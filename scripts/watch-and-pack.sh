#!/usr/bin/env bash
# Discover the latest patch of each of the three newest stable Kubernetes minors
# from public dl.k8s.io, publish scratch OCI node-bins to GHCR, and commit BOM +
# annotated git tags under releases/vX.Y.Z/.
#
# Triggers: GitHub Actions schedule / workflow_dispatch (or local dry-run).
#
# Env:
#   BIN_MIRROR_BASE     — default https://dl.k8s.io/release
#   REGISTRY / REPO     — default ghcr.io / vgromanov/k8s-node-bins
#   GHCR_TOKEN / GITHUB_TOKEN — push to GHCR (login as GHCR_USER)
#   GHCR_USER           — GHCR username (default: github.actor / vgromanov)
#   SKIP_IF_EXISTS=true — skip when GHCR tag already exists (default true)
#   WATCH_DRY_RUN=true  — resolve + pack locally but do not push/commit/tag
#   FORCE_VERSIONS      — space-separated versions to process (skip discovery)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

BIN_MIRROR_BASE="${BIN_MIRROR_BASE:-https://dl.k8s.io/release}"
BIN_MIRROR_BASE="${BIN_MIRROR_BASE%/}"
REGISTRY="${REGISTRY:-ghcr.io}"
REPO="${REPO:-vgromanov/k8s-node-bins}"
PLATFORM="${PLATFORM:-linux/amd64}"
SKIP_IF_EXISTS="${SKIP_IF_EXISTS:-true}"
WATCH_DRY_RUN="${WATCH_DRY_RUN:-false}"
GHCR_USER="${GHCR_USER:-${GITHUB_ACTOR:-vgromanov}}"
GHCR_TOKEN="${GHCR_TOKEN:-${GITHUB_TOKEN:-}}"

BINS=(kubectl kubeadm kubectl-convert kubelet kube-proxy)

need_cmds=(curl crane sha512sum python3 git)
for c in "${need_cmds[@]}"; do
  command -v "${c}" >/dev/null 2>&1 || {
    echo "error: required command not found: ${c}" >&2
    exit 1
  }
done

fetch() {
  curl -fsSL "$1"
}

is_prerelease() {
  local v="$1"
  [[ "${v}" =~ -(alpha|beta|rc)(\.|$|[0-9]) ]]
}

normalize_version() {
  local v
  v="$(tr -d '[:space:]' <<<"$1")"
  case "${v}" in
    v*) printf '%s\n' "${v}" ;;
    *) printf 'v%s\n' "${v}" ;;
  esac
}

minor_of() {
  local v="$1"
  v="${v#v}"
  printf '%s\n' "${v%.*}"
}

ghcr_ref() {
  printf '%s/%s:%s\n' "${REGISTRY}" "${REPO}" "$1"
}

ghcr_exists() {
  crane manifest "$(ghcr_ref "$1")" >/dev/null 2>&1
}

git_tag_exists() {
  git rev-parse -q --verify "refs/tags/$1" >/dev/null 2>&1 \
    || git ls-remote --tags origin "refs/tags/$1" 2>/dev/null | grep -q .
}

resolve_images() {
  local version="$1" out="$2"
  local workdir kubeadm_bin list
  workdir="$(mktemp -d)"

  kubeadm_bin=""
  if command -v kubeadm >/dev/null 2>&1; then
    if kubeadm version -o short >/dev/null 2>&1; then
      kubeadm_bin="kubeadm"
    fi
  fi
  if [[ -z "${kubeadm_bin}" ]]; then
    curl -fsSL -o "${workdir}/kubeadm" \
      "${BIN_MIRROR_BASE}/${version}/bin/linux/amd64/kubeadm"
    chmod +x "${workdir}/kubeadm"
    kubeadm_bin="${workdir}/kubeadm"
  fi

  list="$("${kubeadm_bin}" config images list --kubernetes-version="${version}")"
  rm -rf "${workdir}"
  if [[ -z "${list}" ]]; then
    echo "error: empty image list for ${version}" >&2
    exit 1
  fi
  mkdir -p "$(dirname "${out}")"
  printf '%s\n' "${list}" >"${out}"
}

write_sources_yaml() {
  local version="$1" out="$2"
  local base_url="${BIN_MIRROR_BASE}/${version}/bin/${PLATFORM}"
  local b sha_file sha

  {
    echo "version: ${version}"
    echo "platform: ${PLATFORM}"
    echo "bin_mirror_base: ${BIN_MIRROR_BASE}"
    echo "binaries:"
    for b in "${BINS[@]}"; do
      sha_file="$(fetch "${base_url}/${b}.sha512")"
      sha="$(awk '{print $1}' <<<"${sha_file}")"
      if [[ -z "${sha}" || ${#sha} -lt 64 ]]; then
        echo "error: bad sha512 for ${b} @ ${version}" >&2
        exit 1
      fi
      echo "  - name: ${b}"
      echo "    url: ${base_url}/${b}"
      echo "    sha512: ${sha}"
    done
  } >"${out}"
}

pack_and_push() {
  local version="$1" sources="$2"
  local ref workdir bin_dir oci_dir rootfs name url sha got_sha
  ref="$(ghcr_ref "${version}")"
  workdir="$(mktemp -d)"
  bin_dir="${workdir}/bins"
  oci_dir="${workdir}/oci-dir"
  rootfs="${workdir}/rootfs"
  mkdir -p "${bin_dir}" "${rootfs}/opt/bin"

  while IFS=$'\t' read -r name url sha; do
    [[ -n "${name}" ]] || continue
    echo "→ download ${name}"
    curl -fsSL -o "${bin_dir}/${name}" "${url}"
    got_sha="$(sha512sum "${bin_dir}/${name}" | awk '{print $1}')"
    if [[ "${got_sha}" != "${sha}" ]]; then
      echo "error: sha512 mismatch for ${name}" >&2
      echo "  expected: ${sha}" >&2
      echo "  got:      ${got_sha}" >&2
      exit 1
    fi
    chmod +x "${bin_dir}/${name}"
  done < <(python3 - "${sources}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
try:
    import yaml
except ImportError:
    yaml = None

if yaml is not None:
    data = yaml.safe_load(text)
    for b in data.get("binaries") or []:
        print(f"{b['name']}\t{b['url']}\t{b['sha512'].strip().split()[0]}")
    raise SystemExit(0)

name = url = sha = ""
in_binaries = False
for line in text.splitlines():
    s = line.strip()
    if s == "binaries:":
        in_binaries = True
        continue
    if not in_binaries:
        continue
    if s.startswith("- name:"):
        if name and sha:
            print(f"{name}\t{url}\t{sha}")
        name = s.split(":", 1)[1].strip()
        url = sha = ""
    elif s.startswith("url:"):
        url = s.split(":", 1)[1].strip().strip("\"'")
    elif s.startswith("sha512:"):
        sha = s.split(":", 1)[1].strip().split()[0]
if name and sha:
    print(f"{name}\t{url}\t{sha}")
PY
)

  cp -a "${bin_dir}/." "${rootfs}/opt/bin/"

  if command -v podman >/dev/null 2>&1; then
    cat >"${workdir}/Containerfile" <<'EOF'
FROM scratch
COPY rootfs/opt/bin /opt/bin
EOF
    echo "→ build ${ref} (podman)"
    podman build -t "${ref}" -f "${workdir}/Containerfile" "${workdir}"
    rm -rf "${oci_dir}"
    podman save --format oci-dir -o "${oci_dir}" "${ref}"
  else
    echo "→ build OCI layout (crane-only)"
    python3 - "${rootfs}" "${oci_dir}" <<'PY'
import gzip
import hashlib
import json
import sys
import tarfile
from pathlib import Path

rootfs = Path(sys.argv[1])
out = Path(sys.argv[2])
blobs = out / "blobs" / "sha256"
blobs.mkdir(parents=True, exist_ok=True)

layer_tar = out / "layer.tar"
with tarfile.open(layer_tar, "w") as tar:
    for path in sorted(rootfs.rglob("*")):
        if path.is_file() or path.is_symlink():
            tar.add(path, arcname=str(path.relative_to(rootfs)))

diff_raw = layer_tar.read_bytes()
diff_id = "sha256:" + hashlib.sha256(diff_raw).hexdigest()
gz_bytes = gzip.compress(diff_raw, mtime=0)
layer_digest = "sha256:" + hashlib.sha256(gz_bytes).hexdigest()
(blobs / layer_digest.removeprefix("sha256:")).write_bytes(gz_bytes)

config = {
    "architecture": "amd64",
    "os": "linux",
    "config": {"WorkingDir": "/"},
    "rootfs": {"type": "layers", "diff_ids": [diff_id]},
    "history": [{"created_by": "watch-and-pack.sh"}],
}
config_bytes = (json.dumps(config, separators=(",", ":")) + "\n").encode()
config_digest = "sha256:" + hashlib.sha256(config_bytes).hexdigest()
(blobs / config_digest.removeprefix("sha256:")).write_bytes(config_bytes)

manifest = {
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.manifest.v1+json",
    "config": {
        "mediaType": "application/vnd.oci.image.config.v1+json",
        "digest": config_digest,
        "size": len(config_bytes),
    },
    "layers": [
        {
            "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
            "digest": layer_digest,
            "size": len(gz_bytes),
        }
    ],
}
manifest_bytes = (json.dumps(manifest, separators=(",", ":")) + "\n").encode()
manifest_digest = "sha256:" + hashlib.sha256(manifest_bytes).hexdigest()
(blobs / manifest_digest.removeprefix("sha256:")).write_bytes(manifest_bytes)

index = {
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.index.v1+json",
    "manifests": [
        {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "digest": manifest_digest,
            "size": len(manifest_bytes),
            "platform": {"architecture": "amd64", "os": "linux"},
        }
    ],
}
(out / "index.json").write_text(json.dumps(index, indent=2) + "\n", encoding="utf-8")
(out / "oci-layout").write_text('{"imageLayoutVersion":"1.0.0"}\n', encoding="utf-8")
layer_tar.unlink(missing_ok=True)
PY
  fi

  if [[ "${WATCH_DRY_RUN}" == "true" ]]; then
    echo "WATCH_DRY_RUN=true; skipping push of ${ref}"
    rm -rf "${workdir}"
    return 0
  fi

  if [[ -z "${GHCR_TOKEN}" ]]; then
    echo "error: set GHCR_TOKEN or GITHUB_TOKEN to push to GHCR" >&2
    exit 1
  fi

  echo "→ login ${REGISTRY}"
  echo "${GHCR_TOKEN}" | crane auth login "${REGISTRY}" -u "${GHCR_USER}" --password-stdin

  echo "→ push ${ref}"
  crane push "${oci_dir}" "${ref}"
  echo "✓ ${ref}"
  rm -rf "${workdir}"
}

set_package_public() {
  if [[ "${WATCH_DRY_RUN}" == "true" ]]; then
    return 0
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "warn: gh not found; skip setting package visibility" >&2
    return 0
  fi
  # First publish may race package creation; ignore failures until package exists.
  if gh api \
    --method PUT \
    -H "Accept: application/vnd.github+json" \
    "/user/packages/container/k8s-node-bins/visibility" \
    -f visibility=public >/dev/null 2>&1; then
    echo "✓ GHCR package k8s-node-bins is public"
  else
    echo "warn: could not set package visibility to public (may need manual step)" >&2
  fi
}

discover_targets() {
  local current current_minor major minor i m channel_minor ver raw
  if [[ -n "${FORCE_VERSIONS:-}" ]]; then
    for ver in ${FORCE_VERSIONS}; do
      ver="$(normalize_version "${ver}")"
      if is_prerelease "${ver}"; then
        echo "skip pre-release FORCE_VERSIONS entry: ${ver}"
        continue
      fi
      TARGETS+=("${ver}")
    done
    return 0
  fi

  current="$(normalize_version "$(fetch "${BIN_MIRROR_BASE}/stable.txt")")"
  if is_prerelease "${current}"; then
    echo "error: stable.txt returned pre-release ${current}" >&2
    exit 1
  fi
  current_minor="$(minor_of "${current}")"
  major="${current_minor%%.*}"
  minor="${current_minor#*.}"

  for ((i = 0; i < 3; i++)); do
    m=$((minor - i))
    if ((m < 0)); then
      break
    fi
    channel_minor="${major}.${m}"
    if ((i == 0)); then
      ver="${current}"
    else
      raw="$(fetch "${BIN_MIRROR_BASE}/stable-${channel_minor}.txt")"
      ver="$(normalize_version "${raw}")"
    fi
    if is_prerelease "${ver}"; then
      echo "skip pre-release channel stable-${channel_minor}: ${ver}"
      continue
    fi
    if [[ "$(minor_of "${ver}")" != "${channel_minor}" ]]; then
      echo "error: channel stable-${channel_minor}.txt returned ${ver}" >&2
      exit 1
    fi
    TARGETS+=("${ver}")
  done
}

# --- main ---

echo "BIN_MIRROR_BASE=${BIN_MIRROR_BASE}"
echo "REGISTRY=${REGISTRY} REPO=${REPO}"

if [[ "${WATCH_DRY_RUN}" != "true" && -n "${GITHUB_ACTIONS:-}" ]]; then
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git config user.name "github-actions[bot]"
  git fetch origin "${GITHUB_REF_NAME:-main}" || true
fi

TARGETS=()
discover_targets
echo "Top-3 target versions: ${TARGETS[*]:-none}"

CREATED=()
for ver in "${TARGETS[@]}"; do
  rel="releases/${ver}"
  ref="$(ghcr_ref "${ver}")"

  if [[ "${SKIP_IF_EXISTS}" == "true" ]] && ghcr_exists "${ver}"; then
    echo "skip: ${ref} already exists on GHCR"
    # Ensure BOM + tag exist for audit even if image was pushed earlier.
    if [[ -d "${rel}" && -f "${rel}/VERSION" ]] && git_tag_exists "${ver}"; then
      continue
    fi
  fi

  if git_tag_exists "${ver}" && [[ -d "${rel}" && -f "${rel}/VERSION" ]] \
    && [[ "${SKIP_IF_EXISTS}" == "true" ]] && ghcr_exists "${ver}"; then
    echo "skip: git tag ${ver} and BOM already present"
    continue
  fi

  echo "processing ${ver}"
  mkdir -p "${rel}"
  printf '%s\n' "${ver}" >"${rel}/VERSION"
  write_sources_yaml "${ver}" "${rel}/sources.yaml"
  resolve_images "${ver}" "${rel}/images.txt"

  if [[ "${SKIP_IF_EXISTS}" != "true" ]] || ! ghcr_exists "${ver}"; then
    pack_and_push "${ver}" "${rel}/sources.yaml"
  else
    echo "skip pack: ${ref} already exists"
  fi

  CREATED+=("${ver}")
done

set_package_public

if ((${#CREATED[@]} == 0)); then
  echo "No new releases to commit"
  exit 0
fi

echo "New/updated: ${CREATED[*]}"

if [[ "${WATCH_DRY_RUN}" == "true" ]]; then
  echo "WATCH_DRY_RUN=true; skipping commit/tag/push"
  exit 0
fi

git add releases/
if git diff --cached --quiet; then
  echo "No BOM file changes to commit"
else
  git commit -m "chore(releases): add BOM for ${CREATED[*]}"
fi

for ver in "${CREATED[@]}"; do
  if git rev-parse -q --verify "refs/tags/${ver}" >/dev/null 2>&1; then
    echo "tag exists locally: ${ver}"
    continue
  fi
  git tag -a "${ver}" -m "Kubernetes node-bins ${ver}"
done

if [[ -n "${GITHUB_ACTIONS:-}" ]] || git remote get-url origin >/dev/null 2>&1; then
  git push origin "HEAD:${GITHUB_REF_NAME:-main}"
  for ver in "${CREATED[@]}"; do
    git push origin "refs/tags/${ver}" || true
  done
fi

echo "Done: ${CREATED[*]}"
