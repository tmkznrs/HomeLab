#!/usr/bin/env bash
# 05-install-containerd.sh — 各コンテナに containerd をインストールする
# Ubuntu 標準の containerd パッケージをインストールし、
# SystemdCgroup=true に設定する（kubeadm の必須要件）
# 前提: 04-configure-nodes.sh 実行済み

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/node-config.sh"

# コンテナ内で実行する containerd インストールスクリプト
CONTAINERD_INSTALL_SCRIPT=$(cat << 'INNER_EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "  → Ubuntu 標準の containerd をインストール..."
apt-get update -qq
apt-get install -y -qq containerd 2>/dev/null

echo "  → containerd の設定を生成 (SystemdCgroup=true, sandbox_image=pause:3.10.1)..."
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
# SystemdCgroup を有効化 (kubeadm/kubelet との cgroup driver 一致が必須)
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
# pause イメージを kubeadm 1.35.x が使用するバージョンに合わせる
sed -i 's|sandbox_image = "registry.k8s.io/pause:[^"]*"|sandbox_image = "registry.k8s.io/pause:3.10.1"|' \
    /etc/containerd/config.toml

# 設定が反映されているか確認
if grep -q "SystemdCgroup = true" /etc/containerd/config.toml && \
   grep -q "pause:3.10.1" /etc/containerd/config.toml; then
  echo "  → SystemdCgroup = true, sandbox_image = pause:3.10.1 を確認"
else
  echo "  [ERROR] containerd の設定に失敗しました"
  exit 1
fi

echo "  → containerd を起動・有効化..."
systemctl enable containerd --quiet
systemctl restart containerd

# 起動確認
sleep 1
if systemctl is-active containerd --quiet; then
  echo "  → containerd が正常に起動しています"
else
  echo "  [ERROR] containerd の起動に失敗しました"
  systemctl status containerd --no-pager
  exit 1
fi

echo "  → インストール完了"
INNER_EOF
)

echo "[INFO] 全ノードへの containerd インストールを開始します..."
echo ""

for NODE in "${NODE_ORDER[@]}"; do
  echo "[${NODE}] containerd をインストール中..."

  # コンテナが起動しているか確認
  STATE=$(lxc info "$NODE" 2>/dev/null | awk '/^Status:/{print $2}' || echo "MISSING")
  if [[ "$STATE" != "RUNNING" ]]; then
    echo "  [SKIP] コンテナが RUNNING 状態ではありません (状態: $STATE)"
    continue
  fi

  # 既にインストール済み かつ sandbox_image も正しければスキップ
  if lxc exec "$NODE" -- systemctl is-active containerd --quiet 2>/dev/null && \
     lxc exec "$NODE" -- grep -q 'pause:3.10.1' /etc/containerd/config.toml 2>/dev/null; then
    echo "  [SKIP] containerd は既に起動しており、sandbox_image も正しく設定されています"
    continue
  fi

  # インストールスクリプトを実行
  echo "$CONTAINERD_INSTALL_SCRIPT" | lxc exec "$NODE" -- bash -s

  echo "[${NODE}] 完了"
  echo ""
done

echo "[INFO] containerd バージョン確認:"
for NODE in "${NODE_ORDER[@]}"; do
  VERSION=$(lxc exec "$NODE" -- ctr version 2>/dev/null | awk '/Server/{found=1} found && /Version:/{print $2; exit}' || echo "取得失敗")
  printf "  %-12s containerd %s\n" "$NODE" "$VERSION"
done

echo ""
echo "[OK] 全ノードへの containerd インストールが完了しました"
echo ""
echo "次のステップ: kubeadm のインストールと k8s クラスターの構築 (Phase 2)"
