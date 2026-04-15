# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Kubernetes homelab on LXD containers. HA control plane (×3) + workers (×3). All configuration is declarative YAML under `k8s/` and Helm values files.

## Common Commands

### Apply manifests
```bash
kubectl apply -f k8s/<path>/           # apply a directory
kubectl apply -f k8s/<path>/<file>.yaml
```

### Helm upgrades (general pattern)
```bash
helm upgrade --install <release> <repo>/<chart> -n <namespace> -f k8s/<path>/values.yaml
```

### Check cluster state
```bash
kubectl get pods -A
kubectl get nodes -o wide
```

### Port-forward to internal UIs
```bash
kubectl port-forward -n observability svc/mimir-querier 8080:8080
kubectl port-forward -n observability svc/loki-read 3100:3100
kubectl port-forward -n observability svc/tempo-query-frontend 3200:3200
kubectl port-forward -n observability svc/alloy 12345:12345
```

### Export CA cert (after cert-manager setup)
```bash
kubectl get secret homelab-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > homelab-ca.crt
```

### Get Headlamp login token
```bash
kubectl get secret headlamp-token -n operations \
  -o jsonpath='{.data.token}' | base64 -d
```

## Architecture

### Network / Ingress flow
```
LAN → host iptables DNAT → 10.10.0.100 (MetalLB) → ingress-nginx → Service
```
- All external traffic enters via **ingress-nginx** at `10.10.0.100` (MetalLB `LoadBalancer` IP).
- All services are exposed under a single hostname `homelab.local` using path-based routing.
- TLS is terminated at ingress using the cert-manager-issued secret `homelab-tls` (`homelab-ca-issuer`).
- `allowSnippetAnnotations: true` and `annotations-risk-level: Critical` are required for MinIO console path rewriting.

### Storage layers
- **`local-path`** (StorageClass): used for stateful PVCs (Loki write/backend, Mimir ingester/store-gateway/compactor, Tempo ingester). Not the default StorageClass — must be specified explicitly.
- **MinIO** (`minio-operator` + tenant `minio-observability`): S3-compatible object store for long-term data. Internal endpoint: `minio.infra.svc`. Buckets: `loki-chunks`, `loki-ruler`, `loki-admin`, `mimir-blocks`, `mimir-ruler`, `mimir-alertmanager`, `tempo-traces`. Credentials: `minio` / `minio12345`.

### Observability stack data flow
```
Alloy (DaemonSet, all nodes incl. control-plane)
  ├── kubelet + cAdvisor + kube-state-metrics + apiserver + node unix metrics → Mimir (remote_write)
  ├── annotated pods (prometheus.io/scrape=true) → Mimir
  ├── all pod logs → Loki
  └── OTLP traces (gRPC :4317, HTTP :4318) → Tempo
```
- **Mimir**: distributed mode (replication factor 2), S3 backend via MinIO, `out_of_order_time_window: 10m`.
- **Loki**: SimpleScalable mode (write/read/backend ×2), S3 backend, retention 168h.
- **Tempo**: distributed mode (replication factor 2), S3 backend, block retention 168h.
- **Grafana**: managed by Grafana Operator; PostgreSQL (CloudNativePG cluster `postgres-cluster` in `database` namespace, service `postgres-cluster-rw.database.svc:5432`) as DB backend. Datasources and dashboards are provisioned via `GrafanaDataSource`/`GrafanaDashboard` CRDs.
- **kube-state-metrics**: pod annotation auto-scrape disabled (`prometheusScrape: false`); scraped explicitly by Alloy.

### LXD / Kubernetes specifics
- LXD profile (`lxd/profile.yaml`): privileged + nested containers, AppArmor unconfined, `/sys/fs/bpf` bind mount for Cilium eBPF.
- **Cilium** runs in kube-proxy replacement mode (`kubeProxyReplacement: true`), native routing, pod CIDR `10.244.0.0/16`. Control plane VIP: `10.10.0.10` (kube-vip, ARP mode).
- **metrics-server** requires `--kubelet-insecure-tls` because LXD kubelet certs lack IP SANs.

### Directory layout
```
k8s/
  namespaces/          # Namespace definitions (infra, observability, operations)
  infra/               # cert-manager, ingress-nginx, metallb, minio (operator + tenant)
  kube-system/         # cilium, metrics-server
  local-path-storage/  # local-path-provisioner
  observability/       # numbered 03–10: postgres, grafana-operator, grafana, loki,
                       #   mimir, tempo, alloy, kube-state-metrics
  operations/          # headlamp
lxd/                   # LXD preseed (init.yaml) and k8s node profile (profile.yaml)
scripts/               # Numbered bootstrap scripts (00–10) for initial cluster setup
docs/troubleshooting/  # Investigation notes for known issues
```
