# Garage (S3-compatible object store)

## Overview

Garage runs as a single-instance HelmRelease under
`infrastructure/controllers/base/garage/`, LAN-only at
`https://s3.toddpillars.com`. Key facts:

- **Single node, single replica.** The cluster is one k3s node today, so
  `deployment.replicaCount: 1` and `garage.replicationFactor: 1` — no
  redundancy at the Garage layer. Revisit if a second node ever joins.
- **Chart sourced via a Flux `GitRepository`**, not a `HelmRepository` — Garage
  doesn't publish a hosted chart index. Pinned to a release tag
  (`base/garage/repository.yaml`), not vendored in-tree.
- **`rpcSecret` is chart-managed**, not SOPS — left unset in `values`, so the
  chart generates one itself and stores it in a Secret. No manual secret
  handling needed for Garage's own internals.
- **Cluster layout and buckets/keys are not declarative.** Garage requires a
  one-time (and per-bucket) CLI bootstrap via `kubectl exec`, covered below.

## First-time cluster layout bootstrap

Run once, after the `garage-0` pod is `Running`/`Ready`:

```bash
kubectl get pods -n garage                                    # wait for garage-0 Ready

kubectl exec -n garage garage-0 -- /garage status              # note the node ID
kubectl exec -n garage garage-0 -- /garage layout assign -z home -c 20G <node_id>
kubectl exec -n garage garage-0 -- /garage layout apply --version 1

kubectl exec -n garage garage-0 -- /garage status               # confirm node shows healthy w/ assigned capacity
```

`-z home` is an arbitrary zone label (single-node, so it doesn't matter); `-c
20G` should match (or be ≤) the `persistence.data.size` set in
`base/garage/release.yaml`.

## Creating a bucket + access key for a consuming app

```bash
kubectl exec -n garage garage-0 -- /garage bucket create <bucket-name>
kubectl exec -n garage garage-0 -- /garage key create <key-name>
kubectl exec -n garage garage-0 -- /garage bucket allow \
  --read --write --owner <bucket-name> --key <key-name>
kubectl exec -n garage garage-0 -- /garage key info <key-name>   # prints Key ID + Secret Key
```

Store the resulting Key ID/Secret in the **consuming app's own** SOPS-encrypted
`*.enc.yaml` Secret (same convention as e.g. `linkding-secret.enc.yaml`) — never
commit them in plaintext. The S3 endpoint is `https://s3.toddpillars.com`,
region `garage` (chart default).

## Health checks

```bash
flux get sources git garage -n flux-system
flux get helmrelease garage -n garage
kubectl get pods -n garage
kubectl get certificate garage-tls -n garage                   # should be READY=True
kubectl exec -n garage garage-0 -- /garage status
```

Quick S3 API smoke test from a LAN machine with a key created above:

```bash
aws s3 --endpoint-url https://s3.toddpillars.com ls
```

## Grafana dashboard

`monitoring/controllers/base/kube-prometheus-stack/garage-dashboard.configmap.yaml`
provisions Garage's official dashboard (from
`script/telemetry/grafana-garage-dashboard-prometheus.json` upstream), auto-loaded
by the kube-prometheus-stack Grafana sidecar via the `grafana_dashboard: "1"`
label — same mechanism as the Postiz dashboards. Find it in Grafana under
**Garage**.

Two fixes were needed to make the upstream JSON actually work here, both already
applied:

- **Datasource**: upstream bakes in a raw `${DS_DS_PROMETHEUS}` placeholder meant
  for Grafana's interactive *Import* wizard, which the sidecar provisioning path
  doesn't resolve. Replaced with the repo's standard `${datasource}` template
  variable (same pattern as the Postgres/Redis dashboards).
- **`job` label**: every panel query hardcodes `job="garage"`, but Prometheus
  Operator's default `job` label for our ServiceMonitor was `garage-metrics` (the
  discovered Service's name) — a mismatch that would've silently rendered every
  panel empty. Fixed by setting `jobLabel: app.kubernetes.io/name` on
  `garage-servicemonitor.yaml`, so scraped metrics carry `job="garage"` instead.

**Known-empty panels** (not a bug — confirmed against this Garage v2.4.1
instance's actual `/metrics` output):
- **Disk I/O**: queries `block_bytes_read`/`block_bytes_written`, which don't
  exist in this Garage version's metric set (likely renamed/removed upstream
  since the dashboard was authored).
- **Web requests / Web errors**: query `web_request_counter`/`web_error_counter`,
  which are never emitted because we don't run Garage's web-hosting feature
  (`ingress.s3.web.enabled: false`, `[s3_web]` unconfigured). Revisit if the web
  endpoint is ever enabled.

## Known gotchas

- **Exact chart-generated resource names weren't confirmed against a live
  deploy at write time.** The ServiceMonitor's `port: metrics` and endpoint
  shape are confirmed against the chart's own `templates/service.yaml` /
  `templates/servicemonitor.yaml` source at v2.4.1, but the Ingress
  (`staging/garage/ingress.yaml`, `service.name: garage`) and the
  ServiceMonitor's `selector.matchLabels` still assume the chart's standard
  Helm-fullname naming and default selector labels. After the first
  reconcile, check `kubectl get svc -n garage --show-labels` and fix either
  manifest if they don't match.
- **Renovate may not auto-bump this chart.** It's sourced via
  `GitRepository.spec.ref.tag`, not a `HelmRepository` chart version like
  `open-webui` — Renovate's flux/helm managers are tuned for the latter.
  Watch for this after the first release cycle; may need a manual bump or a
  custom regex manager.
- **Admin API has no auth token configured** — the chart doesn't expose
  `adminToken`/`metricsToken` values. Acceptable since it's ClusterIP-only
  (only reachable from inside the cluster), but reconsider if that changes.
