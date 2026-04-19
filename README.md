# Kubernetes Homelab

LXD コンテナ上に HA 構成の Kubernetes クラスターを構築し、observability スタックを運用するためのセットアップ手順。

## 構成

| 項目 | 内容 |
|---|---|
| ホスト OS | Ubuntu |
| コンテナ | LXD (lxdbr0 ブリッジ, 10.10.0.0/24) |
| Kubernetes | v1.35.3 |
| コントロールプレーン | k8s-cp-1〜3 (VIP: 10.10.0.10) |
| ワーカー | k8s-wk-1〜3 |
| CNI | Cilium 1.19.2 (kube-proxy 置き換えモード) |
| HA | kube-vip (ARP モード) |
| ロードバランサー | MetalLB (10.10.0.100) |
| Ingress | ingress-nginx |
| ストレージ | local-path-provisioner + MinIO |

### ノード一覧

| ノード | IP | vCPU | メモリ | ディスク |
|---|---|---|---|---|
| k8s-cp-1 | 10.10.0.11 | 2 | 4 GiB | 50 GiB |
| k8s-cp-2 | 10.10.0.12 | 2 | 4 GiB | 50 GiB |
| k8s-cp-3 | 10.10.0.13 | 2 | 4 GiB | 50 GiB |
| k8s-wk-1 | 10.10.0.21 | 2 | 16 GiB | 250 GiB |
| k8s-wk-2 | 10.10.0.22 | 2 | 16 GiB | 250 GiB |
| k8s-wk-3 | 10.10.0.23 | 2 | 16 GiB | 250 GiB |

### アクセス先

ドメイン `homelab.local` を `10.10.0.100` に解決するよう端末の hosts ファイルに追記すること。

| サービス | URL |
|---|---|
| Grafana | https://homelab.local/grafana/ (admin / admin) |
| MinIO コンソール | https://homelab.local/minio-console/ (minio / minio12345 または Authentik OIDC) |
| Hubble UI | https://homelab.local/hubble/ |
| Headlamp | https://homelab.local/headlamp/ (Authentik OIDC) |
| Authentik | https://homelab.local/authentik/ |
| pgAdmin | https://homelab.local/pgadmin/ (Authentik OIDC) |

---

## セットアップ手順

### フェーズ 1: ホスト・LXD・Kubernetes クラスター構築

scripts/ 配下のスクリプトを番号順に実行する。

```bash
# ホスト前提条件 (カーネルモジュール, sysctl)
sudo bash scripts/01-host-prereqs.sh

# LXD 初期化
bash scripts/00-lxd-init.sh

# LXD プロファイル作成
bash scripts/02-create-profile.sh

# ノード起動 (k8s-cp-1〜3, k8s-wk-1〜3)
bash scripts/03-launch-nodes.sh

# ノード内 sysctl 設定
bash scripts/04-configure-nodes.sh

# containerd インストール
bash scripts/05-install-containerd.sh

# kubeadm / kubelet / kubectl インストール
bash scripts/06-install-k8s-tools.sh

# k8s-cp-1 初期化 + kube-vip 配置 (証明書キーの有効期限: 2時間)
bash scripts/07-init-control-plane.sh

# k8s-cp-2, cp-3 を join
bash scripts/08-join-control-planes.sh

# k8s-wk-1〜3 を join
bash scripts/09-join-workers.sh

# Cilium (CNI) インストール
bash scripts/10-install-cni.sh
```

> **注意**: `07-init-control-plane.sh` 実行後 2時間以内に `08-join-control-planes.sh` を実行すること（証明書キーの有効期限）。

### フェーズ 2: Helm インストール

```bash
apt-get install -y curl gpg apt-transport-https
curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | gpg --dearmor | tee /usr/share/keyrings/helm.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" > /etc/apt/sources.list.d/helm-stable-debian.list
apt-get update && apt-get install -y helm
```

### フェーズ 3: ホスト iptables (LAN からのアクセス設定)

ingress-nginx の External IP (10.10.0.100) は LXD ブリッジ内のアドレスのため、
LAN の他マシンからアクセスする場合はホストでポート転送を設定する。

```bash
apt install -y iptables iptables-persistent

iptables -t nat -A PREROUTING -i enp1s0 -p tcp --dport 80 -j DNAT --to-destination 10.10.0.100:80
iptables -A FORWARD -p tcp -d 10.10.0.100 --dport 80 -j ACCEPT

iptables -t nat -A PREROUTING -i enp1s0 -p tcp --dport 443 -j DNAT --to-destination 10.10.0.100:443
iptables -A FORWARD -p tcp -d 10.10.0.100 --dport 443 -j ACCEPT

netfilter-persistent save
```

---

## インフラコンポーネント

### Namespace

```bash
kubectl apply -f k8s/namespaces/
```

### cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  -n infra \
  -f k8s/infra/cert-manager/values.yaml \
  --wait

# 自己署名 CA ClusterIssuer を作成
kubectl apply -f k8s/infra/cert-manager/cluster-issuer.yaml
kubectl wait certificate/homelab-ca -n infra --for=condition=Ready --timeout=60s
```

CA 証明書をエクスポートしてアクセス端末にインポートする（初回のみ）：

```bash
kubectl get secret homelab-ca-secret -n infra \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > homelab-ca.crt
```

Windows: `certmgr.msc` →「信頼されたルート証明機関」にインポート

### MetalLB

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update
helm install metallb metallb/metallb -n infra
kubectl apply -f k8s/infra/metallb/ippool.yaml
```

### ingress-nginx

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n infra \
  -f k8s/infra/ingress-nginx/values.yaml
```

### Hubble UI (Cilium の観測 UI)

Cilium インストール後に実行。

```bash
# values.yaml に hubble.relay.enabled / hubble.ui.enabled を追加済み
helm upgrade cilium cilium/cilium \
  -n kube-system \
  -f k8s/kube-system/cilium/values.yaml

kubectl apply -f k8s/kube-system/cilium/ingress-hubble.yaml
```

### metrics-server

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update
helm install metrics-server metrics-server/metrics-server \
  -n kube-system \
  -f k8s/kube-system/metrics-server/values.yaml
```

### Headlamp

Authentik OIDC 認証を使用する。事前に Authentik のセットアップ（後述）と Headlamp アプリ作成を完了すること。

> **既知の制限**: Headlamp は OIDC アクセストークンをプロアクティブにリフレッシュしない。
> セッション継続時間は Authentik の `access_token_validity` と一致する（詳細: `docs/troubleshooting/headlamp-oidc-session.md`）。

#### Authentik アプリ作成（UI）

1. Admin → Applications → Providers → OAuth2/OIDC Provider を作成
   - Name: `headlamp` / Client type: `Confidential`
   - Redirect URIs: `https://homelab.local/headlamp/oidc-callback`
2. Admin → Applications → Application を作成
   - Slug: `headlamp`、上記 Provider を紐付け
   - Launch URL: `https://homelab.local/headlamp/`
3. クライアント ID・シークレットを `k8s/operations/headlamp/values.yaml` の `config.oidc` に記入

#### CP ノードの準備

kube-apiserver が OIDC issuer URL（`https://homelab.local/...`）を検証するため、各 CP ノードに設定が必要。

```bash
# homelab.local の名前解決（LXD コンテナ再起動後も永続）
for node in k8s-cp-1 k8s-cp-2 k8s-cp-3; do
  lxc exec $node -- bash -c 'grep -q homelab.local /etc/hosts || echo "10.10.0.100 homelab.local" >> /etc/hosts'
done

# CA 証明書を配布（kube-apiserver が Authentik の TLS を検証するために必要）
for node in k8s-cp-1 k8s-cp-2 k8s-cp-3; do
  lxc file push homelab-ca.crt ${node}/etc/kubernetes/pki/homelab-ca.crt
done

# kube-apiserver に OIDC フラグを追加（各 CP ノードの manifest を編集）
for node in k8s-cp-1 k8s-cp-2 k8s-cp-3; do
  lxc exec $node -- sed -i '/--tls-cert-file/a\    - --oidc-issuer-url=https://homelab.local/authentik/application/o/headlamp/\n    - --oidc-client-id=<CLIENT_ID>\n    - --oidc-username-claim=preferred_username\n    - --oidc-groups-claim=groups\n    - --oidc-ca-file=/etc/kubernetes/pki/homelab-ca.crt' \
    /etc/kubernetes/manifests/kube-apiserver.yaml
done
# → kube-apiserver が自動再起動（約 30 秒 × 3 台）
```

#### Headlamp のインストール・設定

```bash
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
helm repo update
helm upgrade --install headlamp headlamp/headlamp \
  -n operations \
  -f k8s/operations/headlamp/values.yaml

# CA 証明書を ConfigMap として作成
kubectl get secret homelab-ca-secret -n infra \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/homelab-ca.crt
kubectl create configmap homelab-ca \
  --from-file=ca.crt=/tmp/homelab-ca.crt \
  -n operations --dry-run=client -o yaml | kubectl apply -f -

# CoreDNS・RBAC を適用
kubectl apply -f k8s/kube-system/coredns/configmap-patch.yaml
kubectl apply -f k8s/operations/headlamp/ingress.yaml
kubectl apply -f k8s/operations/headlamp/rbac.yaml
```

### Authentik

cert-manager・PostgreSQL インストール後に実行すること。
Authentik の DB は既存の `postgres-cluster`（database namespace）を流用する。

```bash
# Authentik 用 DB・ユーザーを既存 postgres-cluster に作成
PRIMARY=$(kubectl get cluster postgres-cluster -n database -o jsonpath='{.status.currentPrimary}')
kubectl exec -n database $PRIMARY -- psql -U postgres -c "CREATE USER authentik WITH PASSWORD 'authentik12345';"
kubectl exec -n database $PRIMARY -- psql -U postgres -c "CREATE DATABASE authentik OWNER authentik;"

# Authentik インストール
helm repo add authentik https://charts.goauthentik.io
helm repo update
helm upgrade --install authentik authentik/authentik \
  -n infra \
  -f k8s/infra/authentik/values.yaml \
  --wait --timeout=300s

kubectl apply -f k8s/infra/authentik/ingress.yaml
```

初回セットアップ（UI）：
1. `https://homelab.local/authentik/if/flow/initial-setup/` にアクセスして管理者パスワードを設定
2. Admin → Applications → Providers → OAuth2/OIDC Provider を作成
   - Name: `grafana` / Redirect URIs: `https://homelab.local/grafana/login/generic_oauth`
3. Admin → Applications → Application を作成
   - Slug: `grafana`、上記 Provider を紐付け
   - Launch URL: `https://homelab.local/grafana/`
4. クライアント ID・シークレットを `k8s/infra/authentik/grafana-oauth-secret.yaml` に記入して apply

```bash
kubectl apply -f k8s/infra/authentik/grafana-oauth-secret.yaml
```

---

## ストレージ

### local-path-provisioner

```bash
kubectl apply -f k8s/storage/local-path-provisioner/local-path-storage.yaml
```

`StorageClass` 名: `local-path` / デフォルトではない（PVC で明示指定が必要）。

### MinIO Operator + Tenant

```bash
helm repo add minio-operator https://operator.min.io/
helm repo update

helm upgrade --install minio-operator minio-operator/operator \
  -n storage --create-namespace \
  -f k8s/storage/minio/operator-values.yaml

helm upgrade --install minio-tenant minio-operator/tenant \
  -n storage \
  -f k8s/storage/minio/tenant-values.yaml
```

Tenant 仕様: 3 servers × 2 volumes × 50 GiB、サービス名 `minio.storage.svc`

#### MinIO OIDC 設定（Authentik）

Authentik Admin UI で以下を行う。

1. **Scope Mapping 作成**: Customization → Property Mappings → Create → Scope Mapping
   - Name: `MinIO Policy`
   - Scope name: `minio_policy`
   - Expression:
     ```python
     return {"policy": "consoleAdmin"}
     ```

2. **Provider 作成**: Applications → Providers → OAuth2/OIDC Provider
   - Name: `minio` / Client type: `Confidential`
   - Redirect URIs: `https://homelab.local/minio-console/oauth_callback`
   - Scopes: 上記 `MinIO Policy` を追加

3. **Application 作成**: Applications → Applications
   - Slug: `minio` / Provider: 上記 / Launch URL: `https://homelab.local/minio-console/`

4. クライアント ID・シークレットを `k8s/storage/minio/tenant-values.yaml` の `env` セクションに記入して apply

```bash
# homelab-ca ConfigMap を storage namespace にコピー
kubectl get configmap homelab-ca -n operations -o yaml \
  | sed 's/namespace: operations/namespace: storage/' \
  | kubectl apply -f -

helm upgrade minio-tenant minio-operator/tenant -n storage -f k8s/storage/minio/tenant-values.yaml
```

> **注意**: MinIO Operator sidecar (v7.0.1) は `valueFrom.secretKeyRef` を解決しないバグがあるため、
> クライアントシークレットは `value:` で直接指定する（[#2279](https://github.com/minio/operator/issues/2279)）。

### MinIO コンソール Ingress

`configuration-snippet` を使うため ingress-nginx のアップグレードが先に必要。

```bash
helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
  -n infra \
  -f k8s/infra/ingress-nginx/values.yaml

kubectl apply -f k8s/storage/minio/ingress.yaml
```

---

## Observability スタック

### 前提: Helm リポジトリ追加

```bash
helm repo add grafana              https://grafana.github.io/helm-charts
helm repo add cnpg                 https://cloudnative-pg.github.io/charts
helm repo add grafana-community    https://grafana-community.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### 1. PostgreSQL (CloudNativePG)

Grafana・Authentik のバックエンド DB。

```bash
helm upgrade --install cnpg cnpg/cloudnative-pg \
  -n database --create-namespace \
  -f k8s/database/postgres/cnpg-operator-values.yaml \
  --wait --timeout=120s

kubectl apply -f k8s/database/postgres/secret.yaml
kubectl apply -f k8s/database/postgres/cluster.yaml

kubectl wait cluster/postgres-cluster -n database \
  --for=condition=Ready --timeout=300s
```

### 2. pgAdmin

Authentik で OAuth2/OIDC Provider・Application `pgadmin` を事前作成し、Client ID/Secret を `k8s/database/pgadmin/oauth2-secret.yaml` に記載してから実行する。
Redirect URI: `https://homelab.local/pgadmin/oauth2/authorize`

```bash
helm repo add runix https://helm.runix.net
helm repo update

kubectl apply -f k8s/database/pgadmin/config-configmap.yaml
kubectl apply -f k8s/database/pgadmin/oauth2-secret.yaml

helm upgrade --install pgadmin runix/pgadmin4 \
  -n database \
  -f k8s/database/pgadmin/values.yaml \
  --wait

kubectl apply -f k8s/database/pgadmin/ingress.yaml
```

### 4. Grafana Operator + Grafana

```bash
helm upgrade --install grafana-operator \
  oci://ghcr.io/grafana/helm-charts/grafana-operator \
  --version 5.22.2 \
  --namespace observability \
  -f k8s/observability/04-grafana-operator/operator-values.yaml \
  --wait --timeout=120s

kubectl apply -f k8s/observability/05-grafana/grafana.yaml
kubectl apply -f k8s/observability/05-grafana/ingress.yaml
```

### 5. Loki

```bash
helm upgrade --install loki grafana/loki \
  -n observability \
  -f k8s/observability/06-loki/values.yaml

kubectl apply -f k8s/observability/06-loki/ingress.yaml
```

### 6. Mimir

```bash
helm upgrade --install mimir grafana/mimir-distributed \
  -n observability \
  -f k8s/observability/07-mimir/values.yaml

kubectl apply -f k8s/observability/07-mimir/recording-rules.yaml
kubectl apply -f k8s/observability/07-mimir/ingress.yaml
```

### 7. Tempo

```bash
helm upgrade --install tempo grafana-community/tempo-distributed \
  -n observability \
  -f k8s/observability/08-tempo/values.yaml

kubectl apply -f k8s/observability/08-tempo/ingress.yaml
```

### 8. kube-state-metrics

```bash
helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
  -n observability \
  -f k8s/observability/10-kube-state-metrics/values.yaml
```

### 9. Alloy

```bash
helm upgrade --install alloy grafana/alloy \
  -n observability \
  -f k8s/observability/09-alloy/values.yaml

kubectl apply -f k8s/observability/09-alloy/service.yaml
kubectl apply -f k8s/observability/09-alloy/ingress.yaml
```

### 10. データソース・ダッシュボード

```bash
kubectl apply -f k8s/observability/05-grafana/datasource-loki.yaml
kubectl apply -f k8s/observability/05-grafana/datasource-mimir.yaml
kubectl apply -f k8s/observability/05-grafana/datasource-tempo.yaml
kubectl apply -f k8s/observability/05-grafana/dashboards/
```


## 各コンポーネントの管理画面パス

Ingressは未設定のため、kubectl port-forwardを実行してアクセスする。

### Mimir
Ingressは未設定のため、kubectl port-forwardを実行してアクセスする。
```bash
kubectl port-forward -n observability svc/mimir-querier 8080:8080 
```

### Loki
Ingressは未設定のため、kubectl port-forwardを実行してアクセスする。
```bash
 kubectl port-forward -n observability svc/loki-read 3100:3100 
```

ルートパス (`/`) は404になるため、以下の具体的なパスにアクセスする。

| パス                          | 内容                       |
|-------------------------------|----------------------------|
| `/ready`                      | 準備完了チェック           |
| `/metrics`                    | Prometheusメトリクス       |
| `/config`                     | 現在の設定                 |
| `/services`                   | 実行中サービス一覧         |
| `/log_level`                  | ログレベル確認・変更       |
| `/loki/api/v1/status/buildinfo` | バージョン・ビルド情報   |

### Tempo
Ingressは未設定のため、kubectl port-forwardを実行してアクセスする。
```bash
kubectl port-forward -n observability svc/tempo-query-frontend 3200:3200
```

ルートパス (`/`) は404になるため、以下の具体的なパスにアクセスする。

| パス                          | 内容                                    |
|-------------------------------|-----------------------------------------|
| `/ready`                      | 準備完了チェック                        |
| `/metrics`                    | Prometheusメトリクス                    |
| `/status`                     | 全ステータス情報                        |
| `/status/version`             | バージョン情報                          |
| `/status/services`            | サービス一覧と状態                      |
| `/status/config`              | 現在の設定（`?mode=diff` で差分表示）   |
| `/status/endpoints`           | APIエンドポイント一覧                   |

### Alloy
Ingressは未設定のため、kubectl port-forwardを実行してアクセスする。
```bash
kubectl port-forward -n observability svc/alloy 12345:12345
```