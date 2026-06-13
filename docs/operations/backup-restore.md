# Backup and Restore Guide

## Overview

This guide covers backing up and restoring data from Kubernetes persistent volumes for stateful applications in the homelab cluster. All configuration is already in Git via GitOps — only application data volumes need explicit backup.

## What Needs Backing Up?

### Application Data Locations

| Application | Namespace | PVC Name | Mount Path | Data Type |
|-------------|-----------|----------|------------|-----------|
| Linkding | linkding | linkding-data-pvc | /etc/linkding/data | SQLite DB |
| Mealie | mealie | mealie-data | /app/data | SQLite + uploads |
| Audiobookshelf | audiobookshelf | audiobookshelf-config | /config | App config + DB |
| Audiobookshelf | audiobookshelf | audiobookshelf-metadata | /metadata | Book metadata/covers |
| Audiobookshelf | audiobookshelf | audiobookshelf-audiobooks | /audiobooks | Audio files (large — see note) |
| n8n | naten | n8n-data | /home/node/.n8n | Workflows + credentials |

> **Audiobookshelf audiobooks:** The `/audiobooks` PVC is intentionally excluded from the automated backup script because it can hold large media files. Back it up separately via NAS sync, rsync, or another media-aware tool on its own schedule.

### Secrets and Configuration
- Encrypted secrets in Git (already backed up via SOPS)
- ConfigMaps in Git (already backed up)
- Helm values in Git (already backed up)

**GitOps saves us here!** All configuration is in Git. We only need to backup the **data volumes**.

## Automated Backup Script

`scripts/backup-cluster.sh` backs up all stateful apps, the Flux configuration state, and the SOPS AGE key.

```bash
./scripts/backup-cluster.sh
```

Output goes to `./backups/YYYYMMDD-HHMMSS/`. What it produces:

| File | Contents |
|------|----------|
| `linkding-data.tar.gz` | /etc/linkding/data |
| `mealie-data.tar.gz` | /app/data |
| `audiobookshelf-data.tar.gz` | /config + /metadata (no audiobooks) |
| `n8n-data.tar.gz` | /home/node/.n8n |
| `*-deployment.yaml` | Deployment spec for each app |
| `*-pvc.yaml` | PVC spec(s) for each app |
| `flux-gitrepo.yaml` | Flux GitRepository resources |
| `flux-kustomizations.yaml` | Flux Kustomization resources |
| `helmreleases.yaml` | All HelmRelease resources |
| `sops-age-secret.yaml` | AGE decryption key (plaintext — store securely) |
| `nodes.yaml` | Node configs |
| `all-pvcs.yaml` | All PVCs across namespaces |

## Automated Restore Script

`scripts/restore-cluster.sh` restores data from a backup directory. Run it after Flux has deployed all apps on the target cluster.

```bash
./scripts/restore-cluster.sh ./backups/20260109-020000
```

For each app it will:
1. Scale the deployment to 0
2. Spin up a temporary restore pod mounting the PVC(s)
3. Stream the archive into the pod via `tar xzf`
4. Delete the restore pod
5. Scale the deployment back to 1

## Pre-Migration Backup Checklist

Before migrating to a new cluster:

- [ ] Run `./scripts/backup-cluster.sh` and verify all `.tar.gz` files were created
- [ ] Back up `/audiobooks` separately (NAS sync, rsync, etc.)
- [ ] Copy the `backups/` directory to a second location (USB, NAS, cloud)
- [ ] Save `sops-age-secret.yaml` from the backup somewhere safe offline
- [ ] Document current app versions: `kubectl get deployments -A -o wide`
- [ ] Save kubeconfig: `cp ~/.kube/config ~/kube-backup.yaml`

## Manual Backup Methods

### kubectl exec (simple, good for small data)
```bash
# Backup Linkding
kubectl exec -n linkding deployment/linkding -- tar czf - /etc/linkding/data \
  > linkding-backup-$(date +%Y%m%d).tar.gz

# Backup Mealie
kubectl exec -n mealie deployment/mealie -- tar czf - /app/data \
  > mealie-backup-$(date +%Y%m%d).tar.gz

# Backup Audiobookshelf config + metadata
kubectl exec -n audiobookshelf deployment/audiobookshelf -- tar czf - /config /metadata \
  > audiobookshelf-backup-$(date +%Y%m%d).tar.gz

# Backup n8n
kubectl exec -n naten deployment/n8n -- tar czf - /home/node/.n8n \
  > n8n-backup-$(date +%Y%m%d).tar.gz
```

### Backup Pod (better for large data or when the app must stay down)
```bash
# Example: Linkding
kubectl scale deployment linkding -n linkding --replicas=0

cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: backup-pod
  namespace: linkding
spec:
  containers:
  - name: backup
    image: busybox:latest
    command: ["sleep", "3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: linkding-data-pvc
  restartPolicy: Never
YAML

kubectl wait --for=condition=ready pod/backup-pod -n linkding
kubectl exec -n linkding backup-pod -- tar czf - /data > linkding-backup.tar.gz
kubectl delete pod backup-pod -n linkding

kubectl scale deployment linkding -n linkding --replicas=1
```

### Velero (automated, production-ready)

Velero provides automated cluster and PVC backups with a storage backend.

**Install:**
```bash
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo update

helm install velero vmware-tanzu/velero \
  --namespace velero \
  --create-namespace \
  --set configuration.provider=aws \
  --set configuration.backupStorageLocation.bucket=k8s-backups \
  --set credentials.useSecret=true \
  --set initContainers[0].name=velero-plugin-for-aws \
  --set initContainers[0].image=velero/velero-plugin-for-aws:v1.8.0 \
  --set initContainers[0].volumeMounts[0].mountPath=/target \
  --set initContainers[0].volumeMounts[0].name=plugins
```

**Schedule daily backups:**
```bash
velero schedule create daily-backup \
  --schedule="0 2 * * *" \
  --include-namespaces linkding,mealie,audiobookshelf,naten

velero schedule get
```

**Manual backup:**
```bash
velero backup create pre-migration-backup \
  --include-namespaces linkding,mealie,audiobookshelf,naten \
  --wait
```

**Restore:**
```bash
velero restore create --from-backup pre-migration-backup
```

## Restore Procedures (Manual)

### Restoring a Single App

**Assumption:** Flux has already deployed the app and PVCs exist.

```bash
# 1. Scale down
kubectl scale deployment linkding -n linkding --replicas=0

# 2. Create restore pod
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: restore-pod
  namespace: linkding
spec:
  containers:
  - name: restore
    image: busybox:latest
    command: ["sleep", "3600"]
    volumeMounts:
    - name: data
      mountPath: /etc/linkding/data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: linkding-data-pvc
  restartPolicy: Never
YAML

kubectl wait --for=condition=ready pod/restore-pod -n linkding

# 3. Stream archive in
kubectl exec -n linkding restore-pod -- tar xzf - -C / < linkding-backup.tar.gz

# 4. Cleanup and scale up
kubectl delete pod restore-pod -n linkding
kubectl scale deployment linkding -n linkding --replicas=1
kubectl logs -n linkding deployment/linkding
```

## Testing Backups

Always test your backups after creating them:

```bash
# List archive contents without extracting
tar tzf backups/latest/linkding-data.tar.gz | head -20

# Check archive integrity
tar tzf backups/latest/mealie-data.tar.gz > /dev/null && echo "OK" || echo "CORRUPT"

# Full restore test: spin up a scratch namespace, restore into it, verify
kubectl create namespace backup-test
# ... mount PVC clone or use a temporary pod to validate data
kubectl delete namespace backup-test
```

## Best Practices

1. **Backup Before Changes** — run `scripts/backup-cluster.sh` before any major cluster change or upgrade
2. **Test Restores** — quarterly, pick one app and do a full restore into a test namespace
3. **Multiple Locations** — local machine + NAS or cloud storage; never only one copy
4. **Protect the SOPS Key** — `sops-age-secret.yaml` from the backup contains your AGE private key in plaintext; store it offline or in a password manager
5. **Automate** — consider a CronJob or Velero rather than relying on manual runs

## Recovery Time Objectives

| Scenario | RTO | RPO |
|----------|-----|-----|
| Single app data loss | 15 min | Last backup |
| Full cluster rebuild | 1 hour | Last backup |
| Configuration drift | 5 min | Git commit |

## Linkding Superuser

Linkding creates a superuser on first startup from the `linkding-container-env` secret:

- **Username**: `LD_SUPERUSER_NAME`
- **Password**: `LD_SUPERUSER_PASSWORD`

The secret is SOPS-encrypted at `apps/staging/linkding/linkding-secret.enc.yaml` and automatically decrypted by Flux.

**To change credentials:**
```bash
sops apps/staging/linkding/linkding-secret.enc.yaml
# Edit values, save — SOPS re-encrypts on exit

git add apps/staging/linkding/linkding-secret.enc.yaml
git commit -m "Update Linkding superuser credentials"
git push

# Restart to pick up new values (only affects initial DB creation)
kubectl rollout restart deployment/linkding -n linkding
```

> **Note:** The superuser is only created on initial database setup. If the database already exists, changing these env vars won't update the existing user.

## See Also

- [Velero Documentation](https://velero.io/docs/)
- [FluxCD Disaster Recovery](https://fluxcd.io/flux/guides/disaster-recovery/)
