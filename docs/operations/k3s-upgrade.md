# k3s Server Upgrade

## Overview

The cluster runs a **single k3s server** on a LAN Ubuntu box. The Mac in this
repo is only the admin workstation — every command in the "on the server"
sections below is run over SSH or console on the server itself; every
verification step is run from the workstation with `kubectl` / `flux`.

Key facts about this server:

- **Datastore is the default SQLite (kine), not etcd.** There is no
  `--cluster-init` and no etcd pods, so `k3s etcd-snapshot` does **not** apply.
  The datastore backup is a tarball of `/var/lib/rancher/k3s/server/db/`.
- **Install args are not persisted by the installer.** The get.k3s.io script
  rewrites `/etc/systemd/system/k3s.service` from whatever you pass it. The
  server currently runs with exactly `server --write-kubeconfig-mode 644` and no
  `/etc/rancher/k3s/config.yaml`. **Always replay the full arg list** on every
  install/upgrade run — check `ExecStart` in the service file first if unsure.
- **k3s's bundled helm-controller is active** and manages the packaged `traefik`
  / `traefik-crd` `HelmChart` resources in `kube-system`. A k3s minor upgrade
  that bundles a newer traefik chart will trigger an automatic `helm upgrade` of
  traefik (new pod rolls out). This is expected. The helm-install Job may log a
  transient `Error` immediately after the k3s restart while the API server is
  still settling, then succeed on retry.

## Version-skew rule

k3s follows the Kubernetes version-skew policy — **upgrade one minor at a time**.
Skipping a minor (e.g. 1.34 → 1.36 directly) is unsupported. Step through each
intermediate minor, verifying cluster health between hops.

Check the current latest patch per channel:

```bash
curl -s https://update.k3s.io/v1-release/channels \
  | python3 -c "import sys,json;[print(c['name'],'->',c['latest']) for c in json.load(sys.stdin)['data'] if c['name'].startswith('v1.') or c['name'] in ('stable','latest')]"
```

## Pre-flight (from the workstation)

```bash
kubectl get nodes -o wide                              # node Ready, note current version
flux get kustomizations                                # all Ready
flux get helmreleases -A                               # all Ready
kubectl get pods -A | grep -Ev 'Running|Completed'     # expect no rows
./scripts/backup-cluster.sh                            # PVC data + Flux state + SOPS key
```

## Datastore backup (on the server)

```bash
sudo systemctl stop k3s
sudo tar czf /root/k3s-db-backup-$(date +%F).tgz -C /var/lib/rancher/k3s/server db/
sudo cp -a /etc/rancher/k3s /root/k3s-etc-backup-$(date +%F)   # kubeconfig + node-token
sudo systemctl start k3s
```

Wait for `kubectl get nodes` to report Ready again from the workstation before
continuing.

## Confirm current install args (on the server)

```bash
cat /etc/systemd/system/k3s.service | grep -A20 ExecStart
ls /etc/rancher/k3s/config.yaml* /etc/rancher/k3s/config.yaml.d/ 2>/dev/null
```

Everything after `server` on the `ExecStart` line must be replayed in the
upgrade command below.

## Per-hop upgrade (on the server)

For each intermediate minor, then the final target:

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=<vX.Y.Z+k3s1> \
  sh -s - server --write-kubeconfig-mode 644
```

The installer swaps the binary and restarts the k3s systemd unit in place.
Expect a ~10–30s API-server blip; containerd workloads keep running.

### Verify after each hop (from the workstation)

All of these must pass before starting the next hop:

```bash
kubectl get nodes -o wide                              # Ready at the new version
kubectl get node <node> -o jsonpath='{.metadata.annotations.k3s\.io/node-args}'
                                                       # confirms replayed args stuck
kubectl get pods -A | grep -Ev 'Running|Completed'     # no unexpected rows (allow a few min)
kubectl get apiservices | grep -i false                # no unavailable API services
flux get kustomizations                                # all Ready
flux get helmreleases -A                               # all Ready
```

Flux often shows `apps` "Reconciliation in progress" and `infrastructure`
"dependency ... is not ready" for a minute or two after the restart. If
`infrastructure` stays stuck on a stale dependency message after `apps` goes
Ready, nudge it:

```bash
flux reconcile kustomization infrastructure
```

Ingress spot-check (works from the workstation even without LAN DNS, by resolving
the hostname to the server's IP):

```bash
for h in mls hms absi grs postiz temporal; do
  code=$(curl -sS -k -o /dev/null -w "%{http_code}" --max-time 15 \
    --resolve $h.toddpillars.com:443:<server-ip> https://$h.toddpillars.com/)
  echo "$h -> $code"   # 200/302/307 are all fine (login redirects)
done
```

Let each hop soak a few minutes and investigate any regression before proceeding.

## Post-upgrade

```bash
kubectl version                          # Server Version = target
./scripts/backup-cluster.sh              # fresh known-good snapshot
```

Watch Flux / Renovate over the next day for any HelmRelease that needs a bump for
the newer Kubernetes API.

## Rollback

A single-minor k3s upgrade on SQLite rarely needs a full rollback — the binary
swap is reversible. The datastore tarball is the real safety net.

```bash
# on the server
sudo systemctl stop k3s
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=<previous-version> \
  sh -s - server --write-kubeconfig-mode 644
sudo systemctl stop k3s
sudo rm -rf /var/lib/rancher/k3s/server/db
sudo tar xzf /root/k3s-db-backup-<date>.tgz -C /var/lib/rancher/k3s/server
sudo systemctl start k3s
```

## Adding a second node later

Join the agent at a **matched version**:

```bash
# on the new node
curl -sfL https://get.k3s.io | K3S_URL=https://<server-ip>:6443 \
  K3S_TOKEN=<node-token> INSTALL_K3S_VERSION=<server-version> sh -
# node-token = sudo cat /var/lib/rancher/k3s/server/node-token   (on the server)
```

Once two nodes exist: always upgrade the **server first**, and keep the agent at
most one minor behind the server.

## History

| Date       | From          | To            | Notes |
|------------|---------------|---------------|-------|
| 2026-09-05 | `v1.34.3+k3s1` | `v1.36.4+k3s1` | Two hops via `v1.35.8+k3s1`. Bundled traefik chart auto-upgraded v37 → v40.1.4 (traefik `3.7.8`) on the 1.35 hop; helm-install Job errored once transiently then succeeded. containerd `2.1.5` → `2.3.4`. No app impact. |
