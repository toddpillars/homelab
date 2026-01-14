---
title: Grafana SOPS - Quick Reference
tags: [kubernetes, cheatsheet, quick-reference]
created: 2026-01-14
---

# Grafana SOPS Credentials - Quick Reference Card

## 🎯 Essential Commands

### View Credentials
```bash
# Username
kubectl get secret grafana-admin-credentials -n monitoring -o jsonpath='{.data.admin-user}' | base64 -d

# Password
kubectl get secret grafana-admin-credentials -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d
```

### Edit Encrypted Secret
```bash
# Opens in $EDITOR, auto-encrypts on save
sops monitoring/controllers/base/kube-prometheus-stack/grafana-credentials.enc.yaml
```

### Create New Encrypted Secret
```bash
# 1. Create unencrypted
cat > /tmp/grafana-creds.yaml <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin-credentials
  namespace: monitoring
type: Opaque
stringData:
  admin-user: admin
  admin-password: new-password
YAML

# 2. Encrypt
sops --encrypt /tmp/grafana-creds.yaml > \
  monitoring/controllers/base/kube-prometheus-stack/grafana-credentials.enc.yaml

# 3. Clean up
rm /tmp/grafana-creds.yaml
```

### Force Reconciliation
```bash
flux reconcile kustomization monitoring-controllers --with-source
```

## 🔍 Verification Checklist

| Check | Command | Expected Result |
|-------|---------|-----------------|
| Secret exists | `kubectl get secret grafana-admin-credentials -n monitoring` | Found with 2 data keys |
| Values decrypted | `kubectl get secret grafana-admin-credentials -n monitoring -o jsonpath='{.data.admin-user}' \| base64 -d` | Shows `admin` (not `ENC[...]`) |
| Grafana running | `kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana` | 3/3 Running |
| Flux healthy | `flux get kustomizations` | monitoring-controllers: True |
| HelmRelease OK | `kubectl get helmrelease -n monitoring` | kube-prometheus-stack: True |

## 🐛 Quick Troubleshooting

| Problem | Quick Fix |
|---------|-----------|
| **Secret has `ENC[...]` text** | Add decryption to `clusters/staging/monitoring.yaml` |
| **CreateContainerConfigError** | Secret missing `admin-user` key - recreate with both keys |
| **Cannot decrypt locally** | Extract AGE key: `kubectl get secret sops-age -n flux-system -o jsonpath='{.data.age\.agekey}' \| base64 -d > ~/.config/sops/age/keys.txt` |
| **Wrong namespace error** | Check `namespace: monitoring` in encrypted file (common typo: `monitorin`) |
| **Pod won't start** | Check: `kubectl describe pod -n monitoring -l app.kubernetes.io/name=grafana` |

## 📁 Critical Files
```
📦 monitoring/controllers/base/kube-prometheus-stack/
├── 🔐 grafana-credentials.enc.yaml     # Encrypted secret (SOPS)
├── 📝 kustomization.yaml               # Must include grafana-credentials.enc.yaml
├── ⚙️  release.yaml                     # References existingSecret
└── 📋 repository.yaml

📦 clusters/staging/
└── ⚡ monitoring.yaml                   # Must have decryption enabled

📦 docs/operations/
├── 📖 grafana-sops-credentials.md      # Comprehensive documentation
└── ⚡ grafana-sops-quick-reference.md  # This quick reference

📦 Repository Root
└── 🔧 .sops.yaml                        # SOPS configuration
```

## 🔑 Critical Configuration Snippets

### Decryption Configuration (clusters/staging/monitoring.yaml)
```yaml
spec:
  decryption:          # ⚠️ MUST BE PRESENT
    provider: sops
    secretRef:
      name: sops-age
```

### HelmRelease Configuration (release.yaml)
```yaml
values:
  grafana:
    admin:
      existingSecret: grafana-admin-credentials
      userKey: admin-user
      passwordKey: admin-password
```

### Kustomization Resources (kustomization.yaml)
```yaml
resources:
  - namespace.yaml
  - repository.yaml
  - release.yaml
  - grafana-credentials.enc.yaml  # Include encrypted secret
```

## 🚨 Emergency Procedures

### Password Reset
```bash
kubectl delete secret grafana-admin-credentials -n monitoring
flux reconcile helmrelease kube-prometheus-stack -n monitoring
# Get new password:
kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath="{.data.admin-password}" | base64 -d
```

### Backup AGE Key
```bash
kubectl get secret sops-age -n flux-system -o jsonpath='{.data.age\.agekey}' | base64 -d > age-key-backup.txt
# Store securely in password manager!
```

### Restore AGE Key
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: sops-age
  namespace: flux-system
type: Opaque
data:
  age.agekey: $(cat age-key-backup.txt | base64 -w0)
