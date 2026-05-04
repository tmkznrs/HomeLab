#!/usr/bin/env bash
# 00-lxd-init.sh — LXD の初期化（preseed）と OSD ストレージプールのセットアップ

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/node-config.sh"

# ────────────────────────────────────────────────────────────────────
# Step 1: LXD 初期化（lxd init は一度だけ実行）
# ────────────────────────────────────────────────────────────────────
if lxc storage show default &>/dev/null; then
  echo "[SKIP] LXD は既に初期化されています。"
else
  echo "[INFO] LXD を初期化します (ブリッジ: $BRIDGE, サブネット: $BRIDGE_SUBNET)"
  lxd init --preseed < "$SCRIPT_DIR/../lxd/init.yaml"
  echo "[OK] LXD 初期化完了"
fi
echo ""
lxc storage list
echo ""
lxc network list

# ────────────────────────────────────────────────────────────────────
# Step 2: OSD 用 LVM ストレージプールのセットアップ
# ────────────────────────────────────────────────────────────────────
echo ""
echo "[INFO] OSD ストレージプール ($OSD_POOL) をセットアップします..."

OSD_DISK="/dev/nvme0n1"
OSD_PART="${OSD_DISK}p4"

if lxc storage show "$OSD_POOL" &>/dev/null; then
  echo "[SKIP] ストレージプール '$OSD_POOL' は既に存在します。"
else
  if [ ! -b "$OSD_PART" ]; then
    echo "[INFO] OSD パーティション ($OSD_PART) を作成します (600 GiB)..."
    sudo sgdisk -n "4:0:+600GiB" -t "4:8e00" "$OSD_DISK"
    sudo partx -a "$OSD_DISK" || true
    sudo udevadm settle
  fi
  echo "[INFO] LXD LVM ストレージプール '$OSD_POOL' を作成します..."
  lxc storage create "$OSD_POOL" lvm source="$OSD_PART"
  echo "[OK] ストレージプール '$OSD_POOL' を作成しました"
fi
echo ""
lxc storage list
