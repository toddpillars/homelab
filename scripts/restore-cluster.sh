#!/bin/bash
set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <backup-directory>"
  echo ""
  echo "Restores application data from a backup created by backup-cluster.sh."
  echo "Run this after Flux has deployed all apps on the target cluster."
  exit 1
fi

BACKUP_DIR="$1"

if [ ! -d "$BACKUP_DIR" ]; then
  echo "Error: Backup directory not found: $BACKUP_DIR"
  exit 1
fi

echo "🔄 Restoring from $BACKUP_DIR"

restore_app() {
  local app="$1"
  local namespace="$2"
  local pvc_name="$3"
  local mount_path="$4"
  local archive="$BACKUP_DIR/${app}-data.tar.gz"

  if [ ! -f "$archive" ]; then
    echo "⚠️  No archive found for $app, skipping"
    return
  fi

  echo "📦 Restoring $app..."

  kubectl scale deployment "$app" -n "$namespace" --replicas=0
  kubectl wait --for=jsonpath='{.spec.replicas}'=0 deployment/"$app" -n "$namespace" --timeout=60s 2>/dev/null || sleep 10

  kubectl apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: restore-pod
  namespace: ${namespace}
spec:
  containers:
  - name: restore
    image: busybox:latest
    command: ["sleep", "3600"]
    volumeMounts:
    - name: data
      mountPath: ${mount_path}
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: ${pvc_name}
  restartPolicy: Never
YAML

  kubectl wait --for=condition=ready pod/restore-pod -n "$namespace" --timeout=60s

  kubectl exec -n "$namespace" restore-pod -- tar xzf - -C / < "$archive"

  kubectl delete pod restore-pod -n "$namespace"

  kubectl scale deployment "$app" -n "$namespace" --replicas=1

  echo "✅ $app restored"
}

restore_abs_app() {
  local archive="$BACKUP_DIR/audiobookshelf-data.tar.gz"
  local namespace="audiobookshelf"

  if [ ! -f "$archive" ]; then
    echo "⚠️  No archive found for audiobookshelf, skipping"
    return
  fi

  echo "📦 Restoring audiobookshelf (config + metadata)..."

  kubectl scale deployment audiobookshelf -n "$namespace" --replicas=0
  kubectl wait --for=jsonpath='{.spec.replicas}'=0 deployment/audiobookshelf -n "$namespace" --timeout=60s 2>/dev/null || sleep 10

  # Audiobookshelf has multiple PVCs; mount config and metadata together in one pod
  kubectl apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: restore-pod
  namespace: ${namespace}
spec:
  containers:
  - name: restore
    image: busybox:latest
    command: ["sleep", "3600"]
    volumeMounts:
    - name: config
      mountPath: /config
    - name: metadata
      mountPath: /metadata
  volumes:
  - name: config
    persistentVolumeClaim:
      claimName: audiobookshelf-config
  - name: metadata
    persistentVolumeClaim:
      claimName: audiobookshelf-metadata
  restartPolicy: Never
YAML

  kubectl wait --for=condition=ready pod/restore-pod -n "$namespace" --timeout=60s

  kubectl exec -n "$namespace" restore-pod -- tar xzf - -C / < "$archive"

  kubectl delete pod restore-pod -n "$namespace"

  kubectl scale deployment audiobookshelf -n "$namespace" --replicas=1

  echo "✅ Audiobookshelf restored"
  echo "ℹ️  NOTE: /audiobooks was not included in the backup and must be restored separately"
}

# Restore each app
restore_app "linkding" "linkding" "linkding-data-pvc" "/etc/linkding/data"
restore_app "mealie" "mealie" "mealie-data" "/app/data"
restore_abs_app
restore_app "n8n" "naten" "n8n-data" "/home/node/.n8n"

echo ""
echo "✅ Restore complete!"
echo ""
echo "Verify each app:"
echo "  kubectl logs -n linkding deployment/linkding"
echo "  kubectl logs -n mealie deployment/mealie"
echo "  kubectl logs -n audiobookshelf deployment/audiobookshelf"
echo "  kubectl logs -n naten deployment/n8n"
