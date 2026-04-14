# k8s-homelab

LXD コンテナ上に Kubernetes HA クラスタを構築・運用するためのリポジトリ。

## 前提条件

- Ubuntu 24.04 ホスト
- LXD インストール済み（`snap install lxd`）
- Helm インストール済み

## ディレクトリ構成

```
.
├── scripts/          # クラスタ構築スクリプト（番号順に実行）
│   ├── lib/
│   │   └── node-config.sh    # ノード定義の単一ソース
│   ├── 00-lxd-init.sh
│   ├── 01-host-prereqs.sh
│   ├── ...
│   └── 10-install-cni.sh
└── k8s/              # Kubernetes マニフェスト
    ├── namespaces/   # Namespace 定義
    ├── infra/        # クラスタ基盤コンポーネント
    ├── monitoring/   # 可観測性スタック
    ├── databases/    # ステートフルワークロード
    └── apps/         # 自作アプリケーション
```

## クラスタ構築手順

以下のスクリプトをホストで番号順に実行する。

```bash
cd scripts/

bash 00-lxd-init.sh          # LXD 初期化
bash 01-host-prereqs.sh      # ホストのカーネル設定
bash 02-create-profile.sh    # LXD プロファイル作成
bash 03-launch-nodes.sh      # コンテナ起動（6ノード）
bash 04-configure-nodes.sh   # コンテナ内基本設定
bash 05-install-containerd.sh  # containerd インストール
bash 06-install-k8s-tools.sh   # kubeadm / kubelet / kubectl インストール
bash 07-init-control-plane.sh  # コントロールプレーン初期化（kube-vip 配置）
bash 08-join-control-planes.sh # CP ノード追加（07 実行から2時間以内）
bash 09-join-workers.sh        # ワーカーノード追加
bash 10-install-cni.sh         # Flannel CNI インストール
```

> `07` 実行後、証明書キーの有効期限は **2時間**。速やかに `08` を実行すること。

## クラスタ仕様

| 項目 | 値 |
|---|---|
| Kubernetes | v1.35.3 |
| コントロールプレーン | 3台（k8s-cp-1〜3、10.10.0.11〜13） |
| ワーカー | 3台（k8s-wk-1〜3、10.10.0.21〜23） |
| VIP | 10.10.0.10（kube-vip v1.1.2） |
| CNI | Flannel v0.28.2（host-gw） |
| コンテナランタイム | containerd |
| Pod CIDR | 10.244.0.0/16 |
| Service CIDR | 10.96.0.0/12 |

## デプロイ済みコンポーネント

| コンポーネント | Namespace | アクセス |
|---|---|---|
| MetalLB | `infra` | IPプール: 10.10.0.100〜200 |
| ingress-nginx | `infra` | External IP: 10.10.0.100 |
| metrics-server | `kube-system` | `kubectl top nodes` |
| Headlamp | `infra` | http://192.168.1.107/headlamp/ |
| Grafana | `observability` | http://192.168.1.107/grafana/ |

## Headlamp

Kubernetes 管理 UI。

**アクセス:** `http://192.168.1.107/headlamp/`

**トークン取得:**
```bash
kubectl get secret headlamp-token -n infra -o jsonpath='{.data.token}' | base64 -d
```

トークンはブラウザの localStorage に保存されるため、同じブラウザからは再入力不要。

## ホストのiptables設定

ingress-nginx の External IP（10.10.0.100）はLXDブリッジ内のプライベートIPのため、
LAN上の他マシンからアクセスするにはホストでポート転送を設定する。

```bash
# iptables インストール
sudo apt install -y iptables iptables-persistent

# ポート転送ルール追加（ホスト:80 → ingress-nginx:80）
sudo iptables -t nat -A PREROUTING -i enp1s0 -p tcp --dport 80 -j DNAT --to-destination 10.10.0.100:80
sudo iptables -A FORWARD -p tcp -d 10.10.0.100 --dport 80 -j ACCEPT

# 再起動後も保持
sudo netfilter-persistent save
```

## コンポーネントのデプロイ手順

クラスタ構築（スクリプト00〜10）完了後、以下の順でコンポーネントをデプロイする。

### 1. Namespace 作成

```bash
kubectl apply -f k8s/namespaces/
```

### 2. MetalLB

```bash
helm repo add metallb https://metallb.github.io/metallb
helm repo update
helm install metallb metallb/metallb -n infra --create-namespace

# IPアドレスプール設定
kubectl apply -f k8s/infra/metallb/ippool.yaml
```

### 3. ingress-nginx

MetalLB が External IP を払い出すまで待ってからデプロイする。

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  -n infra \
  -f k8s/infra/ingress-nginx/values.yaml
```

デプロイ確認（External IP が `10.10.0.100` になること）:

```bash
kubectl get svc -n infra ingress-nginx-controller
```

### 4. metrics-server

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update
helm install metrics-server metrics-server/metrics-server \
  -n kube-system \
  -f k8s/infra/metrics-server/values.yaml
```

動作確認:

```bash
kubectl top nodes
```

> `--kubelet-insecure-tls` を有効化している（LXD コンテナの kubelet 証明書に IP SAN がないため）。

### 5. Headlamp

```bash
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
helm repo update
helm install headlamp headlamp/headlamp \
  -n infra \
  -f k8s/infra/headlamp/values.yaml

# ServiceAccount トークン Secret と Ingress を適用
kubectl apply -f k8s/infra/headlamp/token.yaml
kubectl apply -f k8s/infra/headlamp/ingress.yaml
```

## 本番環境向け変更点

現在の構成はリソース削減のため一部設定を簡略化している。本番環境では以下を見直すこと。

### Grafana レプリカ数

`k8s/observability/05-grafana/grafana.yaml` の `replicas` を `2` 以上に戻す。

```yaml
spec:
  deployment:
    spec:
      replicas: 2  # 現在は 1（メモリ削減のため）
```

セッションストアに PostgreSQL を使用しているため、複数レプリカでもログアウトは発生しない。

### PostgreSQL レプリカ数

`k8s/observability/03-postgres/cluster.yaml` の `instances` を `3` に戻す。

```yaml
spec:
  instances: 3  # 現在は 2（メモリ削減のため）
```

2レプリカでは二重障害（スタンバイ障害 → プライマリ障害）に耐えられない。
本番環境では3レプリカにしてスタンバイを2台確保すること。
