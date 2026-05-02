#!/usr/bin/env bash
# 03-launch-nodes.sh — 6台のLXDコンテナを起動し静的IPを割り当てる
# 前提: 00-lxd-init.sh、01-host-prereqs.sh、02-create-profile.sh 実行済み

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/node-config.sh"

echo "[INFO] LXDコンテナの起動を開始します..."
echo ""

for NODE in "${NODE_ORDER[@]}"; do
  ROLE=${NODE_ROLE[$NODE]}
  TYPE=${NODE_TYPE[$NODE]}
  IP=${NODE_IP[$NODE]}
  MEM=${NODE_MEM[$NODE]}
  DISK=${NODE_DISK[$NODE]}

  printf "[%-10s] " "$NODE"

  # 冪等性チェック: 既存インスタンスはスキップ
  if lxc info "$NODE" &>/dev/null; then
    echo "既に存在します (IP: $IP) — スキップ"
    continue
  fi

  echo "起動中 (role=$ROLE, type=$TYPE, ip=$IP, mem=$MEM, disk=$DISK)..."

  if [[ "$TYPE" == "vm" ]]; then
    # VM として起動
    lxc launch "$IMAGE" "$NODE" \
      --vm \
      --profile "$VM_PROFILE" \
      --config limits.cpu="$VCPU" \
      --config limits.memory="$MEM" \
      --device root,size="$DISK"
    # OSD ディスク: dir ドライバーはブロックボリューム非対応のため RAW ファイルで代替
    OSD_IMG="/var/lib/lxd-osd/osd-${NODE}.img"
    sudo mkdir -p /var/lib/lxd-osd && sudo chown "$(id -u):$(id -g)" /var/lib/lxd-osd
    truncate -s "$OSD_DISK_SIZE" "$OSD_IMG"
    lxc config device add "$NODE" osd disk source="$OSD_IMG"
  else
    # コンテナとして起動
    lxc launch "$IMAGE" "$NODE" \
      --profile "$PROFILE" \
      --config limits.cpu="$VCPU" \
      --config limits.memory="$MEM" \
      --device root,size="$DISK"
  fi

  # 静的IP割り当て（LXD管理のDHCPリザベーション）
  # プロファイル由来のデバイスはoverrideで上書きする（LXD 5.x の制約）
  lxc config device override "$NODE" eth0 ipv4.address="$IP"

  # IPリザベーションを反映させるために再起動
  lxc restart --force "$NODE"

  printf "[%-10s] 起動完了 → %s\n" "$NODE" "$IP"
done

echo ""
echo "[INFO] コンテナ一覧:"
lxc list

echo ""
echo "[INFO] ネットワーク疎通確認（各ノードからゲートウェイへping）..."
for NODE in "${NODE_ORDER[@]}"; do
  RESULT=$(lxc exec "$NODE" -- ping -c 1 -W 2 "$BRIDGE_GW" 2>&1 | grep -E "1 received|0 received" || true)
  if echo "$RESULT" | grep -q "1 received"; then
    printf "  [OK]   %-12s → %s\n" "$NODE" "$BRIDGE_GW"
  else
    printf "  [FAIL] %-12s → %s (応答なし)\n" "$NODE" "$BRIDGE_GW"
  fi
done

echo ""
echo "[OK] 全ノードの起動処理が完了しました"
