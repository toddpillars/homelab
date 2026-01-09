#!/bin/bash
set -e

BACKUP_DIR="./backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

echo "🔄 Starting cluster backup to $BACKUP_DIR"

# Backup Linkding
echo "📦 Backing up linkding..."
kubectl get deployment -n linkding linkding -o yaml > "$BACKUP_DIR/linkding-deployment.yaml" 2>/dev/null || echo "⚠️  No deployment for linkding"
kubectl get pvc -n linkding -o yaml > "$BACKUP_DIR/linkding-pvc.yaml" 2>/dev/null || echo "⚠️  No PVC for linkding"

LINKDING_POD=$(kubectl get pod -n linkding -l app=linkding -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$LINKDING_POD" ]; then
  kubectl exec -n linkding $LINKDING_POD -- tar czf - /etc/linkding/data 2>/dev/null \
    > "$BACKUP_DIR/linkding-data.tar.gz" || echo "⚠️  Could not backup linkding data"
  echo "✅ Linkding data backed up"
else
  echo "⚠️  No linkding pod found"
fi

# Backup Mealie
echo "📦 Backing up mealie..."
kubectl get deployment -n mealie mealie -o yaml > "$BACKUP_DIR/mealie-deployment.yaml" 2>/dev/null || echo "⚠️  No deployment for mealie"
kubectl get pvc -n mealie -o yaml > "$BACKUP_DIR/mealie-pvc.yaml" 2>/dev/null || echo "⚠️  No PVC for mealie"

MEALIE_POD=$(kubectl get pod -n mealie -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$MEALIE_POD" ]; then
  kubectl exec -n mealie $MEALIE_POD -- tar czf - /app/data 2>/dev/null \
    > "$BACKUP_DIR/mealie-data.tar.gz" || echo "⚠️  Could not backup mealie data"
  echo "✅ Mealie data backed up"
else
  echo "⚠️  No mealie pod found"
fi

# Backup Homarr
echo "📦 Backing up homarr..."
kubectl get deployment -n homarr homarr -o yaml > "$BACKUP_DIR/homarr-deployment.yaml" 2>/dev/null || echo "⚠️  No deployment for homarr"
kubectl get pvc -n homarr -o yaml > "$BACKUP_DIR/homarr-pvc.yaml" 2>/dev/null || echo "⚠️  No PVC for homarr"

HOMARR_POD=$(kubectl get pod -n homarr -l app.kubernetes.io/name=homarr -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$HOMARR_POD" ]; then
  kubectl exec -n homarr $HOMARR_POD -- tar czf - /appdata 2>/dev/null \
    > "$BACKUP_DIR/homarr-data.tar.gz" || echo "⚠️  Could not backup homarr data"
  echo "✅ Homarr data backed up"
else
  echo "⚠️  No homarr pod found"
fi

# Backup Flux state
echo "📦 Backing up Flux configuration..."
kubectl get gitrepository -n flux-system -o yaml > "$BACKUP_DIR/flux-gitrepo.yaml"
kubectl get kustomization -n flux-system -o yaml > "$BACKUP_DIR/flux-kustomizations.yaml"
kubectl get helmrelease -A -o yaml > "$BACKUP_DIR/helmreleases.yaml"

# Backup SOPS secret (encrypted in git, but backup just in case)
echo "🔐 Backing up SOPS key..."
kubectl get secret sops-age -n flux-system -o yaml > "$BACKUP_DIR/sops-age-secret.yaml" 2>/dev/null || echo "⚠️  No sops-age secret found"

# Save cluster info
echo "ℹ️  Saving cluster info..."
kubectl get nodes -o yaml > "$BACKUP_DIR/nodes.yaml"
kubectl top nodes > "$BACKUP_DIR/node-resources.txt" 2>/dev/null || echo "metrics-server not available" > "$BACKUP_DIR/node-resources.txt"
kubectl get pvc -A -o yaml > "$BACKUP_DIR/all-pvcs.yaml"

echo ""
echo "✅ Backup complete: $BACKUP_DIR"
echo ""
echo "📋 Backup contents:"
ls -lh "$BACKUP_DIR" | grep -E "\.tar\.gz|\.yaml"
echo ""
echo "📊 Backup sizes:"
du -sh "$BACKUP_DIR"
du -sh "$BACKUP_DIR"/*.tar.gz 2>/dev/null || echo "No data archives found"
