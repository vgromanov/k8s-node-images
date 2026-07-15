# k8s-node-images

Public GitHub Actions proxy that packages official Kubernetes **linux/amd64**
node binaries into a scratch OCI image on GHCR.

| Item | Value |
| --- | --- |
| Image | `ghcr.io/vgromanov/k8s-node-bins:<ver>` |
| Layout | `/opt/bin/{kubectl,kubeadm,kubectl-convert,kubelet,kube-proxy}` |
| Source | `https://dl.k8s.io/release` (sha512 verified) |
| Policy | Latest patch of the three newest stable minors; no pre-releases |

## Why

Consumers behind corporate registries can pull through a GHCR remote instead of
needing a live `dl.k8s.io` mirror for binaries.

## Layout

```
.github/workflows/sync.yml   # daily schedule + workflow_dispatch
scripts/watch-and-pack.sh    # discover → download → OCI push → BOM + tag
releases/vX.Y.Z/
  VERSION
  images.txt                 # kubeadm config images list (audit)
  sources.yaml               # dl.k8s.io URLs + sha512
```

Completion marker: annotated git tag `vX.Y.Z` after a successful GHCR push and
BOM commit.

## Usage

Pull (public package):

```bash
crane manifest ghcr.io/vgromanov/k8s-node-bins:v1.36.2
```

Manual sync (Actions → Sync → Run workflow), optionally with
`versions: v1.36.2` and `force: true`.

Local dry-run:

```bash
WATCH_DRY_RUN=true FORCE_VERSIONS=v1.36.2 scripts/watch-and-pack.sh
```

## License

Upstream Kubernetes binaries are governed by the
[Kubernetes license](https://github.com/kubernetes/kubernetes/blob/master/LICENSE).
This repository’s automation scripts are provided as-is.
