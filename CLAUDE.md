# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a GitOps homelab Kubernetes cluster managed by **FluxCD**. All configuration is declarative YAML committed to Git. FluxCD continuously reconciles the cluster state to match what's in the repository. There is a single environment called `staging`.

## Architecture

### Directory Layout

```
clusters/staging/       # FluxCD Kustomization entrypoints (what Flux watches)
apps/
  base/                 # Base Kubernetes manifests per app
  staging/              # Staging overlays (add ingress, env-specific patches)
infrastructure/
  controllers/
    base/               # Base infra controller manifests and HelmReleases
    staging/            # Staging overlays
monitoring/
  controllers/          # kube-prometheus-stack HelmRelease, Loki, Grafana config
  configs/              # Cluster-specific monitoring config (TLS secret, etc.)
scripts/                # Operational scripts (backup, etc.)
docs/operations/        # Runbooks for secrets, backup/restore
```

### How Flux Wires Everything Together

`clusters/staging/` contains three Kustomization objects that Flux watches:
- `apps.yaml` → applies `./apps/staging`
- `infrastructure.yaml` → applies `./infrastructure/controllers/staging` (depends on apps)
- `monitoring.yaml` → applies `./monitoring/controllers/staging` and `./monitoring/configs/staging`

Each of these has SOPS decryption enabled, which instructs Flux to decrypt `*.enc.yaml` files using the `sops-age` secret in the `flux-system` namespace.

### Kustomize Overlay Pattern

Every application follows the same base/overlay structure:
- `apps/base/<app>/` — namespace, deployment, service, storage, configmap
- `apps/staging/<app>/kustomization.yaml` — inherits base, adds ingress and staging-specific patches

Infrastructure controllers follow the same pattern under `infrastructure/controllers/`.

### Secrets Management (SOPS + AGE)

All secrets are encrypted with SOPS and committed as `*.enc.yaml` files. The `.sops.yaml` at the repo root configures SOPS to encrypt only `data` and `stringData` fields in YAML files. FluxCD decrypts them automatically using the AGE private key stored as the `sops-age` secret in `flux-system`.

**Edit a secret:**
```bash
sops <path/to/file>.enc.yaml
# Opens in $EDITOR, re-encrypts on save
```

**If SOPS can't decrypt locally** (missing AGE key):
```bash
kubectl get secret sops-age -n flux-system \
  -o jsonpath='{.data.age\.agekey}' | base64 -d > ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

**Create a new encrypted secret:**
```bash
# Write plaintext YAML to /tmp, then:
sops --encrypt /tmp/my-secret.yaml > path/to/my-secret.enc.yaml
rm /tmp/my-secret.yaml
```

## Common Operational Commands

### Flux Status
```bash
flux get kustomizations                                          # check all kustomizations
flux get helmreleases -A                                         # check all helm releases
flux logs --kind=Kustomization --name=<name>                    # tail kustomization logs
flux reconcile kustomization <name> --with-source               # force reconcile
flux reconcile helmrelease <name> -n <namespace> --with-source  # force helm reconcile
```

### Cluster Inspection
```bash
kubectl get pods -A                        # all pods
kubectl get pvc -A                         # all persistent volumes
kubectl logs -n <ns> deployment/<app>      # app logs
kubectl describe pod -n <ns> <pod>        # debug pod issues
```

### Backup
```bash
./scripts/backup-cluster.sh   # backs up PVC data and Flux state to ./backups/<timestamp>/
```

### Restore Data to a PVC
```bash
kubectl scale deployment <app> -n <ns> --replicas=0
# create a restore pod mounting the PVC, copy data in, delete pod
kubectl scale deployment <app> -n <ns> --replicas=1
```

## Applications

| App | Namespace | Type | Notes |
|-----|-----------|------|-------|
| audiobookshelf | audiobookshelf | Deployment | Audiobook server |
| blog | blog | Deployment | Git-sourced blog; SSH key in `git-ssh-secret.enc.yaml` |
| gulfside | gulfside | Deployment | Static site |
| homepage | homepage | Deployment | Dashboard; stateless (config via ConfigMap + initContainer, restart on config change) |
| linkding | linkding | Deployment | Bookmarks; superuser credentials in `linkding-secret.enc.yaml` |
| mealie | mealie | Deployment | Recipe manager |
| cloudflared | cloudflared | Deployment | Cloudflare Tunnel (2 replicas); under `infrastructure/controllers/`; tunnel credentials in `tunnel-secret.enc.yaml` |
| n8n | naten | Deployment | Workflow automation; under `infrastructure/controllers/`; exposed at n8n.toddpillars.com |
| open-webui | open-webui | HelmRelease | LLM chat UI; under `infrastructure/controllers/`; connects to Ollama at 192.168.0.36:11434 |
| renovate | renovate | CronJob | Dependency update bot; under `infrastructure/controllers/` |
| kube-prometheus-stack | monitoring | HelmRelease | Prometheus + Grafana + Alertmanager |
| Loki | monitoring | HelmRelease | Log aggregation; Grafana datasource configured |

External vLLM instance at `192.168.0.74:8000` is monitored via a headless Service + Endpoints + ServiceMonitor in the `monitoring` namespace.

## Adding a New Application

1. Create `apps/base/<app>/` with: `namespace.yaml`, `deployment.yaml`, `service.yaml`, `storage.yaml` (if needed), `kustomization.yaml`
2. Create `apps/staging/<app>/kustomization.yaml` referencing the base, add ingress and any overlays
3. Add the staging kustomization to `apps/staging/kustomization.yaml`
4. For secrets, create an `*.enc.yaml` file with `sops --encrypt` and reference it in the kustomization

## Key Conventions

- Storage class is `local-path` for all PVCs
- Apps run as user/group 1000 with `fsGroup: 1000`
- Services are `ClusterIP`; external access goes through Cloudflare Tunnel via ingress
- Ingress uses Traefik; some apps add Traefik middleware resources in their staging overlay
- Renovate creates automated PRs for image and Helm chart updates; auto-merge is disabled
- Domain: `*.toddpillars.com` exposed via Cloudflare Tunnel
