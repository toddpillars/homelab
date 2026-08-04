---
title: Dependency and TLS Design
tags: [kubernetes, fluxcd, gitops, cert-manager, tls]
created: 2026-08-04
author: Todd Pillars
---

# Dependency and TLS Design

## Flux reconciliation order

Flux watches three `Kustomization` entrypoints in `clusters/staging/`:

- `apps.yaml` → `./apps/staging`
- `infrastructure.yaml` → `./infrastructure/controllers/staging` (`dependsOn: apps`)
- `monitoring.yaml` → `./monitoring/controllers/staging` + `./monitoring/configs/staging` (`dependsOn: infrastructure`)

The ordering is explicit and load-bearing: `apps/` reconciles first, so
nothing in that tree can depend on a CRD that's only installed by
`infrastructure/` — most importantly, cert-manager's `Certificate` CRD.
Without that constraint, a fresh cluster bootstrap would deadlock: `apps/`
waiting on a CRD that `infrastructure/` hasn't installed yet, while
`infrastructure/` waits on `apps/` to finish first.

## Why TLS is issued two different ways

That ordering constraint is why this repo has two different mechanisms for
getting a trusted cert onto an `Ingress`, chosen by which tree the host lives
in rather than by preference:

- **`apps/`-tree hosts** (e.g. mealie, audiobookshelf-internal, homepage) use
  the `cert-manager.io/cluster-issuer` **ingress-shim annotation** on the
  `Ingress` resource. This defers cert issuance to cert-manager once it
  exists — no cert-manager CRD needs to land in the `apps/` Kustomization,
  which reconciles before `infrastructure/` even runs.
- **`infrastructure/`-tree hosts** (e.g. postiz, temporal) use an explicit
  `Certificate` resource, since that tree already reconciles *after*
  cert-manager is installed and its CRDs are guaranteed to exist.

Both paths terminate in the same place: a `ClusterIssuer`
(`letsencrypt-staging` / `letsencrypt-prod`) that solves **DNS-01 via
Cloudflare**, so LAN-only hosts still get a publicly-trusted certificate
instead of a self-signed one a browser has to be told to trust.

## Net effect

One structural rule — "don't create a circular CRD dependency across the
Flux ordering" — determines which of two equivalent-outcome TLS mechanisms
an app uses. It's a deliberate tradeoff of two code paths to keep instead of
a single mechanism that would force a change to the reconciliation order
(and reintroduce the bootstrap deadlock) every time a new LAN-only host is
added.
