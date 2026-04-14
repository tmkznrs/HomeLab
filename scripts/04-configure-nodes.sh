#!/usr/bin/env bash
# 04-configure-nodes.sh — コンテナ内の基本設定
# スワップ無効化、sysctl、必要パッケージのインストールを行う
# 前提: 03-launch-nodes.sh 実行済み（全コンテナが RUNNING 状態）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/node-config.sh"

# コンテナ内で実行するセットアップスクリプト（ヒアドキュメント）
NODE_SETUP_SCRIPT=$(cat << 'INNER_EOF'
set -euo pipefail

echo "  → スワップを無効化..."
swapoff -a
[ -f /etc/fstab ] && sed -i '/\bswap\b/d' /etc/fstab || true

echo "  → sysctl を設定..."
cat > /etc/sysctl.d/99-k8s.conf << 'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sysctl --system --quiet

echo "  → 必要パッケージをインストール..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  curl \
  gnupg \
  apt-transport-https \
  ca-certificates \
  2>/dev/null

echo "  → カーネルモジュールの確認..."
for mod in overlay br_netfilter; do
  if lsmod 2>/dev/null | grep -q "^${mod} "; then
    echo "    [OK] $mod"
  else
    echo "    [WARN] $mod が見つかりません (ホストでのロードが必要)"
  fi
done

echo "  → セットアップ完了"
INNER_EOF
)

echo "[INFO] 全ノードのコンテナ内設定を開始します..."
echo ""

for NODE in "${NODE_ORDER[@]}"; do
  echo "[${NODE}] 設定中..."

  # コンテナが起動しているか確認
  STATE=$(lxc info "$NODE" 2>/dev/null | awk '/^Status:/{print $2}' || echo "MISSING")
  if [[ "$STATE" != "RUNNING" ]]; then
    echo "  [SKIP] コンテナが RUNNING 状態ではありません (状態: $STATE)"
    continue
  fi

  # セットアップスクリプトをコンテナ内で実行
  echo "$NODE_SETUP_SCRIPT" | lxc exec "$NODE" -- bash -s

  echo "[${NODE}] 完了"
  echo ""
done

echo "[OK] 全ノードのコンテナ内設定が完了しました"
