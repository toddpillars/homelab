# Postiz Helm Chart

A Helm chart for deploying Postiz, a social media scheduling application with workflow orchestration.

## TL;DR

```bash
helm install my-postiz oci://ghcr.io/gitroomhq/postiz-helmchart/charts/postiz-app
```

## Introduction

This chart bootstraps a [Postiz](https://postiz.com) deployment on a Kubernetes cluster using the Helm package manager.

**Features:**
- 🔄 Temporal workflow engine for orchestration
- 🗄️ PostgreSQL database (or external)
- 🔴 Valkey (Redis-compatible) caching
- 🔒 Auto-generated connection strings
- 🔑 External secrets integration
- 📝 Custom annotations support
- 🌐 HTTPRoute support (Kubernetes Gateway API)
- 📦 Extra manifests injection for custom resources

## Prerequisites

- Kubernetes 1.19+
- Helm 3.8+
- PV provisioner support in the underlying infrastructure (for PostgreSQL/Redis persistence)

## Installing the Chart

### Quick Start (All Defaults)

```bash
helm install postiz oci://ghcr.io/gitroomhq/postiz-helmchart/charts/postiz-app
```

This installs the chart with:
- Internal PostgreSQL database
- Internal Valkey (Redis) cache
- Temporal workflow engine
- Auto-generated connection strings

### Custom Installation

Create a `values.yaml` file:

```yaml
# Use external database
postgresql:
  enabled: false

secrets:
  autoGenerate:
    enabled: false
  DATABASE_URL: "postgresql://user:pass@external-db:5432/postiz"
  REDIS_URL: "redis://:password@external-redis:6379"
  JWT_SECRET: "your-jwt-secret"

# Enable ingress
ingress:
  enabled: true
  className: "nginx"
  hosts:
    - host: postiz.example.com
      paths:
        - path: /
          pathType: Prefix
          port: 80

# Add Reloader annotations
podAnnotations:
  reloader.stakater.com/auto: "true"
```

Install with custom values:
```bash
helm install postiz oci://ghcr.io/gitroomhq/postiz-helmchart/charts/postiz-app -f values.yaml
```

## Configuration

### Core Application

| Parameter          | Description             | Default                        |
| ------------------ | ----------------------- | ------------------------------ |
| `replicaCount`     | Number of Postiz pods   | `1`                            |
| `image.repository` | Postiz image repository | `ghcr.io/gitroomhq/postiz-app` |
| `image.tag`        | Postiz image tag        | `"latest"`                     |
| `image.pullPolicy` | Image pull policy       | `IfNotPresent`                 |

### Database (PostgreSQL)

| Parameter                  | Description                | Default           |
| -------------------------- | -------------------------- | ----------------- |
| `postgresql.enabled`       | Deploy internal PostgreSQL | `true`            |
| `postgresql.auth.username` | Database username          | `postiz`          |
| `postgresql.auth.password` | Database password          | `postiz-password` |
| `postgresql.auth.database` | Database name              | `postiz`          |

### Cache (Valkey/Redis)

| Parameter             | Description            | Default                 |
| --------------------- | ---------------------- | ----------------------- |
| `redis.enabled`       | Deploy internal Valkey | `true`                  |
| `redis.auth.password` | Valkey password        | `postiz-redis-password` |

### Temporal Workflow Engine

| Parameter                      | Description              | Default |
| ------------------------------ | ------------------------ | ------- |
| `temporal.enabled`             | Deploy Temporal          | `true`  |
| `temporal.server.replicaCount` | Temporal server replicas | `1`     |
| `temporal.web.enabled`         | Deploy Temporal Web UI   | `true`  |

### Secrets & Auto-Generation

| Parameter                       | Description                | Default |
| ------------------------------- | -------------------------- | ------- |
| `secrets.autoGenerate.enabled`  | Enable auto-generation     | `true`  |
| `secrets.autoGenerate.database` | Auto-gen DATABASE_URL      | `true`  |
| `secrets.autoGenerate.redis`    | Auto-gen REDIS_URL         | `true`  |
| `secrets.DATABASE_URL`          | Manual database URL        | `""`    |
| `secrets.REDIS_URL`             | Manual Redis URL           | `""`    |
| `secrets.JWT_SECRET`            | JWT secret key             | `""`    |
| `extraSecrets`                  | External secrets to inject | `[]`    |

### Networking

| Parameter           | Description             | Default     |
| ------------------- | ----------------------- | ----------- |
| `service.type`      | Kubernetes Service type | `ClusterIP` |
| `service.port`      | Service port            | `80`        |
| `ingress.enabled`   | Enable ingress          | `false`     |
| `ingress.className` | Ingress class           | `""`        |
| `ingress.hosts`     | Ingress hosts           | `[]`        |

### Annotations

| Parameter               | Description              | Default |
| ----------------------- | ------------------------ | ------- |
| `podAnnotations`        | Pod template annotations | `{}`    |
| `deploymentAnnotations` | Deployment annotations   | `{}`    |
| `configMapAnnotations`  | ConfigMap annotations    | `{}`    |
| `secretAnnotations`     | Secret annotations       | `{}`    |
| `serviceAnnotations`    | Service annotations      | `{}`    |

## Examples

### Production Deployment

```yaml
# Production-ready configuration
replicaCount: 3

image:
  tag: "v1.3.0"  # Pin to specific version

resources:
  requests:
    memory: "512Mi"
    cpu: "500m"
  limits:
    memory: "1Gi"
    cpu: "1000m"

postgresql:
  enabled: true
  primary:
    persistence:
      size: 20Gi
  resources:
    requests:
      memory: "256Mi"
      cpu: "250m"

temporal:
  enabled: true
  server:
    replicaCount: 3
    config:
      persistence:
        numHistoryShards: 512
    resources:
      requests:
        memory: "1Gi"
        cpu: "500m"

secrets:
  autoGenerate:
    enabled: true

podAnnotations:
  reloader.stakater.com/auto: "true"

ingress:
  enabled: true
  className: "nginx"
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
  hosts:
    - host: postiz.example.com
      paths:
        - path: /
          pathType: Prefix
          port: 80
  tls:
    - secretName: postiz-tls
      hosts:
        - postiz.example.com

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 80
```

### External Database Configuration

```yaml
postgresql:
  enabled: false

secrets:
  autoGenerate:
    enabled: false
    database: false
  DATABASE_URL: "postgresql://postiz:secure-password@production-db.example.com:5432/postiz?sslmode=require"
  REDIS_URL: "redis://:redis-password@production-redis.example.com:6379/0"
  JWT_SECRET: "production-jwt-secret"
```

### Temporal with External Database

```yaml
temporal:
  enabled: true
  server:
    config:
      persistence:
        datastores:
          default:
            sql:
              pluginName: postgres12
              host: "temporal-db.example.com"
              port: 5432
              user: "temporal"
              password: "temporal-password"
              databaseName: "temporal"
              maxConns: 20
              maxIdleConns: 5
          visibility:
            sql:
              pluginName: postgres12
              host: "temporal-db.example.com"
              port: 5432
              user: "temporal"
              password: "temporal-password"
              databaseName: "temporal_visibility"
```

### External Secrets with Vault

```yaml
# First, install External Secrets Operator
# kubectl apply -f https://raw.githubusercontent.com/external-secrets/external-secrets/main/deploy/crds/bundle.yaml

# Create SecretStore
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "https://vault.example.com"
      path: "secret"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "postiz"

---
# Create ExternalSecret
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: postiz-external-secrets
spec:
  secretStoreRef:
    name: vault-backend
  target:
    name: postiz-vault-secrets
  data:
    - secretKey: JWT_SECRET
      remoteRef:
        key: postiz/production
        property: jwt_secret
    - secretKey: LINKEDIN_CLIENT_ID
      remoteRef:
        key: postiz/oauth
        property: linkedin_client_id
    - secretKey: LINKEDIN_CLIENT_SECRET
      remoteRef:
        key: postiz/oauth
        property: linkedin_client_secret

---
# Helm values
extraSecrets:
  - name: postiz-vault-secrets
```

### Stakater Reloader Configuration

```yaml
# Install Reloader
# helm repo add stakater https://stakater.github.io/stakater-charts
# helm install reloader stakater/reloader

# Enable auto-reload in Postiz
podAnnotations:
  reloader.stakater.com/auto: "true"

# OR use specific resource matching
configMapAnnotations:
  reloader.stakater.com/match: "true"
secretAnnotations:
  reloader.stakater.com/match: "true"
deploymentAnnotations:
  reloader.stakater.com/search: "true"
```

### HTTPRoute with Kubernetes Gateway API

For modern Kubernetes clusters with [Gateway API](https://gateway-api.sigs.k8s.io/) installed, use HTTPRoute instead of Ingress:

**Basic HTTPRoute:**
```yaml
# First, ensure Gateway API CRDs are installed
# kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0/standard-install.yaml

httproute:
  enabled: true
  # Reference your gateway
  parentRefs:
    - name: my-gateway
      namespace: default
  # Hostnames to match
  hostnames:
    - postiz.example.com
```

**Advanced HTTPRoute with custom routing:**
```yaml
httproute:
  enabled: true
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
  parentRefs:
    - name: api-gateway
      namespace: gateway-system
    - name: ingress-gateway
      namespace: default
  hostnames:
    - postiz.example.com
    - api.example.com
  # Custom routing rules
  rules:
    # Route /api traffic
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: postiz-app
          port: 80
    # Route / traffic
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: postiz-app
          port: 80
```

**Multi-gateway HTTPRoute:**
```yaml
httproute:
  enabled: true
  parentRefs:
    # Attach to multiple gateways
    - name: external-gateway
      namespace: gateway-system
      sectionName: http
    - name: internal-gateway
      namespace: gateway-system
      sectionName: http
  hostnames:
    - postiz.internal.example.com
    - postiz.external.example.com
```

### Extra Manifests for Custom Resources

Inject additional Kubernetes resources (ConfigMaps, ServiceMonitors, NetworkPolicies, etc.) alongside the Postiz deployment:

**Custom ConfigMap:**
```yaml
extraManifests:
  - |
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: postiz-custom-config
      namespace: default
    data:
      custom-setting: "value"
      feature-flag: "enabled"
```

**Service Monitoring (Prometheus):**
```yaml
extraManifests:
  - |
    apiVersion: monitoring.coreos.com/v1
    kind: ServiceMonitor
    metadata:
      name: postiz-monitor
      namespace: default
    spec:
      selector:
        matchLabels:
          app.kubernetes.io/name: postiz-app
      endpoints:
        - port: metrics
          interval: 30s
```

**Network Policy:**
```yaml
extraManifests:
  - |
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: postiz-network-policy
      namespace: default
    spec:
      podSelector:
        matchLabels:
          app.kubernetes.io/name: postiz-app
      policyTypes:
        - Ingress
        - Egress
      ingress:
        - from:
            - podSelector:
                matchLabels:
                  app: nginx-ingress
          ports:
            - protocol: TCP
              port: 80
      egress:
        - to:
            - podSelector:
                matchLabels:
                  app.kubernetes.io/name: postiz-app-postgresql
          ports:
            - protocol: TCP
              port: 5432
        - to:
            - podSelector:
                matchLabels:
                  app.kubernetes.io/name: postiz-app-redis-master
          ports:
            - protocol: TCP
              port: 6379
        - to:
            - namespaceSelector: {}
          ports:
            - protocol: TCP
              port: 53
            - protocol: UDP
              port: 53
```

**Multiple Custom Resources:**
```yaml
extraManifests:
  # Custom ConfigMap
  - |
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: postiz-app-settings
    data:
      log-level: "info"
      debug: "false"

  # Custom Secret
  - |
    apiVersion: v1
    kind: Secret
    metadata:
      name: postiz-webhook-secrets
    type: Opaque
    data:
      webhook-token: "<BASE64_WEBHOOK_TOKEN>"

  # PodDisruptionBudget for high availability
  - |
    apiVersion: policy/v1
    kind: PodDisruptionBudget
    metadata:
      name: postiz-pdb
    spec:
      minAvailable: 1
      selector:
        matchLabels:
          app.kubernetes.io/name: postiz-app

  # Custom RBAC Role
  - |
    apiVersion: rbac.authorization.k8s.io/v1
    kind: Role
    metadata:
      name: postiz-custom-role
    rules:
      - apiGroups: [""]
        resources: ["configmaps"]
        verbs: ["get", "list", "watch"]
```

**Extra Manifests with Values Integration:**

While extraManifests don't support Helm templating, you can pass raw YAML strings from your values file:

```yaml
extraManifests:
  - |
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: postiz-environment-config
    data:
      ENVIRONMENT: "production"
      LOG_LEVEL: "info"
      REPLICA_COUNT: "3"
```

## Accessing the Application

### Port Forwarding

**Postiz Application:**
```bash
kubectl port-forward svc/postiz-app 3000:80
```
Visit http://localhost:3000

**Temporal Web UI:**
```bash
kubectl port-forward svc/postiz-app-temporal-web 8080:8080
```
Visit http://localhost:8080

**PostgreSQL:**
```bash
kubectl port-forward svc/postiz-app-postgresql 5432:5432
psql -h localhost -U postiz -d postiz
```

### Via Ingress

See [Production Deployment](#production-deployment) example above.

## Troubleshooting

### Pods Not Starting

Check events:
```bash
kubectl describe pod -l app.kubernetes.io/name=postiz-app
```

Check logs:
```bash
kubectl logs -l app.kubernetes.io/name=postiz-app --tail=100
```

### Database Connection Issues

Verify connection string:
```bash
kubectl get secret postiz-app-secrets -o jsonpath='{.data.DATABASE_URL}' | base64 -d
```

Test database connectivity:
```bash
kubectl run -it --rm debug --image=postgres:15 --restart=Never -- \
  psql "postgresql://postiz:postiz-password@postiz-app-postgresql:5432/postiz"
```

### Temporal Issues

Check Temporal server logs:
```bash
kubectl logs -l app.kubernetes.io/component=frontend,app.kubernetes.io/part-of=temporal
```

Verify Temporal connectivity:
```bash
kubectl exec -it deployment/postiz-app -- \
  nc -zv postiz-app-temporal-frontend-headless 7233
```

## Uninstalling

```bash
helm uninstall postiz-app
```

**Warning:** This will delete all resources including PersistentVolumeClaims (data). To preserve data, back up before uninstalling.

## Migration from v1.0.x to v1.1.0

Version 1.1.0 is backward compatible, but introduces Temporal (required) and Valkey (Redis replacement).

### Migration Steps

1. **Backup data** (if using internal PostgreSQL/Redis):
   ```bash
   kubectl exec postiz-app-postgresql-0 -- pg_dump -U postiz postiz > backup.sql
   kubectl exec postiz-app-redis-master-0 -- redis-cli SAVE
   ```

2. **Upgrade Helm chart**:
   ```bash
   helm upgrade postiz-app oci://ghcr.io/gitroomhq/postiz-helmchart/charts/postiz-app
   ```

3. **Verify deployment**:
   ```bash
   kubectl rollout status deployment/postiz-app
   kubectl get pods | grep temporal
   ```

### Notable Changes

- **Temporal**: Now deployed by default. Adds workflow orchestration capabilities.
- **Valkey**: Replaces Redis. Fully compatible, no action needed.
- **Auto-generation**: Connection strings auto-generated. Disable if using manual config.

## Contributing

Contributions are welcome! Please read the [Contributing Guide](../../CONTRIBUTING.md).

## License

Apache License 2.0 - see [LICENSE](../../LICENSE).

## Support

- **Issues**: [GitHub Issues](https://github.com/gitroomhq/postiz-helmchart/issues)
- **Discussions**: [GitHub Discussions](https://github.com/gitroomhq/postiz-helmchart/discussions)
- **Postiz Documentation**: [postiz.com/docs](https://postiz.com/docs)
