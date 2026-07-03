#!/bin/bash
set -euo pipefail

BACKUP_DIR="./backups/$(date +%Y%m%d-%H%M%S)"
KEEP="${KEEP:-5}"   # number of backup snapshots to retain
FAILURES=0

mkdir -p "$BACKUP_DIR"

echo "🔄 Starting cluster backup to $BACKUP_DIR"

# Backup a single app's data volume(s) into a validated tar.gz.
#   $1 app          - deployment / archive name
#   $2 namespace
#   $3 label-selector - passed to `kubectl get pod -l`; empty string = first pod
#   $4.. paths       - one or more container paths to archive
backup_app() {
  local app="$1" namespace="$2" selector="$3"
  shift 3
  local paths=("$@")
  local archive="$BACKUP_DIR/${app}-data.tar.gz"

  echo "📦 Backing up ${app} (${paths[*]})..."
  kubectl get deployment -n "$namespace" "$app" -o yaml > "$BACKUP_DIR/${app}-deployment.yaml" 2>/dev/null \
    || echo "⚠️  No deployment for ${app}"
  kubectl get pvc -n "$namespace" -o yaml > "$BACKUP_DIR/${app}-pvc.yaml" 2>/dev/null \
    || echo "⚠️  No PVC for ${app}"

  local pod
  if [ -n "$selector" ]; then
    pod=$(kubectl get pod -n "$namespace" -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  else
    pod=$(kubectl get pod -n "$namespace" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  fi

  if [ -z "$pod" ]; then
    echo "❌ No pod found for ${app} — data NOT backed up"
    FAILURES=$((FAILURES + 1))
    return
  fi

  # `|| true` so set -e doesn't abort; we validate the archive explicitly below.
  kubectl exec -n "$namespace" "$pod" -- tar czf - "${paths[@]}" > "$archive" 2>/dev/null || true

  if [ ! -s "$archive" ] || ! tar tzf "$archive" >/dev/null 2>&1; then
    echo "❌ ${app} backup is empty or corrupt ($archive)"
    FAILURES=$((FAILURES + 1))
    return
  fi

  echo "✅ ${app} data backed up ($(du -h "$archive" | cut -f1))"
}

# NOTE: audiobookshelf /audiobooks is intentionally excluded — it can be large
# and should be backed up separately (e.g. NAS sync or a dedicated media tool).
backup_app linkding       linkding       "app=linkding"       /etc/linkding/data
backup_app mealie         mealie         ""                    /app/data
backup_app audiobookshelf audiobookshelf "app=audiobookshelf" /config /metadata
backup_app n8n            naten          "app=n8n"            /home/node/.n8n

# Backup Flux state
echo "📦 Backing up Flux configuration..."
kubectl get gitrepository -n flux-system -o yaml > "$BACKUP_DIR/flux-gitrepo.yaml"
kubectl get kustomization -n flux-system -o yaml > "$BACKUP_DIR/flux-kustomizations.yaml"
kubectl get helmrelease -A -o yaml > "$BACKUP_DIR/helmreleases.yaml"

# Backup SOPS secret (encrypted in git, but backup just in case).
# Contains the AGE private key in plaintext — lock down permissions.
echo "🔐 Backing up SOPS key..."
if kubectl get secret sops-age -n flux-system -o yaml > "$BACKUP_DIR/sops-age-secret.yaml" 2>/dev/null; then
  chmod 600 "$BACKUP_DIR/sops-age-secret.yaml"
else
  echo "⚠️  No sops-age secret found"
fi

# Save cluster info
echo "ℹ️  Saving cluster info..."
kubectl get nodes -o yaml > "$BACKUP_DIR/nodes.yaml"
kubectl top nodes > "$BACKUP_DIR/node-resources.txt" 2>/dev/null || echo "metrics-server not available" > "$BACKUP_DIR/node-resources.txt"
kubectl get pvc -A -o yaml > "$BACKUP_DIR/all-pvcs.yaml"

# Prune old snapshots, keeping the most recent $KEEP (dirs are lexically sortable).
# Portable to macOS bash 3.2 / BSD head (no mapfile, no negative head counts).
echo "🧹 Pruning old backups (keeping last ${KEEP})..."
SNAPSHOTS=$(ls -1d ./backups/*/ 2>/dev/null | sort)
TOTAL=$(printf '%s' "$SNAPSHOTS" | grep -c '/' || true)
if [ "$TOTAL" -gt "$KEEP" ]; then
  printf '%s\n' "$SNAPSHOTS" | head -n "$((TOTAL - KEEP))" | while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    echo "   removing $dir"
    rm -rf "$dir"
  done
fi

echo ""
echo "📋 Backup contents:"
ls -lh "$BACKUP_DIR" | grep -E "\.tar\.gz|\.yaml"
echo ""
echo "📊 Backup size:"
du -sh "$BACKUP_DIR"

if [ "$FAILURES" -gt 0 ]; then
  echo ""
  echo "❌ Backup completed with ${FAILURES} failure(s) — review output above."
  exit 1
fi

echo ""
echo "✅ Backup complete: $BACKUP_DIR"
