#!/usr/bin/env bash
# 12-install-rook-ceph.sh — Rook-Ceph Operator + クラスターのインストール
# 前提: ワーカーノードが VM として起動済み（OSD 用 /dev/sdb が存在すること）
#       lsblk で確認: lxc exec k8s-wk-1 -- lsblk

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "======================================================"
echo "  Rook-Ceph インストール"
echo "======================================================"
echo ""

# ────────────────────────────────────────────────────────────────────────────
# Step 1: Helm リポジトリ追加
# ────────────────────────────────────────────────────────────────────────────
echo "[1/3] Helm リポジトリを追加します..."
helm repo add rook-release https://charts.rook.io/release
helm repo update
echo "  [OK]"

# ────────────────────────────────────────────────────────────────────────────
# Step 2: Rook Operator をインストール
# ────────────────────────────────────────────────────────────────────────────
echo "[2/4] Rook Ceph Operator をインストールします..."
helm upgrade --install rook-ceph rook-release/rook-ceph \
  -n storage --create-namespace \
  -f "$REPO_ROOT/k8s/storage/rook-ceph/operator-values.yaml" \
  --wait
echo "  [OK] Operator が起動しました"

# ────────────────────────────────────────────────────────────────────────────
# Step 3: CephCluster / CephBlockPool / StorageClass を適用
# ────────────────────────────────────────────────────────────────────────────
echo "[3/4] CephCluster / CephBlockPool / StorageClass / CephObjectStore を適用します..."
kubectl apply -f "$REPO_ROOT/k8s/storage/rook-ceph/cluster.yaml"

echo ""
echo "  Ceph クラスターの初期化を待機中（最大15分）..."
kubectl -n storage wait cephcluster rook-ceph \
  --for=condition=Ready \
  --timeout=900s

echo ""
echo "  Object Store (RGW) の起動を待機中（最大10分）..."
kubectl -n storage wait cephobjectstore my-store \
  --for=condition=Ready \
  --timeout=600s

# ────────────────────────────────────────────────────────────────────────────
# Step 4: Toolbox のデプロイ + RGW ユーザーを作成（固定クレデンシャル）
# ────────────────────────────────────────────────────────────────────────────
# toolbox は rook-ceph operator chart v1.14 以降は含まれず、
# rook-ceph-cluster chart の templates/deployment.yaml から別途 apply する
echo "[4/4] Toolbox をデプロイします..."
helm template rook-ceph-cluster rook-release/rook-ceph-cluster \
  -n storage \
  --set operatorNamespace=storage \
  --set clusterName=rook-ceph \
  --set toolbox.enabled=true \
  -s templates/deployment.yaml \
  | kubectl apply -f -

echo "  Toolbox Pod の起動を待機中..."
kubectl -n storage rollout status deploy/rook-ceph-tools --timeout=120s

kubectl -n storage exec deploy/rook-ceph-tools -- \
  radosgw-admin user create \
  --uid=observability \
  --display-name="Observability Stack" \
  --access-key=ceph-obs-access \
  --secret-key=ceph-obs-secret 2>/dev/null \
  || kubectl -n storage exec deploy/rook-ceph-tools -- \
     radosgw-admin user modify \
     --uid=observability \
     --access-key=ceph-obs-access \
     --secret-key=ceph-obs-secret

echo "  [OK] RGW ユーザーが作成されました"
echo "    Access Key : ceph-obs-access"
echo "    Secret Key : ceph-obs-secret"
echo "    Endpoint   : http://rook-ceph-rgw-my-store.storage.svc"

echo ""
echo "======================================================"
echo "[OK] Rook-Ceph のインストールが完了しました"
echo "======================================================"
echo ""
echo "次のステップ: Loki / Mimir / Tempo の Helm upgrade"
echo "  helm upgrade loki grafana/loki -n observability -f k8s/observability/06-loki/values.yaml"
echo "  helm upgrade mimir grafana/mimir-distributed -n observability -f k8s/observability/07-mimir/values.yaml"
echo "  helm upgrade tempo grafana/tempo-distributed -n observability -f k8s/observability/08-tempo/values.yaml"
echo ""
echo "検証コマンド:"
echo "  kubectl -n storage get cephcluster"
echo "  kubectl -n storage get cephobjectstore"
echo "  kubectl -n storage get pods"
echo "  kubectl get storageclass ceph-block"
echo ""
echo "OSD デバイス名の確認（適用前に実施）:"
echo "  lxc exec k8s-wk-1 -- lsblk"
echo "  lxc exec k8s-wk-2 -- lsblk"
echo "  lxc exec k8s-wk-3 -- lsblk"
