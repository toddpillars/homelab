---
title: Storage & Horizontal Scaling
tags: [kubernetes, k3s, storage, local-path, scaling]
created: 2026-08-04
author: Todd Pillars
---

# Storage & Horizontal Scaling

## Current topology

The cluster runs a single K3s node today. Every `PersistentVolumeClaim` in
the repo uses the `local-path` storage class — data lives on the node's
local disk, provisioned on-demand, with no network storage layer in front
of it.

## The tradeoff `local-path` makes

`local-path` is simple to operate and has no external dependency (no NFS
server, no Ceph cluster, no cloud block-storage API to integrate with), which
is the right tradeoff for a single-node homelab. The cost of that simplicity
is that a volume is **bound to whichever node created it**. There's no
migration or rebalancing built in — a pod that needs a given PVC can only be
scheduled onto the node that PVC's data actually lives on.

## Why that matters for adding a second node

A second node is planned, to offload AI-inference-adjacent workloads from
the current single node. With `local-path`, that's not simply "join a node
and get more capacity" — every existing PVC's data stays pinned to the
original node unless it's deliberately migrated, so:

- Workloads with `local-path` volumes can't be rescheduled onto the new node
  for load-balancing purposes without first moving their data.
- Any workload that *should* end up on the new node (e.g. something that
  wants to be co-located with new AI-inference-adjacent capacity) needs its
  PVC data copied over as part of the migration, not just a pod
  reschedule.
- Cluster upgrade ordering matters here too: the node join is planned to
  happen after the control-plane K3s version is upgraded (stepping through
  intermediate minor versions rather than jumping), so the new node joins
  a cluster already at the target version instead of also being a version
  migration.

## Why not switch storage classes now

Moving to a networked storage class (e.g. Longhorn, NFS-backed
provisioning) would remove the node-pinning problem, but it's not adopted
yet — it adds an operational component (a storage controller to run,
monitor, and upgrade) that isn't justified until there's a concrete second
workload placement to support. The plan is to treat storage migration as its
own deliberate step at the point the second node is actually joined, rather
than provision for it speculatively today.
