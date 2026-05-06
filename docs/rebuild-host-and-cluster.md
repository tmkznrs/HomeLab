# ホスト OS 再インストール + クラスター再構築手順

## 背景・目的

LXD のデフォルトストレージプール (`dir` ドライバー) が原因で以下の問題が発生していた:

- etcd `slow fdatasync` → kube-apiserver Readiness probe 断続的失敗
- Ceph BlueStore slow ops (LVM thin pool の割当遅延)
- ワーカー VM のルートディスクがファイルバック (QCOW2) → fsync 二重化

根本対策として、パーティション構成を見直してホスト OS ごと再インストールする。

## 新しいパーティション構成

```
nvme0n1 (953.9 GiB)
├─ p1:   1 GiB  vfat         /boot/efi
├─ p2:   2 GiB  ext4         /boot
├─ p3:  60 GiB  ext4         /              ← ホスト OS 専用 (旧: 200 GiB、ノードと混在)
├─ p4: 150 GiB  LVM thin     fast pool      ← ノードルートディスク (旧: dir pool)
└─ p5: ~741 GiB LVM thick    osd pool       ← Ceph OSD 固定割当 (旧: LVM thin 600 GiB)
```

| pool | ドライバー | thin | 用途 |
|------|-----------|------|------|
| `fast` | lvm | あり | CP コンテナ・ワーカー VM のルートディスク |
| `osd`  | lvm | **なし** | Ceph OSD ブロックデバイス (BlueStore 向け固定割当) |

## Phase 1: live USB でパーティション再構成 + Ubuntu 再インストール

### 1-1. live USB を起動

Ubuntu Server 24.04 の ISO で起動し、インストーラーを開始する。

### 1-2. カスタムパーティション設定

インストーラーの「ストレージ構成」で手動設定を選択し、以下の通りに構成する:

| パーティション | サイズ | フォーマット | マウントポイント |
|--------------|--------|------------|----------------|
| nvme0n1p1 | 1 GiB | EFI System Partition | /boot/efi |
| nvme0n1p2 | 2 GiB | ext4 | /boot |
| nvme0n1p3 | 60 GiB | ext4 | / |
| nvme0n1p4 | 150 GiB | **フォーマットしない** (raw) | — |
| nvme0n1p5 | 残り全て | **フォーマットしない** (raw) | — |

> p4・p5 はインストーラーでフォーマットせず raw のまま残す。LXD が LVM として管理する。

### 1-3. Ubuntu Server インストール

- ユーザー名: `k8sadmin`
- OpenSSH server: インストール時に有効化
- 追加パッケージ: 不要 (最小構成)

### 1-4. 再起動後の初期設定

```bash
# LXD のインストール (snap)
sudo snap install lxd --channel=5.21/stable

# git・その他ツール
sudo apt-get update && sudo apt-get install -y git gdisk

# HomeLab リポジトリをクローン
git clone <repo-url> ~/HomeLab
cd ~/HomeLab
```

## Phase 2: LXD 初期化・ストレージプール作成

```bash
bash scripts/00-lxd-init.sh
```

このスクリプトが以下を実行する:

1. `lxd init --preseed < lxd/init.yaml` — ネットワーク (lxdbr0) の初期化
2. nvme0n1p4 に `fast` LVM thin pool を作成 (ノードルートディスク用)
3. nvme0n1p5 に `osd` LVM thick pool を作成 (`lvm.use_thinpool=false`)

実行後の確認:

```bash
lxc storage list
# NAME   DRIVER  SOURCE         ...
# fast   lvm     /dev/nvme0n1p4
# osd    lvm     /dev/nvme0n1p5

lxc storage show osd | grep thinpool
# (thinpool の記載がないことを確認)
```

## Phase 3: クラスター再構築

スクリプトを順番に実行する。

```bash
cd ~/HomeLab/scripts

bash 01-host-prereqs.sh       # カーネルモジュール・sysctl
bash 02-create-profile.sh     # k8s / k8s-vm プロファイル作成 (pool: fast)
bash 03-launch-nodes.sh       # 6台起動 (fast pool でルートディスク作成)
bash 04-configure-nodes.sh    # スワップ無効化・sysctl・パッケージ
bash 05-install-containerd.sh # containerd (SystemdCgroup=true)
bash 06-install-k8s-tools.sh  # kubeadm / kubelet / kubectl v1.35.x
bash 07-init-control-plane.sh # kubeadm init + etcd タイムアウト設定
bash 08-join-control-planes.sh # ※ 07 完了後 2時間以内に実行
bash 09-join-workers.sh
bash 10-install-cni.sh        # Cilium v1.17.3
bash 12-install-rook-ceph.sh  # Rook-Ceph (OSD: 240 GiB × 3 = 720 GiB, thick)
```

### etcd タイムアウト設定の確認

`07-init-control-plane.sh` により kubeadm が以下を設定する:

```yaml
etcd:
  local:
    extraArgs:
      - name: heartbeat-interval
        value: "500"   # デフォルト 100ms → 500ms
      - name: election-timeout
        value: "2500"  # デフォルト 1000ms → 2500ms
```

確認コマンド:

```bash
kubectl exec -n kube-system etcd-k8s-cp-1 -- \
  grep -E "heartbeat|election" /etc/kubernetes/manifests/etcd.yaml
```

## Phase 4: Kubernetes マニフェスト適用

クラスター再構築後、`k8s/` 配下のマニフェストを適用して各スタックを復元する。

```bash
# 名前空間
kubectl apply -f k8s/namespaces/

# インフラ (cert-manager, ingress-nginx, metallb, authentik)
kubectl apply -f k8s/infra/

# ストレージ (local-path, minio)
kubectl apply -f k8s/storage/

# データベース (postgres, pgadmin)
kubectl apply -f k8s/database/

# オブザーバビリティ (grafana, loki, mimir, tempo, alloy)
kubectl apply -f k8s/observability/

# オペレーション (headlamp, argocd)
kubectl apply -f k8s/operations/
```

## 事後検証

```bash
# 1. ストレージプールの確認
lxc storage show fast
lxc storage show osd | grep -E "thinpool|source"

# 2. ノードのルートディスクが fast pool を使っているか
lxc config device show k8s-cp-1 | grep pool   # pool: fast
lxc config device show k8s-wk-1 | grep pool   # pool: fast

# 3. Ceph 健全性
kubectl exec -n storage rook-ceph-tools-<pod> -- ceph status
# health: HEALTH_OK が目標

# 4. etcd slow fdatasync が出ていないか (30分観察)
kubectl logs -n kube-system etcd-k8s-cp-2 --since=30m | grep "slow fdatasync"

# 5. apiserver probe 失敗が出ていないか
kubectl get events -n kube-system \
  --field-selector type=Warning,reason=Unhealthy | grep apiserver
```
