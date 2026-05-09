#!/usr/bin/env bash
# 07-init-control-plane.sh — k8s-cp-1 にて kubeadm init + kube-vip 配置
#
# 解決した問題:
#   kube-vip v0.8+ は cp_enable=true のとき Kubernetes lease で leader election を行う。
#   kubeadm init 完了前は RBAC が存在しないため VIP を取得できず、
#   kubeadm が VIP 経由で API 呼び出しを行う upload-config 以降でタイムアウトする。
#
# 解決策:
#   1. kubeadm init 前に VIP を eth0 に静的付与 (ip addr add)
#   2. kubeadm init を実行（VIP が到達可能なので成功する）
#   3. init 完了後に kube-vip static pod manifest を配置
#   4. kube-vip が lease を取得して VIP を引き継ぐ
#   5. 静的 IP を削除
#
# 前提: 05-install-containerd.sh 実行済み

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/node-config.sh"

FIRST_CP="k8s-cp-1"
VIP="10.10.0.10"
KUBE_VIP_VERSION="v1.1.2"
K8S_VERSION="v1.35.3"
POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"
JOIN_INFO="$HOME/.kube/join-info.env"

echo "[INFO] k8s-cp-1 のコントロールプレーン初期化を開始します"
echo "  VIP: $VIP"
echo "  Kubernetes: $K8S_VERSION"
echo "  Pod CIDR: $POD_CIDR"
echo "  Service CIDR: $SERVICE_CIDR"
echo ""

# --- Step 1: VIP を eth0 に静的付与 ---
echo "[1/6] VIP ($VIP/32) を eth0 に静的付与..."
lxc exec "$FIRST_CP" -- bash -c "
  if ip addr show eth0 | grep -q '${VIP}/32'; then
    echo '  [SKIP] VIP は既に eth0 に付与されています'
  else
    ip addr add ${VIP}/32 dev eth0
    echo '  [OK] VIP を eth0 に付与しました'
  fi
  ip addr show eth0 | grep -E 'inet '
"
echo ""

# --- Step 2: kube-vip イメージを事前 pull ---
echo "[2/6] kube-vip イメージを pull..."
lxc exec "$FIRST_CP" -- ctr image pull "ghcr.io/kube-vip/kube-vip:${KUBE_VIP_VERSION}"
echo "  [OK] イメージ pull 完了"
echo ""

# --- Step 3: kubeadm init ---
echo "[3/6] kubeadm init を実行中（数分かかります）..."

# kubeadm コンフィグを生成してノードに転送
cat <<EOF | lxc exec "$FIRST_CP" -- tee /tmp/kubeadm-config.yaml > /dev/null
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "${K8S_VERSION}"
controlPlaneEndpoint: "${VIP}:6443"
networking:
  podSubnet: "${POD_CIDR}"
  serviceSubnet: "${SERVICE_CIDR}"
apiServer:
  extraArgs:
    - name: max-requests-inflight
      value: "150"
    - name: max-mutating-requests-inflight
      value: "50"
etcd:
  local:
    extraArgs:
      - name: heartbeat-interval
        value: "500"
      - name: election-timeout
        value: "2500"
EOF

lxc exec "$FIRST_CP" -- kubeadm init \
  --config /tmp/kubeadm-config.yaml \
  --upload-certs \
  --skip-phases=addon/kube-proxy \
  --ignore-preflight-errors=SystemVerification \
  2>&1 | tee /tmp/kubeadm-init.log

if ! grep -q "Your Kubernetes control-plane has initialized successfully" /tmp/kubeadm-init.log; then
  echo "[ERROR] kubeadm init が失敗しました。/tmp/kubeadm-init.log を確認してください"
  exit 1
fi

echo "[3/6] kubeadm init 完了"
echo ""

# --- Step 4: kubeconfig 設定 ---
echo "[4/6] kubeconfig を設定..."

lxc exec "$FIRST_CP" -- bash -s << 'EOF'
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chown root:root /root/.kube/config
echo "  [OK] /root/.kube/config を設定しました"
EOF

# ホスト側にも取得
mkdir -p ~/.kube
lxc file pull "${FIRST_CP}/etc/kubernetes/admin.conf" ~/.kube/config
echo "  [OK] ホスト側 ~/.kube/config を設定しました"
echo ""

# --- Step 5: kube-vip static pod manifest を配置 ---
echo "[5/6] kube-vip manifest を配置（RBAC 取得後）..."

lxc exec "$FIRST_CP" -- bash -s << EOF
set -euo pipefail

mkdir -p /etc/kubernetes/manifests

echo "  → kube-vip manifest を生成..."
ctr run --rm --net-host \
  ghcr.io/kube-vip/kube-vip:${KUBE_VIP_VERSION} \
  vip \
  /kube-vip manifest pod \
    --interface eth0 \
    --address ${VIP} \
    --controlplane \
    --arp \
    --leaseDuration 5 \
    --leaseRenewDuration 3 \
    --leaseRetry 1 \
  > /etc/kubernetes/manifests/kube-vip.yaml

echo "  → manifest 確認:"
grep -E "image:|address|interface" /etc/kubernetes/manifests/kube-vip.yaml | head -5
EOF

echo "  [OK] kube-vip manifest を配置しました"
echo ""

# kube-vip が起動して lease を取得するまで待機
echo "  → kube-vip が lease を取得するまで待機（最大60秒）..."
TIMEOUT=60
ELAPSED=0
while [[ $ELAPSED -lt $TIMEOUT ]]; do
  LEASE=$(lxc exec "$FIRST_CP" -- kubectl -n kube-system get lease plndr-cp-lock \
    -o jsonpath='{.spec.holderIdentity}' 2>/dev/null || true)
  if [[ -n "$LEASE" ]]; then
    echo "  [OK] kube-vip が lease を取得しました: $LEASE"
    break
  fi
  sleep 3
  ELAPSED=$((ELAPSED + 3))
done

if [[ $ELAPSED -ge $TIMEOUT ]]; then
  echo "  [WARN] kube-vip の lease 取得を確認できませんでした（処理続行）"
fi

# VIP の疎通確認
echo "  → VIP ($VIP) の疎通確認..."
if ping -c 3 -W 2 "$VIP" &>/dev/null; then
  echo "  [OK] VIP に到達できます"
else
  echo "  [WARN] VIP への ping が失敗しました（iptables 経由のみの可能性）"
fi

# --- Step 6: 静的 IP を削除 ---
echo ""
echo "[6/6] 静的 VIP を eth0 から削除（kube-vip に引き継ぎ）..."
lxc exec "$FIRST_CP" -- bash -c "
  if ip addr show eth0 | grep -q '${VIP}/32'; then
    ip addr del ${VIP}/32 dev eth0
    echo '  [OK] 静的 VIP を削除しました（kube-vip が管理します）'
  else
    echo '  [INFO] 静的 VIP はすでに存在しません（kube-vip が引き継ぎ済み）'
  fi
  ip addr show eth0 | grep -E 'inet '
"
echo ""

# --- join 情報を保存 ---
echo "[INFO] join 情報を抽出・保存..."

JOIN_TOKEN=$(grep -oP '(?<=--token )\S+' /tmp/kubeadm-init.log | head -1)
JOIN_HASH=$(grep -oP '(?<=--discovery-token-ca-cert-hash sha256:)\S+' /tmp/kubeadm-init.log | head -1)
JOIN_CERT_KEY=$(grep "certificate-key" /tmp/kubeadm-init.log | awk '{print $NF}' | head -1)

if [[ -z "$JOIN_TOKEN" || -z "$JOIN_HASH" || -z "$JOIN_CERT_KEY" ]]; then
  echo "[ERROR] join 情報の抽出に失敗しました。/tmp/kubeadm-init.log を確認してください"
  tail -30 /tmp/kubeadm-init.log
  exit 1
fi

cat > "$JOIN_INFO" << ENVEOF
JOIN_ENDPOINT="${VIP}:6443"
JOIN_TOKEN="${JOIN_TOKEN}"
JOIN_HASH="${JOIN_HASH}"
JOIN_CERT_KEY="${JOIN_CERT_KEY}"
ENVEOF

echo "  [OK] join 情報を $JOIN_INFO に保存しました"
echo "  TOKEN:    ${JOIN_TOKEN}"
echo "  HASH:     ${JOIN_HASH:0:16}..."
echo "  CERT_KEY: ${JOIN_CERT_KEY:0:16}..."
echo ""

# --- 動作確認 ---
echo "[INFO] 初期化確認..."
sleep 5

kubectl get nodes 2>/dev/null || lxc exec "$FIRST_CP" -- kubectl get nodes

echo ""
echo "[OK] k8s-cp-1 の初期化が完了しました"
echo ""
echo "⚠️  証明書キーの有効期限は 2時間です。"
echo "   すぐに 08-join-control-planes.sh を実行してください。"
