# homelab

A GitOps-managed Kubernetes cluster, reconciled continuously by **FluxCD**
from this repository. Everything — workloads, ingress, TLS, secrets,
monitoring, and the dependency ordering between them — is declarative YAML
under version control. There's a single environment, `staging`, run with the
same discipline you'd expect from a production system: encrypted secrets,
tested backup/restore, and a controlled upgrade path rather than ad hoc
`kubectl apply`.

This README covers the architecture, the tradeoffs behind it, the AI/LLM
stack running on top of it, and how backup, observability, and upgrades are
handled. For the full inventory of running applications and day-to-day
operational commands, see [`CLAUDE.md`](CLAUDE.md). For deep-dive runbooks,
see [`docs/operations/`](docs/operations/).

## Architecture & design decisions

**Git as the only source of truth.** Flux watches three `Kustomization`
entrypoints in `clusters/staging/` — `apps`, `infrastructure`, and
`monitoring` — applied in that order via explicit `dependsOn` relationships.
The ordering isn't arbitrary: `apps/` reconciles first and deliberately
avoids depending on any CRD owned by `infrastructure/` (like cert-manager's
`Certificate`), so a fresh cluster can bootstrap without a circular
dependency. That constraint is why TLS is issued two different ways
depending on which tree a host lives in — an `ingress-shim` annotation on the
`Ingress` for `apps/`-tree hosts (defers cert issuance to cert-manager once
it exists, no CRD required up front), versus an explicit `Certificate`
resource for `infrastructure/`-tree hosts that already reconcile after
cert-manager is installed. Same outcome, two mechanisms, chosen for where
each app sits in the dependency graph rather than by preference.

**One structural pattern for every app.** Every application and every
infrastructure controller follows the same `base/` + `staging/` overlay
split (Kustomize): base owns the namespace/deployment/service/storage, the
overlay adds ingress and environment-specific patches. New apps are additive
— a new directory plus one line in a parent `kustomization.yaml` — rather
than a special case to design around.

**Secrets: SOPS + AGE, not a KMS-backed manager.** Every secret is encrypted
in place as a `*.enc.yaml` file and decrypted at reconcile time by Flux using
an AGE key held only as a cluster secret. The SOPS config restricts
encryption to `data`/`stringData` fields, so a `git diff` on a secret still
shows a legible, reviewable change (keys, structure, everything but values)
instead of an opaque blob. The tradeoff accepted here is operational
simplicity over centralized secret rotation/audit — the right call for a
single-operator cluster, not necessarily for a multi-tenant one.

**Exposure model as a security boundary, not just routing.** Internet-facing
hosts go through a Cloudflare Tunnel — outbound-only from the cluster, no
inbound port ever opened on the network. LAN-only hosts instead get a
Traefik `Ingress` with a publicly-trusted TLS cert issued via Let's Encrypt
over Cloudflare DNS-01, so "internal" doesn't mean "self-signed cert and a
browser warning." The one intentional exception to "everything is GitOps" is
the tunnel's routing table itself: it's managed in the Cloudflare dashboard,
not git, because the tunnel daemon hot-reloads dashboard changes with zero
downtime while a git-driven config would require a rollout. That's
documented explicitly in the repo as a deliberate exception, not drift
someone will "fix" later.

**Vendoring around a broken upstream dependency.** One app's only published
Helm chart turned out to be broken — bundled sub-charts pointed at container
images the upstream vendor had retired, so the chart failed on install. The
community fix existed only as an open, unmerged pull request. Rather than
depend on a fork branch staying alive indefinitely, the fixed chart was
vendored in-tree and pinned to a specific revision, sourced from the same
Flux `GitRepository` already used for this repo. It's the one app in the
cluster sourced that way; every other Helm-based app pulls from a proper
`HelmRepository`. That asymmetry is intentional and documented at the point
of use, so it doesn't read as an oversight to the next person (or agent)
touching the file.

## AI / LLM stack

Two apps and one monitoring pattern make up the AI-facing surface of this
cluster today, with more planned:

- **n8n** — the workflow/automation layer, exposed through the tunnel, with
  its own Prometheus metrics enabled and execution history pruned on a
  rolling window so state doesn't grow unbounded.
- **open-webui** — the chat interface. It deliberately runs no inference
  itself; it's configured to call out to a LAN-hosted llama.cpp instance. That
  split keeps GPU-bound inference compute off the Kubernetes node entirely
  and treats "chat UI" and "model serving" as separate concerns with
  separate scaling and hardware requirements.
- **Bridging non-Kubernetes inference servers into Prometheus.** LAN-hosted
  llama.cpp inference servers (running outside the cluster, on bare metal)
  are scraped using the same `ServiceMonitor`
  contract as every in-cluster workload — a headless `Service` paired with a
  hand-authored `Endpoints` object stands in for kube-proxy's usual
  service-discovery, so a process that was never scheduled by Kubernetes
  still shows up in the same Grafana dashboards as everything that was. One
  monitoring integration point regardless of where the workload actually
  runs.

**Roadmap:** the next phase of this stack is a self-hosted AI platform
layer — vector storage, local search, workflow orchestration, and LLM
observability/tracing — designed to sit alongside n8n and open-webui rather
than replace them. This is in-progress design work, not yet running in the
cluster, and is called out here as direction rather than a shipped feature.

## Observability stack

- **kube-prometheus-stack** (Prometheus + Alertmanager + Grafana) is the
  metrics backbone. Prometheus's TSDB is backed by a PVC rather than the
  chart's default `emptyDir`, with retention and retention-size tuned
  together so Prometheus trims old data on its own before the volume fills
  — a metrics history that survives pod reschedules without an unbounded
  disk-fill risk. Grafana sits behind Traefik with its own trusted TLS cert
  and admin credentials sourced from a SOPS-encrypted secret, never a chart
  default.
- **Loki** handles logs, wired into the same Grafana as a datasource rather
  than standing up a second Grafana instance — one pane of glass for metrics
  and logs, not two dashboards to keep in sync.
- **ServiceMonitors as the uniform integration contract.** Every workload
  that needs to be observed — in-cluster app, datastore exporter, or a
  bare-metal inference server outside Kubernetes entirely — is onboarded the
  same way: a `ServiceMonitor` pointed at a `Service`. New apps get
  dashboards and alerting by following one well-understood pattern instead
  of a bespoke integration per data source.
- **Self-hosted by choice, not by default.** A managed observability SaaS
  would be less operational overhead, but self-hosting keeps all metrics and
  log data on infrastructure that's actually owned, and it means working
  directly with the Prometheus Operator's CRDs (`ServiceMonitor`,
  `PrometheusRule`) rather than a vendor's abstraction over them.

## Backup & restore

GitOps already backs up *configuration* — every Deployment, ConfigMap, and
HelmRelease is reconstructable from `git clone` alone. What actually needs a
backup strategy is **stateful data on persistent volumes**, and that's
handled in tiers:

1. **Ad hoc** — a `kubectl exec ... tar czf -` one-liner per app, good for a
   quick snapshot before a risky change.
2. **Scripted** — `scripts/backup-cluster.sh` and `scripts/restore-cluster.sh`
   automate the same pattern across every stateful app in one run: scale
   down, stream the PVC contents through a temporary pod, tar it up (or
   restore it back in), scale up. This is the routine path, and it also
   captures Flux's own state (GitRepository/Kustomization/HelmRelease
   objects) and the SOPS AGE key itself, since that key is the one piece of
   this cluster that cannot be reconstructed from git.
3. **Not yet running: Velero.** Named in the runbook as the natural next
   step for scheduled, storage-backend-integrated backups. It isn't running
   today because the operational overhead of standing up and maintaining it
   isn't yet justified at this cluster's current scale — a judgment call
   revisited as the cluster grows, not an oversight.

Large, derived, or easily-re-sourced data (media libraries, caches) is
deliberately excluded from the routine backup path and handled separately —
backing up everything uniformly would mean the backup job runtime and
storage footprint are dominated by data that isn't actually irreplaceable.

Recovery targets (RTO/RPO) are defined per failure scenario — single-app
data loss, full cluster rebuild, configuration-only drift — each with a
different acceptable downtime and data-loss window; see
[`docs/operations/backup-restore.md`](docs/operations/backup-restore.md) for
the current targets and the full restore procedure.

## Upgrade & migration path

**Dependency updates are automated but never auto-applied.** Renovate opens
PRs for image tags, Helm chart versions, and Flux manifests, but nothing
auto-merges — every change gets human review before it reaches the cluster.
Guardrails are encoded as policy, not just habit: a stateful datastore's
major-version bumps are disabled by an explicit Renovate rule, with the
reasoning captured in the rule itself — a major version needs an in-place
data migration (dump/restore or an in-place upgrade tool), and a tag change
in a Deployment spec can't perform that migration safely on its own. Related
images that must move together are grouped into a single PR instead of
landing as uncoordinated, individually-mergeable changes.

**Cluster upgrades step through intermediate minor versions** rather than
jumping straight to the target release, and are preceded by a datastore
backup — in this cluster's case the k3s SQLite datastore (single control
plane, no etcd), backed up as a directory copy rather than an etcd
snapshot.

**Horizontal growth has a specific, named migration wrinkle.** Every PVC in
this cluster uses `local-path` storage, which binds data to whichever node
created the volume. Adding a second node isn't just "more capacity" —
it changes how workload scheduling and data placement have to be reasoned
about, since a pod can't freely move to a node that doesn't have its data.
That's an open, planned piece of work, tracked as a migration problem to
solve deliberately rather than something to discover mid-upgrade.

**Node maintenance as an ongoing, automated concern.** Every image update
pulled to the node leaves old container image layers behind, and Kubernetes
only garbage-collects them once disk pressure is already high. Rather than
wait for that threshold, a scheduled job runs a prune on a regular cadence,
turning what would otherwise be a slow, silent disk-fill into a routine,
observable maintenance task.

## Tech stack

| Layer | Tool |
|---|---|
| Cluster | K3s |
| GitOps / reconciliation | FluxCD |
| Manifest management | Kustomize (base/overlay) |
| Package management | Helm |
| Secrets | SOPS + AGE |
| Ingress | Traefik |
| TLS | cert-manager (Let's Encrypt via Cloudflare DNS-01) |
| Internet exposure | Cloudflare Tunnel |
| Metrics | kube-prometheus-stack (Prometheus, Alertmanager, Grafana) |
| Logs | Loki |
| Dependency updates | Renovate |

## Repo layout

```
clusters/staging/       Flux Kustomization entrypoints (what Flux watches)
apps/
  base/                  Base manifests per application
  staging/               Staging overlays (ingress, env-specific patches)
infrastructure/
  controllers/
    base/                Base infra controller manifests and HelmReleases
    staging/              Staging overlays
monitoring/
  controllers/            kube-prometheus-stack + Loki HelmReleases
  configs/                Cluster-specific monitoring config
scripts/                 Backup/restore automation
docs/operations/         Runbooks: backup/restore, per-app deep dives
```

## Further reading

- [`CLAUDE.md`](CLAUDE.md) — full application inventory, operational
  commands, and conventions.
- [`docs/operations/backup-restore.md`](docs/operations/backup-restore.md) —
  full backup/restore procedures and recovery targets.
- [`docs/operations/postiz.md`](docs/operations/postiz.md) — a full
  deployment writeup, including the vendored-chart story referenced above.
- [`docs/operations/grafana-sops-credentials.md`](docs/operations/grafana-sops-credentials.md)
  — Grafana credential management via SOPS.
