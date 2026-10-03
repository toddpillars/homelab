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
  local kind="${5:-deployment}"   # workload kind to scale (deployment | statefulset)
  local archive="$BACKUP_DIR/${app}-data.tar.gz"

  if [ ! -f "$archive" ]; then
    echo "⚠️  No archive found for $app, skipping"
    return
  fi

  echo "📦 Restoring $app..."

  kubectl scale "$kind" "$app" -n "$namespace" --replicas=0
  kubectl wait --for=jsonpath='{.spec.replicas}'=0 "$kind"/"$app" -n "$namespace" --timeout=60s 2>/dev/null || sleep 10

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

  kubectl exec -i -n "$namespace" restore-pod -- tar xzf - -C / < "$archive"

  kubectl delete pod restore-pod -n "$namespace"

  kubectl scale "$kind" "$app" -n "$namespace" --replicas=1

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

  kubectl exec -i -n "$namespace" restore-pod -- tar xzf - -C / < "$archive"

  kubectl delete pod restore-pod -n "$namespace"

  kubectl scale deployment audiobookshelf -n "$namespace" --replicas=1

  echo "✅ Audiobookshelf restored"
  echo "ℹ️  NOTE: /audiobooks was not included in the backup and must be restored separately"
}

restore_garage() {
  local namespace="garage"
  local archive="$BACKUP_DIR/garage-data.tar.gz"

  if [ ! -f "$archive" ]; then
    echo "⚠️  No archive found for garage, skipping"
    return
  fi

  echo "📦 Restoring garage (meta + data)..."

  kubectl scale statefulset garage -n "$namespace" --replicas=0
  kubectl wait --for=jsonpath='{.spec.replicas}'=0 statefulset/garage -n "$namespace" --timeout=60s 2>/dev/null || sleep 10

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
    - name: meta
      mountPath: /mnt/meta
    - name: data
      mountPath: /mnt/data
  volumes:
  - name: meta
    persistentVolumeClaim:
      claimName: meta-garage-0
  - name: data
    persistentVolumeClaim:
      claimName: data-garage-0
  restartPolicy: Never
YAML

  kubectl wait --for=condition=ready pod/restore-pod -n "$namespace" --timeout=60s

  # Drop any existing live DB so it can't be mixed with the restored one. Data
  # blocks are content-addressed, so leftover blocks are harmless and kept.
  kubectl exec -n "$namespace" restore-pod -- sh -c 'rm -rf /mnt/meta/db.lmdb*'

  kubectl exec -i -n "$namespace" restore-pod -- tar xzf - -C /mnt < "$archive"

  # The backup holds a consistent snapshot, not a live db.lmdb: promote the
  # newest snapshot (ISO timestamps sort lexically) to be the live database.
  kubectl exec -n "$namespace" restore-pod -- sh -c '
    set -e
    snap=$(ls -1 /mnt/meta/snapshots | sort | tail -n 1)
    [ -n "$snap" ] || { echo "no snapshot in archive" >&2; exit 1; }
    # Snapshots are a single LMDB file, but the live db.lmdb is a directory
    # holding data.mdb — Garage fails to open a bare file at that path.
    mkdir /mnt/meta/db.lmdb
    cp -a "/mnt/meta/snapshots/$snap/db.lmdb" /mnt/meta/db.lmdb/data.mdb
    chown -R 1000:1000 /mnt/meta/db.lmdb
    echo "promoted snapshot $snap"
  '

  kubectl delete pod restore-pod -n "$namespace"

  kubectl scale statefulset garage -n "$namespace" --replicas=1

  echo "✅ garage restored"
  echo "ℹ️  NOTE: verify with: kubectl exec -n garage garage-0 -- /garage status"
}

# Restore each app
restore_app "linkding" "linkding" "linkding-data-pvc" "/etc/linkding/data"
restore_app "mealie" "mealie" "mealie-data" "/app/data"
restore_abs_app
restore_app "n8n" "naten" "n8n-data" "/home/node/.n8n"
restore_app "open-webui" "open-webui" "open-webui" "/app/backend/data" "statefulset"
restore_garage

echo ""
echo "✅ Restore complete!"
echo ""
echo "Verify each app:"
echo "  kubectl logs -n linkding deployment/linkding"
echo "  kubectl logs -n mealie deployment/mealie"
echo "  kubectl logs -n audiobookshelf deployment/audiobookshelf"
echo "  kubectl logs -n naten deployment/n8n"
echo "  kubectl logs -n open-webui statefulset/open-webui"
echo "  kubectl exec -n garage garage-0 -- /garage status"
