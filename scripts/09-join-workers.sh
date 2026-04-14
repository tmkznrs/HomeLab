#!/usr/bin/env bash
# 09-join-workers.sh — k8s-wk-1,2,3 をワーカーとして join
# 前提: 08-join-control-planes.sh 実行済み

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/node-config.sh"

JOIN_INFO="$HOME/.kube/join-info.env"
FIRST_CP="k8s-cp-1"
WORKER_NODES=(k8s-wk-1 k8s-wk-2 k8s-wk-3)

# join 情報を読み込む
if [[ ! -f "$JOIN_INFO" ]]; then
  echo "[ERROR] $JOIN_INFO が見つかりません。07-init-control-plane.sh を先に実行してください"
  exit 1
fi
source "$JOIN_INFO"

# トークンが期限切れの場合は再生成
echo "[INFO] トークンの有効性を確認..."
if ! lxc exec "$FIRST_CP" -- kubeadm token list 2>/dev/null | grep -q "$JOIN_TOKEN"; then
  echo "  [WARN] トークンが期限切れです。新しいトークンを生成します..."
  NEW_TOKEN=$(lxc exec "$FIRST_CP" -- kubeadm token create 2>/dev/null)
  JOIN_TOKEN="$NEW_TOKEN"
  sed -i "s/^JOIN_TOKEN=.*/JOIN_TOKEN=\"${NEW_TOKEN}\"/" "$JOIN_INFO"
  echo "  [OK] 新しいトークン: $NEW_TOKEN"
fi

echo "[INFO] ワーカーノードの join を開始します"
echo "  対象: ${WORKER_NODES[*]}"
echo "  エンドポイント: $JOIN_ENDPOINT"
echo ""

for NODE in "${WORKER_NODES[@]}"; do
  echo "=== $NODE ==="

  STATE=$(lxc info "$NODE" 2>/dev/null | awk '/^Status:/{print $2}' || echo "MISSING")
  if [[ "$STATE" != "RUNNING" ]]; then
    echo "  [SKIP] コンテナが RUNNING 状態ではありません"
    continue
  fi

  # 既に join 済みか確認
  if lxc exec "$NODE" -- test -f /etc/kubernetes/kubelet.conf 2>/dev/null; then
    echo "  [SKIP] 既に join 済みです"
    continue
  fi

  echo "  → kubeadm join を実行中..."
  lxc exec "$NODE" -- kubeadm join "$JOIN_ENDPOINT" \
    --token "$JOIN_TOKEN" \
    --discovery-token-ca-cert-hash "sha256:${JOIN_HASH}" \
    --ignore-preflight-errors=SystemVerification

  echo "  [OK] $NODE の join が完了しました"
  echo ""
done

echo "[INFO] ノード状態確認..."
sleep 5
kubectl get nodes -o wide 2>/dev/null || lxc exec "$FIRST_CP" -- kubectl get nodes -o wide

echo ""
echo "[OK] ワーカーノードの join が完了しました"
echo "   次: 10-install-cni.sh を実行して CNI をインストールしてください"
