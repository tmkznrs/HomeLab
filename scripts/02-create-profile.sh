#!/usr/bin/env bash
# 02-create-profile.sh — k8s LXD プロファイルの作成
# Kubernetes コンテナに必要な権限・設定を持つプロファイルを作成する

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/node-config.sh"

# 既存チェック
if lxc profile show "$PROFILE" &>/dev/null; then
  echo "[SKIP] プロファイル '$PROFILE' は既に存在します。"
  lxc profile show "$PROFILE"
  exit 0
fi

echo "[INFO] LXD プロファイル '$PROFILE' を作成します..."

lxc profile create "$PROFILE"

# プロファイル設定を適用
lxc profile edit "$PROFILE" << 'EOF'
config:
  # containerd が overlayfs でポッドコンテナを作成するために必要
  security.nesting: "true"

  # 特権コンテナ化: UID マッピングを行わずホストの root と同一にする
  # /dev/kmsg 等のデバイスへのアクセスに必要（kubelet の oomWatcher）
  security.privileged: "true"

  # コンテナ起動前にホストでロードするカーネルモジュール
  linux.kernel_modules: overlay,br_netfilter

  # AppArmor を unconfined に: containerd/iptables のシステムコール制限を解除
  # capability drop をクリア: iptables-restore, mount 等に必要な権限を確保
  # proc:rw: コンテナ内から sysctl を書き込み可能にする（kubeadm preflight 要件）
  # cgroup:rw: kubelet のポッド cgroup 管理に必要
  # /sys/fs/bpf bind mount: Cilium が eBPF プログラムをロードするために必要
  raw.lxc: |
    lxc.apparmor.profile=unconfined
    lxc.cap.drop=
    lxc.mount.auto=proc:rw sys:ro cgroup:rw
    lxc.mount.entry = none sys/fs/bpf bpf rw,relatime,create=dir 0 0

  # コンテナ内のスワップを無効化（k8s の必須要件）
  limits.memory.swap: "false"
  limits.memory.swap.priority: "0"

description: Kubernetes ノード用 LXD プロファイル

devices:
  eth0:
    name: eth0
    network: lxdbr0
    type: nic
  kmsg:
    path: /dev/kmsg
    source: /dev/kmsg
    type: unix-char
  root:
    path: /
    pool: default
    size: 30GiB
    type: disk
EOF

echo "[OK] プロファイル '$PROFILE' を作成しました"
echo ""
lxc profile show "$PROFILE"
