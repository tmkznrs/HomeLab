#!/usr/bin/env bash
# 10-install-cni.sh — Cilium (kube-proxy 置き換えあり) のインストール
# Helm を使用してインストールする
# 前提: 09-join-workers.sh 実行済み、~/.kube/config が設定済み
#       kubeadm init 時に --skip-phases=addon/kube-proxy を指定済み

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/node-config.sh"

CILIUM_VERSION="1.17.3"
CILIUM_NAMESPACE="kube-system"
VALUES_FILE="$SCRIPT_DIR/../k8s/kube-system/cilium/values.yaml"

echo "[INFO] Cilium ${CILIUM_VERSION} (kube-proxy 置き換えあり) をインストールします"
echo ""

# --- Step 1: Helm repo 追加 ---
echo "[1/4] Cilium Helm リポジトリを追加..."
helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
helm repo update cilium
echo "  [OK] リポジトリを更新しました"
echo ""

# --- Step 2: Cilium をインストール ---
echo "[2/4] Cilium をインストール..."
helm upgrade --install cilium cilium/cilium \
  --version "$CILIUM_VERSION" \
  --namespace "$CILIUM_NAMESPACE" \
  --values "$VALUES_FILE" \
  --wait --timeout 5m
echo "  [OK] Cilium をインストールしました"
echo ""

# --- Step 3: Cilium が Ready になるまで待機 ---
echo "[3/4] Cilium が Ready になるまで待機（最大5分）..."
kubectl rollout status daemonset/cilium -n "$CILIUM_NAMESPACE" --timeout=300s
kubectl rollout status deployment/cilium-operator -n "$CILIUM_NAMESPACE" --timeout=300s
echo ""

# --- Step 4: 全ノード Ready 待機 ---
echo "[4/4] 全ノードが Ready になるまで待機（最大5分）..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

echo ""
echo "[INFO] クラスター状態:"
kubectl get nodes -o wide

echo ""
echo "[INFO] システム Pod 状態:"
kubectl get pods -n kube-system -o wide

echo ""
echo "[INFO] Cilium ステータス:"
helm status cilium -n "$CILIUM_NAMESPACE"

echo ""
echo "[OK] CNI のインストールが完了しました"
echo ""
echo "=== クラスター構築完了 ==="
echo ""
echo "検証コマンド:"
echo "  kubectl get nodes -o wide"
echo "  kubectl get pods -n kube-system"
echo "  helm status cilium -n kube-system"
echo "  kubectl -n kube-system exec etcd-k8s-cp-1 -- etcdctl member list \\"
echo "    --cacert=/etc/kubernetes/pki/etcd/ca.crt \\"
echo "    --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \\"
echo "    --key=/etc/kubernetes/pki/etcd/healthcheck-client.key"
