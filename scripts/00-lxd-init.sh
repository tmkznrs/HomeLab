#!/usr/bin/env bash
# 00-lxd-init.sh — LXD の初期化（preseed）
# 実行条件: LXD が未初期化であること（lxc storage list が空）
# 一度だけ実行する

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/node-config.sh"

# 既に初期化済みか確認
if lxc storage list --format csv 2>/dev/null | grep -q .; then
  echo "[SKIP] LXD は既に初期化されています。"
  lxc storage list
  lxc network list
  exit 0
fi

echo "[INFO] LXD を初期化します (ブリッジ: $BRIDGE, サブネット: $BRIDGE_SUBNET)"

lxd init --preseed <<EOF
config:
  core.https_address: ""
networks:
- name: ${BRIDGE}
  type: bridge
  config:
    ipv4.address: ${BRIDGE_GW}/24
    ipv4.nat: "true"
    ipv6.address: none
    ipv6.nat: "false"
    dns.mode: managed
storage_pools:
- name: default
  driver: zfs
  config:
    source: "/dev/nvme0n1p4"
profiles:
- name: default
  devices:
    eth0:
      name: eth0
      network: ${BRIDGE}
      type: nic
    root:
      path: /
      pool: default
      type: disk
projects: []
cluster: null
EOF

echo "[OK] LXD 初期化完了"
echo ""
lxc storage list
echo ""
lxc network list
