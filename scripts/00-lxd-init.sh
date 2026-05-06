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
# Step 2: ノードルートディスク用 LVM thin ストレージプール (fast) のセットアップ
# nvme0n1p4: 150 GiB, LVM thin — CP コンテナ・ワーカー VM のルートディスク置き場
# ────────────────────────────────────────────────────────────────────
echo ""
echo "[INFO] fast ストレージプール ($FAST_POOL) をセットアップします..."

NVMe_DISK="/dev/nvme0n1"
FAST_PART="${NVMe_DISK}p4"

if lxc storage show "$FAST_POOL" &>/dev/null; then
  echo "[SKIP] ストレージプール '$FAST_POOL' は既に存在します。"
else
  if [ ! -b "$FAST_PART" ]; then
    echo "[INFO] fast パーティション ($FAST_PART) を作成します (150 GiB)..."
    sudo sgdisk -n "4:0:+150GiB" -t "4:8e00" "$NVMe_DISK"
    sudo partx -a "$NVMe_DISK" || true
    sudo udevadm settle
  fi
  echo "[INFO] LXD LVM thin ストレージプール '$FAST_POOL' を作成します..."
  lxc storage create "$FAST_POOL" lvm source="$FAST_PART"
  echo "[OK] ストレージプール '$FAST_POOL' を作成しました"
fi

# ────────────────────────────────────────────────────────────────────
# Step 3: Ceph OSD 用 LVM thick ストレージプール (osd) のセットアップ
# nvme0n1p5: ~740 GiB, LVM thick (thin pool 無効) — Ceph BlueStore 向け固定割当
# thin pool を使わないことで BlueStore の書き込み遅延 (slow ops) を防ぐ
# ────────────────────────────────────────────────────────────────────
echo ""
echo "[INFO] OSD ストレージプール ($OSD_POOL) をセットアップします..."

OSD_PART="${NVMe_DISK}p5"

if lxc storage show "$OSD_POOL" &>/dev/null; then
  echo "[SKIP] ストレージプール '$OSD_POOL' は既に存在します。"
else
  if [ ! -b "$OSD_PART" ]; then
    echo "[INFO] OSD パーティション ($OSD_PART) を作成します (残り全領域)..."
    sudo sgdisk -n "5:0:0" -t "5:8e00" "$NVMe_DISK"
    sudo partx -a "$NVMe_DISK" || true
    sudo udevadm settle
  fi
  echo "[INFO] LXD LVM thick ストレージプール '$OSD_POOL' を作成します..."
  lxc storage create "$OSD_POOL" lvm source="$OSD_PART" lvm.use_thinpool=false
  echo "[OK] ストレージプール '$OSD_POOL' を作成しました"
fi
echo ""
lxc storage list
