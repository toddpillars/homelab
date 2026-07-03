---
title: Grafana SOPS Credentials Management
tags: [kubernetes, flux, sops, grafana, security, gitops]
created: 2026-01-14
updated: 2026-07-03
author: Todd Pillars
---

# Grafana SOPS Credentials Management

Grafana admin credentials are stored SOPS-encrypted in Git and automatically
decrypted by FluxCD at deploy time. See `CLAUDE.md` → **Secrets Management** for
the general SOPS/AGE workflow; this doc covers the Grafana-specific pieces.

## Quick Reference

```bash
# View credentials
kubectl get secret grafana-admin-credentials -n monitoring -o jsonpath='{.data.admin-user}' | base64 -d
kubectl get secret grafana-admin-credentials -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d

# Edit the encrypted secret (opens $EDITOR, re-encrypts on save)
sops monitoring/controllers/base/kube-prometheus-stack/grafana-credentials.enc.yaml

# Force Flux to apply changes
flux reconcile kustomization monitoring-controllers --with-source
```

### Verification checklist

| Check | Command | Expected |
|-------|---------|----------|
| Secret exists | `kubectl get secret grafana-admin-credentials -n monitoring` | Found, 2 data keys |
| Values decrypted | `kubectl get secret grafana-admin-credentials -n monitoring -o jsonpath='{.data.admin-user}' \| base64 -d` | `admin` (not `ENC[...]`) |
| Grafana running | `kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana` | Running |
| Flux healthy | `flux get kustomizations` | monitoring-controllers: True |
| HelmRelease OK | `kubectl get helmrelease -n monitoring` | kube-prometheus-stack: True |

### Quick troubleshooting

| Problem | Fix |
|---------|-----|
| Secret has `ENC[...]` text | Add `decryption` block to `clusters/staging/monitoring.yaml` |
| CreateContainerConfigError | Secret missing `admin-user` key — recreate with both keys |
| Cannot decrypt locally | Export AGE key (see *Cannot decrypt SOPS file locally* below) |
| Wrong namespace error | Ensure `namespace: monitoring` in the encrypted file |

## How it fits together

```
monitoring/controllers/base/kube-prometheus-stack/
├── grafana-credentials.enc.yaml   # SOPS-encrypted Secret (admin-user, admin-password)
├── kustomization.yaml             # must list grafana-credentials.enc.yaml
├── release.yaml                   # HelmRelease references existingSecret
├── repository.yaml
└── namespace.yaml

clusters/staging/monitoring.yaml   # Flux Kustomization with SOPS decryption enabled
.sops.yaml                         # SOPS config (repo root)
```

- **SOPS** encrypts only `data`/`stringData` fields (per `.sops.yaml`), using the
  cluster's AGE key stored as the `sops-age` secret in `flux-system`.
- **FluxCD** decrypts the file during reconciliation and creates the Kubernetes secret.
- **Grafana Helm chart** reads admin credentials from that secret.

### Required config snippets

Decryption block — `clusters/staging/monitoring.yaml` (must be present, or encrypted
values get applied verbatim and Grafana fails to start):

```yaml
spec:
  decryption:
    provider: sops
    secretRef:
      name: sops-age
```

HelmRelease — `release.yaml`:

```yaml
values:
  grafana:
    admin:
      existingSecret: grafana-admin-credentials
      userKey: admin-user
      passwordKey: admin-password
```

Kustomization — `kustomization.yaml` must include `grafana-credentials.enc.yaml`
alongside `namespace.yaml`, `repository.yaml`, and `release.yaml`.

## Updating credentials

```bash
sops monitoring/controllers/base/kube-prometheus-stack/grafana-credentials.enc.yaml
# edit admin-user / admin-password, save (SOPS re-encrypts)

git add monitoring/controllers/base/kube-prometheus-stack/grafana-credentials.enc.yaml
git commit -m "Update Grafana admin credentials"
git push

flux reconcile kustomization monitoring-controllers --with-source
```

To recreate the secret from scratch, write a plaintext Secret to `/tmp`, run
`sops --encrypt` into the `.enc.yaml` path, then `rm` the plaintext (same pattern
as any other secret in this repo).

## Emergency password reset

If the password is lost, delete the secret(s) and let Helm regenerate one:

```bash
kubectl delete secret grafana-admin-credentials -n monitoring
kubectl delete secret kube-prometheus-stack-grafana -n monitoring
flux reconcile helmrelease kube-prometheus-stack -n monitoring

kubectl get secret kube-prometheus-stack-grafana -n monitoring \
  -o jsonpath='{.data.admin-password}' | base64 -d
```

## Troubleshooting

### Secret contains encrypted `ENC[...]` text instead of values
FluxCD kustomization is missing the SOPS `decryption` block. Confirm with
`grep -A4 decryption: clusters/staging/monitoring.yaml`; add it if absent and push.

### Grafana pod in CreateContainerConfigError
The secret is missing a required key. Check both are present:
```bash
kubectl get secret grafana-admin-credentials -n monitoring -o jsonpath='{.data}' | jq
```
Recreate with both `admin-user` and `admin-password` if one is missing.

### Cannot decrypt SOPS file locally
The AGE private key isn't on your machine. Export it from the cluster:
```bash
kubectl get secret sops-age -n flux-system \
  -o jsonpath='{.data.age\.agekey}' | base64 -d > ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

### FluxCD reconciliation failed
```bash
kubectl get kustomization monitoring-controllers -n flux-system -o yaml | tail -30
flux reconcile kustomization monitoring-controllers --with-source
```
Common causes: missing decryption block, wrong secret namespace.

## Security & backup

- The `sops-age` secret in `flux-system` holds the private key that decrypts **all**
  SOPS secrets — anyone with cluster admin can extract it. Limit cluster access and
  rotate the key/passwords after any suspected compromise or personnel change.
- **Back up the AGE key** — without it you cannot decrypt secrets or rebuild the
  cluster. Store it in a password manager or encrypted offline storage; never commit
  it unencrypted. `scripts/backup-cluster.sh` writes it (mode 600) into each backup
  snapshot as `sops-age-secret.yaml`.

## Disaster recovery

Complete cluster loss (requires the Git repo + an AGE key backup):

```bash
# 1. Bootstrap Flux against the repo
flux bootstrap github --owner=toddpillars --repository=homelab \
  --path=clusters/staging --personal

# 2. Restore the AGE key so Flux can decrypt
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: sops-age
  namespace: flux-system
type: Opaque
data:
  age.agekey: $(base64 -w0 < age-key-backup.txt)
EOF

# 3. Flux reconciles and Grafana comes up with credentials from the encrypted secret.
#    Verify: flux get kustomizations ; kubectl get pods -n monitoring
```

If only the Grafana password is lost, decrypt it from Git
(`sops --decrypt .../grafana-credentials.enc.yaml`) or read it from the live secret.
If the AGE key itself is lost with no backup, every SOPS secret must be recreated
under a new key — which is why the key backup is mandatory.

## References

- [SOPS](https://github.com/getsops/sops) · [FluxCD SOPS Guide](https://fluxcd.io/flux/guides/mozilla-sops/) · [AGE](https://github.com/FiloSottile/age)
- [Grafana Helm Chart](https://github.com/grafana/helm-charts/tree/main/charts/grafana)
