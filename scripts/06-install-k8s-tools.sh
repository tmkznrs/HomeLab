#!/usr/bin/env bash
# 06-install-k8s-tools.sh — 各コンテナに kubeadm / kubelet / kubectl をインストールする
# kubernetes apt リポジトリ (pkgs.k8s.io) から v1.35 系を取得し、バージョンを固定する
# 前提: 05-install-containerd.sh 実行済み

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/node-config.sh"

K8S_MINOR="1.35"

K8S_INSTALL_SCRIPT=$(cat << INNER_EOF
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "  → kubernetes apt リポジトリを追加..."
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

echo "  → kubeadm / kubelet / kubectl をインストール..."
apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl 2>/dev/null

echo "  → パッケージバージョンを固定 (apt-mark hold)..."
apt-mark hold kubelet kubeadm kubectl

echo "  → kubelet を有効化（起動は kubeadm init/join が行う）..."
systemctl enable kubelet --quiet

echo "  → インストール完了"
INNER_EOF
)

echo "[INFO] 全ノードへの kubernetes ツールインストールを開始します..."
echo "  対象バージョン: v${K8S_MINOR}.x"
echo ""

for NODE in "${NODE_ORDER[@]}"; do
  echo "[${NODE}] kubeadm / kubelet / kubectl をインストール中..."

  STATE=$(lxc info "$NODE" 2>/dev/null | awk '/^Status:/{print $2}' || echo "MISSING")
  if [[ "$STATE" != "RUNNING" ]]; then
    echo "  [SKIP] コンテナが RUNNING 状態ではありません (状態: $STATE)"
    continue
  fi

  if lxc exec "$NODE" -- kubeadm version &>/dev/null 2>&1; then
    echo "  [SKIP] kubeadm は既にインストールされています"
    continue
  fi

  echo "$K8S_INSTALL_SCRIPT" | lxc exec "$NODE" -- bash -s

  echo "[${NODE}] 完了"
  echo ""
done

echo "[INFO] インストール確認:"
for NODE in "${NODE_ORDER[@]}"; do
  STATE=$(lxc info "$NODE" 2>/dev/null | awk '/^Status:/{print $2}' || echo "MISSING")
  if [[ "$STATE" != "RUNNING" ]]; then
    printf "  %-12s SKIP\n" "$NODE"
    continue
  fi
  VERSION=$(lxc exec "$NODE" -- kubeadm version -o short 2>/dev/null || echo "取得失敗")
  printf "  %-12s %s\n" "$NODE" "$VERSION"
done

echo ""
echo "[OK] 全ノードへの kubernetes ツールインストールが完了しました"
echo ""
echo "次のステップ: 07-init-control-plane.sh を実行してコントロールプレーンを初期化してください"
