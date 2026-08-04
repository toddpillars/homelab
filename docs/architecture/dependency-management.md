---
title: Dependency & Upgrade Policy
tags: [renovate, gitops, upgrades, kubernetes]
created: 2026-08-04
author: Todd Pillars
---

# Dependency & Upgrade Policy

Renovate opens pull requests for image tags, Helm chart versions, and Flux
manifests across the repo. It proposes changes; it never applies them.

## Nothing auto-merges

Every dependency PR — image bump, chart bump, Flux manifest change — gets
human review before it reaches the cluster. This is a deliberate departure
from Renovate's more common "auto-merge patch/minor" configuration: on a
single-operator homelab, the review itself is cheap, and the failure mode of
an unreviewed bad bump (a broken migration, a changed default) is expensive
enough to be worth the friction.

## Guardrails are policy, not habit

Two rules in `renovate.json` encode judgment calls as enforced configuration
rather than something a reviewer has to remember every time:

- **Stateful datastore majors are disabled.** Postgres major-version bumps
  are blocked by an explicit `packageRules` entry, with the reasoning
  captured in the rule's own `description` field: a major version needs an
  in-place data migration (`pg_upgrade` or a dump/restore), and a container
  tag change in a Deployment spec cannot perform that migration safely on
  its own. A minor/patch bump is just a new binary; a major bump is a data
  operation that has to be done deliberately, outside of Renovate's normal
  flow.
- **Coupled images are grouped.** Images that belong to one logical stack
  (app + its exporters/sidecars) are grouped into a single PR via
  `groupName`, instead of landing as several independently-mergeable PRs
  that could put the stack into a half-upgraded state if only some of them
  are merged.

## What this buys

The result is a dependency pipeline that stays automated (nobody is manually
checking upstream release pages) without being unattended — every change
that reaches the cluster passed through both an automated proposal and a
human decision, and the one class of change that machinery genuinely
shouldn't auto-apply (a stateful major version) is prevented at the policy
level instead of relying on the reviewer to catch it every single time.
