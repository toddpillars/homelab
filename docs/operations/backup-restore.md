# Backup and Restore Guide

## Overview

This guide covers backing up and restoring data from Kubernetes persistent volumes, specifically for applications like Linkding, Mealie, and Homarr.

## What Needs Backing Up?

### Application Data Locations

| Application | PVC Name | Mount Path | Data Type |
|------------|----------|------------|-----------|
| Linkding | linkding-data | /etc/linkding/data | SQLite DB |
| Mealie | mealie-data | /app/data | PostgreSQL/SQLite |
| Homarr | homarr-config | /app/data | SQLite + config |

### Secrets and Configuration
- Encrypted secrets in Git (already backed up via SOPS)
- ConfigMaps in Git (already backed up)
- Helm values in Git (already backed up)

**GitOps saves us here!** All configuration is in Git. We only need to backup the **data volumes**.

## Pre-Migration Backup Checklist

Before migrating to a new cluster:

- [ ] Identify all PVCs: `kubectl get pvc -A`
- [ ] Export application data from each PVC
- [ ] Export databases (if using external DB)
- [ ] Document current versions of apps
- [ ] Save SOPS age keys securely
- [ ] Backup kubeconfig
- [ ] List all running pods: `kubectl get pods -A -o yaml > cluster-state.yaml`

## Manual Backup Methods

### Method 1: kubectl cp (Simple, works for small data)
```bash
# Backup Linkding data
kubectl exec -n linkding deployment/linkding -- tar czf - /etc/linkding/data \
  > linkding-backup-$(date +%Y%m%d).tar.gz

# Backup Mealie data
kubectl exec -n mealie deployment/mealie -- tar czf - /app/data \
  > mealie-backup-$(date +%Y%m%d).tar.gz

# Backup Homarr data
kubectl exec -n homarr deployment/homarr -- tar czf - /app/data \
  > homarr-backup-$(date +%Y%m%d).tar.gz
```

### Method 2: Using a Backup Pod (Better for large data)
```bash
# Create a backup pod with PVC mounted
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: backup-pod
  namespace: linkding
spec:
  containers:
  - name: backup
    image: ubuntu:latest
    command: ["sleep", "3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: linkding-data
YAML

# Wait for pod to be ready
kubectl wait --for=condition=ready pod/backup-pod -n linkding

# Copy data out
kubectl cp linkding/backup-pod:/data ./linkding-backup/

# Cleanup
kubectl delete pod backup-pod -n linkding
```

### Method 3: Velero (Automated, Production-Ready)

See [Velero Setup](#velero-setup) below for automated backups.

## Restore Procedures

### Restoring to New Cluster

**Assumption:** New cluster is set up with Flux, apps are deployed via GitOps.

#### Step 1: Verify Apps Are Running
```bash
kubectl get pods -n linkding
kubectl get pods -n mealie
kubectl get pods -n homarr
```

#### Step 2: Scale Down Apps
```bash
kubectl scale deployment linkding -n linkding --replicas=0
kubectl scale deployment mealie -n mealie --replicas=0
kubectl scale deployment homarr -n homarr --replicas=0
```

#### Step 3: Restore Data

**Using kubectl cp:**
```bash
# Extract backup
mkdir -p /tmp/linkding-restore
tar xzf linkding-backup-20260109.tar.gz -C /tmp/linkding-restore

# Create restore pod
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: restore-pod
  namespace: linkding
spec:
  containers:
  - name: restore
    image: ubuntu:latest
    command: ["sleep", "3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: linkding-data
YAML

kubectl wait --for=condition=ready pod/restore-pod -n linkding

# Copy data in
kubectl cp /tmp/linkding-restore/etc/linkding/data/. linkding/restore-pod:/data/

# Cleanup
kubectl delete pod restore-pod -n linkding
```

#### Step 4: Scale Apps Back Up
```bash
kubectl scale deployment linkding -n linkding --replicas=1
kubectl scale deployment mealie -n mealie --replicas=1
kubectl scale deployment homarr -n homarr --replicas=1
```

#### Step 5: Verify
```bash
kubectl logs -n linkding deployment/linkding
kubectl logs -n mealie deployment/mealie
kubectl logs -n homarr deployment/homarr
```

## Automated Backup Strategy

### Option 1: CronJob Backup (Simple)

Create a CronJob that runs backups daily:
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: linkding-backup
  namespace: linkding
spec:
  schedule: "0 2 * * *"  # 2 AM daily
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: ubuntu:latest
            command:
            - /bin/bash
            - -c
            - |
              apt-get update && apt-get install -y curl
              tar czf /backup/linkding-$(date +%Y%m%d).tar.gz /data
              # Upload to S3/storage here
              # curl -T /backup/linkding-*.tar.gz https://your-storage/
            volumeMounts:
            - name: data
              mountPath: /data
              readOnly: true
            - name: backup
              mountPath: /backup
          restartPolicy: OnFailure
          volumes:
          - name: data
            persistentVolumeClaim:
              claimName: linkding-data
          - name: backup
            emptyDir: {}
```

### Option 2: Velero Setup

Velero provides automated cluster and PVC backups.

**Install Velero:**
```bash
# Add Velero Helm repo
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
helm repo update

# Install Velero (with local storage for homelab)
helm install velero vmware-tanzu/velero \
  --namespace velero \
  --create-namespace \
  --set configuration.provider=aws \
  --set configuration.backupStorageLocation.bucket=k8s-backups \
  --set configuration.volumeSnapshotLocation.config.region=us-east-1 \
  --set credentials.useSecret=true \
  --set initContainers[0].name=velero-plugin-for-aws \
  --set initContainers[0].image=velero/velero-plugin-for-aws:v1.8.0 \
  --set initContainers[0].volumeMounts[0].mountPath=/target \
  --set initContainers[0].volumeMounts[0].name=plugins
```

**Create Backup Schedule:**
```bash
# Daily backup of all namespaces
velero schedule create daily-backup \
  --schedule="0 2 * * *" \
  --include-namespaces linkding,mealie,homarr

# Verify
velero schedule get
```

**Manual Backup:**
```bash
velero backup create pre-migration-backup \
  --include-namespaces linkding,mealie,homarr \
  --wait
```

**Restore:**
```bash
velero restore create --from-backup pre-migration-backup
```

## Pre-Migration Backup Script

Save this as `scripts/backup-cluster.sh`:
```bash
#!/bin/bash
set -e

BACKUP_DIR="./backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

echo "🔄 Starting cluster backup to $BACKUP_DIR"

# Backup each app
for app in linkding mealie homarr; do
  echo "📦 Backing up $app..."
  
  # Get the deployment and PVC info
  kubectl get deployment -n $app -o yaml > "$BACKUP_DIR/${app}-deployment.yaml"
  kubectl get pvc -n $app -o yaml > "$BACKUP_DIR/${app}-pvc.yaml"
  
  # Backup data
  POD=$(kubectl get pod -n $app -l app=$app -o jsonpath='{.items[0].metadata.name}')
  kubectl exec -n $app $POD -- tar czf - /app/data 2>/dev/null \
    > "$BACKUP_DIR/${app}-data.tar.gz" || echo "⚠️  No data found for $app"
done

# Backup Flux state
echo "📦 Backing up Flux configuration..."
kubectl get gitrepository -n flux-system -o yaml > "$BACKUP_DIR/flux-gitrepo.yaml"
kubectl get kustomization -n flux-system -o yaml > "$BACKUP_DIR/flux-kustomizations.yaml"
kubectl get helmrelease -A -o yaml > "$BACKUP_DIR/helmreleases.yaml"

# Backup secrets (they're encrypted in git, but just in case)
echo "🔐 Backing up secrets..."
kubectl get secret sops-age -n flux-system -o yaml > "$BACKUP_DIR/sops-age-secret.yaml"

# Save cluster info
echo "ℹ️  Saving cluster info..."
kubectl get nodes -o yaml > "$BACKUP_DIR/nodes.yaml"
kubectl get pods -A -o yaml > "$BACKUP_DIR/all-pods.yaml"

echo "✅ Backup complete: $BACKUP_DIR"
echo ""
echo "📋 Backup contents:"
ls -lh "$BACKUP_DIR"
```

Make it executable:
```bash
chmod +x scripts/backup-cluster.sh
```

## Restore Script

Save this as `scripts/restore-cluster.sh`:
```bash
#!/bin/bash
set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <backup-directory>"
  exit 1
fi

BACKUP_DIR="$1"

if [ ! -d "$BACKUP_DIR" ]; then
  echo "Error: Backup directory not found: $BACKUP_DIR"
  exit 1
fi

echo "🔄 Restoring from $BACKUP_DIR"

# Wait for apps to be deployed by Flux
echo "⏳ Waiting for Flux to deploy apps..."
sleep 30

# Restore each app's data
for app in linkding mealie homarr; do
  if [ -f "$BACKUP_DIR/${app}-data.tar.gz" ]; then
    echo "📦 Restoring $app data..."
    
    # Scale down
    kubectl scale deployment $app -n $app --replicas=0
    sleep 10
    
    # Create restore pod
    cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: restore-pod
  namespace: $app
spec:
  containers:
  - name: restore
    image: ubuntu:latest
    command: ["sleep", "3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: ${app}-data
YAML

    kubectl wait --for=condition=ready pod/restore-pod -n $app --timeout=60s
    
    # Restore data
    kubectl exec -n $app restore-pod -- tar xzf - -C /data \
      < "$BACKUP_DIR/${app}-data.tar.gz"
    
    # Cleanup
    kubectl delete pod restore-pod -n $app
    
    # Scale back up
    kubectl scale deployment $app -n $app --replicas=1
    
    echo "✅ $app restored"
  fi
done

echo "✅ Restore complete!"
```

Make it executable:
```bash
chmod +x scripts/restore-cluster.sh
```

## Testing Backups

**Always test your backups!**
```bash
# 1. Create a test namespace
kubectl create namespace backup-test

# 2. Deploy a test app with data
kubectl run test-app --image=nginx -n backup-test
kubectl exec -n backup-test test-app -- sh -c 'echo "test data" > /tmp/test.txt'

# 3. Backup
kubectl exec -n backup-test test-app -- cat /tmp/test.txt > test-backup.txt

# 4. Delete
kubectl delete pod test-app -n backup-test

# 5. Recreate and restore
kubectl run test-app --image=nginx -n backup-test
kubectl exec -n backup-test test-app -i -- sh -c 'cat > /tmp/test.txt' < test-backup.txt

# 6. Verify
kubectl exec -n backup-test test-app -- cat /tmp/test.txt

# 7. Cleanup
kubectl delete namespace backup-test
```

## Best Practices

1. **Backup Before Changes**
   - Always backup before major changes
   - Run `scripts/backup-cluster.sh` before migrations

2. **Test Restores Regularly**
   - Schedule quarterly restore tests
   - Verify data integrity after restore

3. **Multiple Backup Locations**
   - Local backups on your machine
   - Remote storage (S3, NAS, etc.)
   - Git for configuration (already doing this!)

4. **Document Versions**
   - Note app versions in backup metadata
   - Track Kubernetes version
   - Save Helm chart versions

5. **Automate**
   - Use CronJobs or Velero
   - Don't rely on manual backups
   - Monitor backup success/failure

## Recovery Time Objectives

| Scenario | RTO | RPO |
|----------|-----|-----|
| Single app data loss | 15 min | Last backup |
| Full cluster rebuild | 1 hour | Last backup |
| Configuration drift | 5 min | Git commit |

## See Also

- [Cluster Migration Guide](../troubleshooting/cluster-migration.md)
- [GitOps Setup](../guides/gitops-setup.md)
- [Velero Documentation](https://velero.io/docs/)
