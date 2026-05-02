#!/usr/bin/env bash
# 02-create-profile.sh — k8s LXD プロファイルの作成
# Kubernetes コンテナに必要な権限・設定を持つプロファイルを作成する

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/node-config.sh"

# ── k8s プロファイル（コントロールプレーン / コンテナ用）────────────────────
if lxc profile show "$PROFILE" &>/dev/null; then
  echo "[SKIP] プロファイル '$PROFILE' は既に存在します。"
else
  echo "[INFO] LXD プロファイル '$PROFILE' を作成します..."
  lxc profile create "$PROFILE"
  lxc profile edit "$PROFILE" < "$SCRIPT_DIR/../lxd/profile.yaml"
  echo "[OK] プロファイル '$PROFILE' を作成しました"
  echo ""
  lxc profile show "$PROFILE"
fi

# ── k8s-vm プロファイル（ワーカー VM 用）────────────────────────────────────
if lxc profile show "$VM_PROFILE" &>/dev/null; then
  echo "[SKIP] プロファイル '$VM_PROFILE' は既に存在します。"
else
  echo "[INFO] LXD プロファイル '$VM_PROFILE' を作成します..."
  lxc profile create "$VM_PROFILE"
  lxc profile edit "$VM_PROFILE" < "$SCRIPT_DIR/../lxd/vm-profile.yaml"
  echo "[OK] プロファイル '$VM_PROFILE' を作成しました"
  echo ""
  lxc profile show "$VM_PROFILE"
fi
