#!/usr/bin/env bash
# lib/node-config.sh — ノード定義の単一ソース
# このファイルを source して各スクリプトから参照する

# ノードの役割 (cp=コントロールプレーン, wk=ワーカー)
declare -A NODE_ROLE=(
  [k8s-cp-1]=cp [k8s-cp-2]=cp [k8s-cp-3]=cp
  [k8s-wk-1]=wk [k8s-wk-2]=wk [k8s-wk-3]=wk
)

# インスタンス種別 (container / vm)
declare -A NODE_TYPE=(
  [k8s-cp-1]=container [k8s-cp-2]=container [k8s-cp-3]=container
  [k8s-wk-1]=vm [k8s-wk-2]=vm [k8s-wk-3]=vm
)

# 静的IPアドレス
declare -A NODE_IP=(
  [k8s-cp-1]=10.10.0.11 [k8s-cp-2]=10.10.0.12 [k8s-cp-3]=10.10.0.13
  [k8s-wk-1]=10.10.0.21 [k8s-wk-2]=10.10.0.22 [k8s-wk-3]=10.10.0.23
)

# メモリ制限
declare -A NODE_MEM=(
  [k8s-cp-1]=4GiB [k8s-cp-2]=4GiB [k8s-cp-3]=4GiB
  [k8s-wk-1]=16GiB [k8s-wk-2]=16GiB [k8s-wk-3]=16GiB
)

# ディスクサイズ
declare -A NODE_DISK=(
  [k8s-cp-1]=50GiB [k8s-cp-2]=50GiB [k8s-cp-3]=50GiB
  [k8s-wk-1]=50GiB [k8s-wk-2]=50GiB [k8s-wk-3]=50GiB
)

# vCPU数（全ノード共通）
VCPU=2

# Ceph OSD ディスクサイズ（ワーカーVM 1台あたり）
OSD_DISK_SIZE=200G

# 起動順序（コントロールプレーン → ワーカー）
NODE_ORDER=(k8s-cp-1 k8s-cp-2 k8s-cp-3 k8s-wk-1 k8s-wk-2 k8s-wk-3)

# LXD設定
IMAGE="ubuntu:24.04"
PROFILE="k8s"
VM_PROFILE="k8s-vm"

# ネットワーク設定
BRIDGE="lxdbr0"
BRIDGE_SUBNET="10.10.0.0/24"
BRIDGE_GW="10.10.0.1"
