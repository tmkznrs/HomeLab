#!/usr/bin/env bash
# 08-join-control-planes.sh — k8s-cp-2, k8s-cp-3 をコントロールプレーンとして join
# 前提: 07-init-control-plane.sh 実行済み（2時間以内に実行すること）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/node-config.sh"

JOIN_INFO="$HOME/.kube/join-info.env"
FIRST_CP="k8s-cp-1"
CP_NODES=(k8s-cp-2 k8s-cp-3)

# join 情報を読み込む
if [[ ! -f "$JOIN_INFO" ]]; then
  echo "[ERROR] $JOIN_INFO が見つかりません。07-init-control-plane.sh を先に実行してください"
  exit 1
fi
source "$JOIN_INFO"

echo "[INFO] コントロールプレーンの join を開始します"
echo "  対象: ${CP_NODES[*]}"
echo "  エンドポイント: $JOIN_ENDPOINT"
echo ""

for NODE in "${CP_NODES[@]}"; do
  echo "=== $NODE ==="

  STATE=$(lxc info "$NODE" 2>/dev/null | awk '/^Status:/{print $2}' || echo "MISSING")
  if [[ "$STATE" != "RUNNING" ]]; then
    echo "  [SKIP] コンテナが RUNNING 状態ではありません"
    continue
  fi

  # 既に join 済みか確認
  if lxc exec "$NODE" -- test -f /etc/kubernetes/admin.conf 2>/dev/null; then
    echo "  [SKIP] 既に join 済みです (/etc/kubernetes/admin.conf が存在)"
    continue
  fi

  # --- kube-vip manifest をコピー ---
  echo "  → kube-vip manifest を配置..."
  lxc exec "$NODE" -- mkdir -p /etc/kubernetes/manifests
  lxc file pull "${FIRST_CP}/etc/kubernetes/manifests/kube-vip.yaml" /tmp/kube-vip.yaml
  lxc file push /tmp/kube-vip.yaml "${NODE}/etc/kubernetes/manifests/kube-vip.yaml"
  echo "    [OK] kube-vip.yaml を配置しました"

  # --- kubeadm join ---
  echo "  → kubeadm join を実行中..."
  lxc exec "$NODE" -- kubeadm join "$JOIN_ENDPOINT" \
    --token "$JOIN_TOKEN" \
    --discovery-token-ca-cert-hash "sha256:${JOIN_HASH}" \
    --control-plane \
    --certificate-key "$JOIN_CERT_KEY" \
    --ignore-preflight-errors=SystemVerification

  # --- kubeconfig 設定 ---
  lxc exec "$NODE" -- bash -s << 'EOF'
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config
EOF
  echo "  [OK] $NODE の join が完了しました"
  echo ""
done

echo "[INFO] ノード状態確認..."
sleep 5
kubectl get nodes -o wide 2>/dev/null || lxc exec "$FIRST_CP" -- kubectl get nodes -o wide

echo ""
echo "[OK] コントロールプレーンの join が完了しました"
echo "   次: 09-join-workers.sh を実行してワーカーノードを追加してください"
