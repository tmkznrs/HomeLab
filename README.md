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
| ストレージ | local-path-provisioner + Rook-Ceph (ceph-block) + MinIO (Rook-Ceph RGW) |

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
| Rook-Ceph | https://homelab.local/ceph/ (admin / admin) |
| Hubble UI | https://homelab.local/hubble/ |
| Headlamp | https://homelab.local/headlamp/ (Authentik OIDC) |
| Argo CD | https://homelab.local/argocd/ (Authentik OIDC) |
| Authentik | https://homelab.local/authentik/ |
| pgAdmin | https://homelab.local/pgadmin/ (Authentik OIDC) |

### 外部 PC からの kubectl 管理

LXD ブリッジ（10.10.0.0/24）は外部 PC から直接到達不可のため、LXD ホスト（192.168.1.101）経由で接続する。

#### 1. CA 証明書を外部 PC に信頼させる

```bash
# LXD ホスト上で実行
kubectl get secret homelab-ca-secret -n infra \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > homelab-ca.crt
```

取り出した `homelab-ca.crt` を外部 PC に転送してインポートする。

| OS | コマンド |
|---|---|
| Ubuntu/Debian | `sudo cp homelab-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates` |
| macOS | `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain homelab-ca.crt` |
| Windows | `certmgr.msc` →「信頼されたルート証明機関」にインポート |

#### 2. kubeconfig を外部 PC にコピーして設定

```bash
# LXD ホスト上で実行
kubectl config view --raw > kubeconfig-homelab.yaml

# server を LXD ホストの LAN IP に変更
kubectl config set-cluster kubernetes \
  --server=https://192.168.1.101:6443 \
  --kubeconfig=kubeconfig-homelab.yaml

# TLS 検証ホスト名を kube-vip VIP に固定（接続先と証明書の CN が異なるため必須）
kubectl config set-cluster kubernetes \
  --tls-server-name=10.10.0.10 \
  --kubeconfig=kubeconfig-homelab.yaml
```

外部 PC にコピーして配置：

```bash
mkdir -p ~/.kube
cp kubeconfig-homelab.yaml ~/.kube/config
```

#### 3. 動作確認

```bash
kubectl get nodes -o wide
```

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

# kubectl 用 API サーバー (kube-vip VIP: 10.10.0.10)
iptables -t nat -A PREROUTING -i enp1s0 -p tcp --dport 6443 -j DNAT --to-destination 10.10.0.10:6443
iptables -A FORWARD -p tcp -d 10.10.0.10 --dport 6443 -j ACCEPT

netfilter-persistent save
```

---

## 各コンポーネントのインストール

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

### trust-manager

cert-manager の直後に入れる。CA バンドルをクラスター全体の Pod に配布する。

```bash
helm upgrade --install trust-manager jetstack/trust-manager \
  -n infra \
  -f k8s/infra/trust-manager/values.yaml \
  --wait
```

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


### metrics-server

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update
helm install metrics-server metrics-server/metrics-server \
  -n kube-system \
  -f k8s/kube-system/metrics-server/values.yaml
```

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

### Rook-Ceph

#### Helm リポジトリ追加
```bash
helm repo add rook-release https://charts.rook.io/release
helm repo update
```

#### Rook Operator をインストール
```bash
helm upgrade --install rook-ceph rook-release/rook-ceph \
  -n storage --create-namespace \
  -f "$REPO_ROOT/k8s/storage/rook-ceph/operator-values.yaml" \
  --wait
```

#### CephCluster / CephBlockPool / StorageClass を適用
```bash
kubectl apply -f "$REPO_ROOT/k8s/storage/rook-ceph/cluster.yaml"
kubectl -n storage wait cephcluster rook-ceph \
  --for=condition=Ready \
  --timeout=900s
kubectl -n storage wait cephobjectstore my-store \
  --for=condition=Ready \
  --timeout=600s
```

#### Toolbox のデプロイ + RGW ユーザーを作成（固定クレデンシャル）
```bash
helm template rook-ceph-cluster rook-release/rook-ceph-cluster \
  -n storage \
  --set operatorNamespace=storage \
  --set clusterName=rook-ceph \
  --set toolbox.enabled=true \
  -s templates/deployment.yaml \
  | kubectl apply -f -

kubectl -n storage rollout status deploy/rook-ceph-tools --timeout=120s

kubectl -n storage exec deploy/rook-ceph-tools -- \
  radosgw-admin user create \
  --uid=observability \
  --display-name="Observability Stack" \
  --access-key=ceph-obs-access \
  --secret-key=ceph-obs-secret \
  --rgw-realm=my-store \
  --rgw-zonegroup=my-store \
  --rgw-zone=my-store 2>/dev/null \
  || kubectl -n storage exec deploy/rook-ceph-tools -- \
     radosgw-admin user modify \
     --uid=observability \
     --access-key=ceph-obs-access \
     --secret-key=ceph-obs-secret \
     --rgw-realm=my-store \
     --rgw-zonegroup=my-store \
     --rgw-zone=my-store

# S3 バケットを作成（Loki/Mimir/Tempo 用）
kubectl -n storage exec deploy/rook-ceph-tools -- python3 -c "
import urllib.request, urllib.error, hmac, hashlib, datetime

endpoint = 'http://rook-ceph-rgw-my-store.storage.svc'
access_key = 'ceph-obs-access'
secret_key = 'ceph-obs-secret'

def sign(key, msg):
    return hmac.new(key, msg.encode('utf-8'), hashlib.sha256).digest()

def get_signature(key, date_stamp, region, service, msg):
    k_date = sign(('AWS4' + key).encode('utf-8'), date_stamp)
    k_region = sign(k_date, region)
    k_service = sign(k_region, service)
    k_signing = sign(k_service, 'aws4_request')
    return hmac.new(k_signing, msg.encode('utf-8'), hashlib.sha256).hexdigest()

buckets = ['loki-chunks', 'loki-ruler', 'loki-admin', 'mimir-blocks', 'mimir-ruler', 'mimir-alertmanager', 'tempo-traces']
now = datetime.datetime.utcnow()
amz_date = now.strftime('%Y%m%dT%H%M%SZ')
date_stamp = now.strftime('%Y%m%d')
region, service = 'us-east-1', 's3'

for bucket in buckets:
    payload_hash = hashlib.sha256(b'').hexdigest()
    canonical_headers = f'host:rook-ceph-rgw-my-store.storage.svc\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amz_date}\n'
    signed_headers = 'host;x-amz-content-sha256;x-amz-date'
    canonical_request = f'PUT\n/{bucket}\n\n{canonical_headers}\n{signed_headers}\n{payload_hash}'
    credential_scope = f'{date_stamp}/{region}/{service}/aws4_request'
    string_to_sign = f'AWS4-HMAC-SHA256\n{amz_date}\n{credential_scope}\n{hashlib.sha256(canonical_request.encode()).hexdigest()}'
    signature = get_signature(secret_key, date_stamp, region, service, string_to_sign)
    auth_header = f'AWS4-HMAC-SHA256 Credential={access_key}/{credential_scope}, SignedHeaders={signed_headers}, Signature={signature}'
    req = urllib.request.Request(f'{endpoint}/{bucket}', data=b'', method='PUT')
    req.add_header('Authorization', auth_header)
    req.add_header('x-amz-date', amz_date)
    req.add_header('x-amz-content-sha256', payload_hash)
    try:
        resp = urllib.request.urlopen(req)
        print(f'{bucket}: {resp.status}')
    except urllib.error.HTTPError as e:
        print(f'{bucket}: {e.code} {e.read().decode()}')
"
```

### PostgreSQL (CloudNativePG)

Grafana・Authentik のバックエンド DB。

```bash
helm repo add cnpg                 https://cloudnative-pg.github.io/charts
helm upgrade --install cnpg cnpg/cloudnative-pg \
  -n database --create-namespace \
  -f k8s/database/postgres/cnpg-operator-values.yaml \
  --wait --timeout=120s

kubectl apply -f k8s/database/postgres/secret.yaml
kubectl apply -f k8s/database/postgres/cluster.yaml

kubectl wait cluster/postgres-cluster -n database \
  --for=condition=Ready --timeout=300s

kubectl -n database exec postgres-cluster-1 -- psql -U postgres -c "CREATE USER authentik WITH PASSWORD 'authentik12345';" 2>&1
kubectl -n database exec postgres-cluster-1 -- psql -U postgres -c "CREATE DATABASE authentik OWNER authentik;" 2>&1
```

### Authentik

cert-manager・PostgreSQL インストール後に実行すること。
Authentik の DB は既存の `postgres-cluster`（database namespace）を流用する。

`k8s/infra/authentik/values.yaml` に `bootstrap_password` / `bootstrap_token` を設定することで、
管理者パスワードと API トークンが自動的に作成される（UI での初回セットアップ不要）。

```bash
# Authentik 用 DB・ユーザーを既存 postgres-cluster に作成
PRIMARY=$(kubectl get cluster postgres-cluster -n database -o jsonpath='{.status.currentPrimary}')
kubectl exec -n database $PRIMARY -- psql -U postgres -c "CREATE USER authentik WITH PASSWORD 'authentik12345';"
kubectl exec -n database $PRIMARY -- psql -U postgres -c "CREATE DATABASE authentik OWNER authentik;"

# Authentik インストール（values.yaml に bootstrap_password/bootstrap_token を含む）
helm repo add authentik https://charts.goauthentik.io
helm repo update
helm upgrade --install authentik authentik/authentik \
  -n infra \
  -f k8s/infra/authentik/values.yaml \
  --wait --timeout=300s

kubectl apply -f k8s/infra/authentik/ingress.yaml
```

#### OIDC Provider / Application のセットアップ（API 自動化）

bootstrap_token を使って Authentik REST API で全サービスの Provider と Application を一括作成する。
`k8s/infra/authentik/values.yaml` の `bootstrap_token` の値を TOKEN に設定すること。

```bash
TOKEN="homelab-bootstrap-token"   # values.yaml の bootstrap_token と一致させる
API="http://localhost:9000/authentik/api/v3"

# Authentik API に port-forward でアクセス
kubectl port-forward -n infra svc/authentik-server 9000:80 &

# Authorization Flow / Invalidation Flow の PK を取得
AUTH_FLOW=$(curl -s "$API/flows/instances/?slug=default-provider-authorization-implicit-consent" \
  -H "Authorization: Bearer $TOKEN" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['results'][0]['pk'])")
INVAL_FLOW=$(curl -s "$API/flows/instances/?slug=default-provider-invalidation-flow" \
  -H "Authorization: Bearer $TOKEN" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['results'][0]['pk'])")

# "authentik Admins" グループを作成
curl -s -X POST "$API/core/groups/" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"authentik Admins","is_superuser":false}' | python3 -c "import sys,json; d=json.load(sys.stdin); print('Group:', d.get('pk', d))"

# OAuth2 Provider 作成関数
create_provider() {
  local name=$1 redirect_uri=$2
  curl -s -X POST "$API/providers/oauth2/" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$name\",\"authorization_flow\":\"$AUTH_FLOW\",\"invalidation_flow\":\"$INVAL_FLOW\",
         \"redirect_uris\":[{\"matching_mode\":\"strict\",\"url\":\"$redirect_uri\"}],
         \"sub_mode\":\"hashed_user_id\",\"include_claims_in_id_token\":true}"
}

# 各サービスの Provider を作成し、client_id / client_secret を取得して各ファイルに記入
GRAFANA=$(create_provider "grafana" "https://homelab.local/grafana/login/generic_oauth")
HEADLAMP=$(create_provider "headlamp" "https://homelab.local/headlamp/oidc-callback")
ARGOCD=$(create_provider "argocd" "https://homelab.local/argocd/auth/callback")
PGADMIN=$(create_provider "pgadmin" "https://homelab.local/pgadmin/oauth2/authorize")

# Application 作成（Provider PK は各レスポンスの .pk を使用）
create_app() {
  local name=$1 slug=$2 pk=$3 url=$4
  curl -s -X POST "$API/core/applications/" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$name\",\"slug\":\"$slug\",\"provider\":$pk,\"meta_launch_url\":\"$url\"}"
}
# pk は各 Provider レスポンスの .pk フィールドを参照
create_app "Grafana"  "grafana"  <grafana_pk>  "https://homelab.local/grafana/"
create_app "Headlamp" "headlamp" <headlamp_pk> "https://homelab.local/headlamp/"
create_app "ArgoCD"   "argocd"   <argocd_pk>   "https://homelab.local/argocd/"
create_app "pgAdmin"  "pgadmin"  <pgadmin_pk>  "https://homelab.local/pgadmin/"
```

Provider 作成後、取得した client_id / client_secret を以下に反映する:

| サービス | 更新先 |
|---------|-------|
| Grafana | `kubectl create secret generic grafana-oauth-secret -n observability --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_ID=<id> --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=<secret>` |
| Headlamp | `k8s/operations/headlamp/values.yaml` の `config.oidc.clientID` / `clientSecret` |
| ArgoCD | `k8s/operations/argocd/values.yaml` の `clientID`、`k8s/operations/argocd/oidc-secret.yaml` の `clientSecret` |
| pgAdmin | `k8s/database/pgadmin/oauth2-secret.yaml` の `OAUTH2_CLIENT_ID` / `OAUTH2_CLIENT_SECRET` |

### pgAdmin

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
# <CLIENT_ID>を実際のクライアントIDに書き換えて実行すること
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

### Hubble UI (Cilium の観測 UI)

Cilium インストール後に実行。

```bash
# values.yaml に hubble.relay.enabled / hubble.ui.enabled を追加済み
helm upgrade cilium cilium/cilium \
  -n kube-system \
  -f k8s/kube-system/cilium/values.yaml

kubectl apply -f k8s/kube-system/cilium/ingress-hubble.yaml
```


### Argo CD

Authentik のセットアップ完了後に実行すること。

#### Authentik アプリ作成（UI）

1. Admin → Applications → Providers → OAuth2/OIDC Provider を作成
   - Name: `argocd` / Client type: `Confidential`
   - Redirect URIs: `https://homelab.local/argocd/auth/callback`
   - Scopes: `authentik default OAuth Mapping - OpenID 'groups'` を追加
2. Admin → Applications → Application を作成
   - Slug: `argocd`、上記 Provider を紐付け
3. クライアント ID・シークレットを控える

#### インストール

クライアントシークレットを `k8s/operations/argocd/oidc-secret.yaml` に記入し、クライアント ID を `k8s/operations/argocd/values.yaml` の `configs.cm.oidc.config.clientID` に記入してから実行する。

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

kubectl apply -f k8s/operations/argocd/oidc-secret.yaml

helm upgrade --install argocd argo/argo-cd \
  -n operations \
  -f k8s/operations/argocd/values.yaml

kubectl apply -f k8s/operations/argocd/ingress.yaml
```

初期 admin パスワードの確認：

```bash
kubectl -n operations get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

#### CLI ログイン

```bash
argocd login homelab.local \
  --grpc-web \
  --grpc-web-root-path /argocd \
  --sso
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
## Observability スタックのインストール

### 前提: Helm リポジトリ追加

```bash
helm repo add grafana              https://grafana.github.io/helm-charts
helm repo add grafana-community    https://grafana-community.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### Grafana Operator + Grafana

#### Authentik アプリ作成（UI）

https://homelab.local/authentik/ にアクセスして以下を実施：

1. Admin → Applications → Providers → Create → OAuth2/OIDC Provider
Name: grafana
Client type: Confidential
Redirect URIs: https://homelab.local/grafana/login/generic_oauth
2. Admin → Applications → Applications → Create
Slug: grafana
上記 Provider を紐付け
Launch URL: https://homelab.local/grafana/
3. 作成した Provider のクライアント ID・シークレットを
   k8s/observability/05-grafana/grafana.yamlの
   `auth.generic_oauth.client_id` / `client_secret` に直接書き込む

#### Grafanaのインストール

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

### Loki

```bash
helm upgrade --install loki grafana/loki \
  -n observability \
  -f k8s/observability/06-loki/values.yaml

kubectl apply -f k8s/observability/06-loki/ingress.yaml
```

### Mimir

```bash
helm upgrade --install mimir grafana/mimir-distributed \
  -n observability \
  -f k8s/observability/07-mimir/values.yaml

kubectl apply -f k8s/observability/07-mimir/recording-rules.yaml
kubectl apply -f k8s/observability/07-mimir/alert-rules.yaml
kubectl apply -f k8s/observability/07-mimir/ingress.yaml
```

`recording-rules.yaml` には recording rules、`alert-rules.yaml` には以下のアラートルールが含まれる。

| アラート | 条件 | 重大度 |
|---|---|---|
| NodeMemoryHigh | メモリ使用率 > 80% (5分継続) | warning |
| NodeMemoryCritical | メモリ使用率 > 90% (5分継続) | critical |

Alertmanager は `values.yaml` の `alertmanager.fallbackConfig` に Gmail SMTP 設定を持ち、アラート発火時に `tmkznrs@gmail.com` へメール通知する。PrometheusRule は Alloy の `mimir.rules.kubernetes` コンポーネントが Mimir へ自動同期する。

### Tempo

```bash
helm upgrade --install tempo grafana-community/tempo-distributed \
  -n observability \
  -f k8s/observability/08-tempo/values.yaml

kubectl apply -f k8s/observability/08-tempo/ingress.yaml
```

### kube-state-metrics

```bash
helm upgrade --install kube-state-metrics prometheus-community/kube-state-metrics \
  -n observability \
  -f k8s/observability/10-kube-state-metrics/values.yaml
```

### Alloy

```bash
helm upgrade --install alloy grafana/alloy \
  -n observability \
  -f k8s/observability/09-alloy/values.yaml

kubectl apply -f k8s/observability/09-alloy/service.yaml
kubectl apply -f k8s/observability/09-alloy/ingress.yaml
```

### データソース

```bash
kubectl apply -f k8s/observability/05-grafana/datasource-loki.yaml
kubectl apply -f k8s/observability/05-grafana/datasource-mimir.yaml
kubectl apply -f k8s/observability/05-grafana/datasource-tempo.yaml
```

### alloy-probe (外部マシン ICMP 死活監視)

クラスター側の単一レプリカ Alloy Deployment から外部マシンへ ICMP プローブを送信する。
Windows Alloy など外部エージェントが停止した場合でも監視が継続される。

```bash
kubectl apply -f k8s/observability/10-alloy-probe/configmap.yaml
kubectl apply -f k8s/observability/10-alloy-probe/deployment.yaml
```

監視結果は Grafana → Explore → Mimir で確認:
- `probe_success{job="external-probe"}` — 死活 (1=OK, 0=NG)
- `probe_duration_seconds{job="external-probe"}` — RTT

---

## 外部 Alloy エージェント

クラスター外のマシン（Windows など）からメトリクス・ログを収集して Mimir / Loki へ送信する。
設定ファイルと詳細手順は [`alloy/README.md`](alloy/README.md) を参照。

| ファイル | 対象 | 収集内容 |
|---|---|---|
| `alloy/config.windows.alloy` | Windows | システムメトリクス、イベントログ |

---

## 各コンポーネントの管理画面パス

### Mimir
Ingress 未設定のため、kubectl port-forward でアクセスする。
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