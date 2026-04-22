# skills-stack Helm chart

Deploys the OPL **skills-service** (semantic search + MCP at `/mcp`) and **skills-manager** (agentskill.sh marketplace, GitHub install, UI) using images from Quay:

- `quay.io/varkrish/skills-service`
- `quay.io/varkrish/skills-manager`

## Install

```bash
helm upgrade --install skills ./helm/skills-stack \
  --namespace opl --create-namespace \
  --set skillsService.image.tag=latest \
  --set skillsManager.image.tag=latest
```

## Storage

| PVC | Access | Used by |
|-----|--------|---------|
| `*-marketplace` | `ReadWriteMany` (default) | Manager (RW), skills-service (RO) — **shared installed skills** |
| `*-skills-cache` | `ReadWriteOnce` | skills-service only — HF model + vector index |

Set `marketplace.persistence.storageClassName` to a class that supports **RWX** (e.g. AWS EFS, Azure Files, NFS) if the two pods may land on different nodes. For single-node clusters you can try `ReadWriteOnce` with a single replica for both (not typical).

If `marketplace.persistence.enabled` is `false`, both pods use `emptyDir` for `/app/skills/marketplace` (not shared — only for quick testing).

## GitHub token (optional)

```bash
# Prefer an existing secret
helm upgrade --install skills ./helm/skills-stack \
  --set skillsManager.existingSecret=my-github-token \
  --set skillsManager.existingSecretKey=token

# Or inline (avoid in production)
helm upgrade --install skills ./helm/skills-stack \
  --set skillsManager.githubToken="$GITHUB_TOKEN"
```

## Ingress (optional)

```bash
helm upgrade --install skills ./helm/skills-stack \
  --set ingress.enabled=true \
  --set ingress.className=nginx \
  --set ingress.skills.host=skills.example.com \
  --set ingress.manager.host=skills-ui.example.com
```

MCP URL from outside the cluster: `https://skills.example.com/mcp` (path on the skills service).

## Static skills (base / Frappe)

By default, `/app/skills/base` and `/app/skills/frappe` are `emptyDir`. To load team skills from a PVC or ConfigMap, use `skillsService.extraVolumes` and `skillsService.extraVolumeMounts` in your own values file.

## Uninstall

```bash
helm uninstall skills -n opl
# Optional: delete PVCs if you want a clean slate
kubectl delete pvc -n opl -l app.kubernetes.io/instance=skills
```
