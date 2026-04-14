#!/usr/bin/env bash
# 01-host-prereqs.sh — ホスト側の前提条件設定
# Kubernetes ノードが必要とするカーネルモジュールと sysctl をホストに設定する
# sudo で実行すること

set -euo pipefail

# sudo チェック
if [[ "$EUID" -ne 0 ]]; then
  echo "[ERROR] このスクリプトは root 権限が必要です。sudo で実行してください:"
  echo "  sudo bash $0"
  exit 1
fi

echo "[INFO] カーネルモジュールの設定..."

# 永続化: 再起動後も自動ロード
cat > /etc/modules-load.d/k8s.conf << 'EOF'
overlay
br_netfilter
nf_conntrack
EOF

# 即時ロード
MODULES=(overlay br_netfilter nf_conntrack)
for mod in "${MODULES[@]}"; do
  if lsmod | grep -q "^${mod} "; then
    echo "  [SKIP] $mod (既にロード済み)"
  else
    modprobe "$mod" && echo "  [OK] $mod をロード"
  fi
done

echo ""
echo "[INFO] sysctl の設定..."

cat > /etc/sysctl.d/99-k8s-lxd.conf << 'EOF'
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sysctl --system --quiet
echo "  [OK] sysctl を適用しました"

echo ""
echo "[INFO] 設定確認:"
echo "  ip_forward             = $(sysctl -n net.ipv4.ip_forward)"
echo "  bridge-nf-call-iptables = $(sysctl -n net.bridge.bridge-nf-call-iptables)"
echo "  bridge-nf-call-ip6tables = $(sysctl -n net.bridge.bridge-nf-call-ip6tables)"
echo ""
echo "[OK] ホスト前提条件の設定完了"
