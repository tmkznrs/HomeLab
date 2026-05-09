# クラスター再構築手順 (ホスト OS 維持)

## 背景・目的

LXD のストレージ設定が原因で以下の問題が発生していた:

- **ノードルートディスクが `dir` pool (ファイル置き)**  
  ワーカー VM の仮想ディスクが QCOW2 ファイルとしてホスト ext4 上に存在する。  
  VM 内の `fsync()` → QEMU → ホスト ext4 `fsync()` と二重になり、etcd の `slow fdatasync` を引き起こす。

- **Ceph OSD が LVM thin pool 上に存在**  
  LVM thin pool は書き込み時に都度ブロックを割り当てるため、Ceph BlueStore の slow ops を引き起こす。

対策として、パーティションを再構成してストレージプールを作り直す。  
**ホスト OS (nvme0n1p3) は変更しない。**

## 新しいパーティション構成

```
nvme0n1 (953.9 GiB)
├─ p1:   1 GiB  vfat         /boot/efi     (変更なし)
├─ p2:   2 GiB  ext4         /boot         (変更なし)
├─ p3: 200 GiB  ext4         /             (変更なし)
├─ p4: 150 GiB  LVM thin     fast pool  ←  旧 osd(600G) を削除して再作成
└─ p5: ~601 GiB LVM thick    osd pool   ←  残り全て (200 GiB × 3 = 600 GiB)
```

| pool | ドライバー | thin | 用途 |
|------|-----------|------|------|
| `fast` | lvm | あり | CP コンテナ・ワーカー VM のルートディスク |
| `osd`  | lvm | **なし** | Ceph OSD ブロックデバイス (BlueStore 向け固定割当) |

## Phase 1: LXD クラスターを停止・削除

```bash
# Kubernetes ノードを停止
lxc stop k8s-cp-1 k8s-cp-2 k8s-cp-3 k8s-wk-1 k8s-wk-2 k8s-wk-3

# LXD インスタンスを削除 (ルートディスクも削除される)
lxc delete k8s-cp-1 k8s-cp-2 k8s-cp-3 k8s-wk-1 k8s-wk-2 k8s-wk-3

# Ceph OSD ブロックボリュームを削除
lxc storage volume delete osd osd-k8s-wk-1
lxc storage volume delete osd osd-k8s-wk-2
lxc storage volume delete osd osd-k8s-wk-3

# LXD ストレージプールを削除
lxc storage delete osd
lxc storage delete default
```

## Phase 2: パーティション再構成

**p4 (旧 osd 600G) を削除し、p4=150G(fast) + p5=残り(osd) に再作成する。**

```bash
# 旧 p4 の LVM シグネチャを消去
sudo pvremove /dev/nvme0n1p4 || true
sudo wipefs -a /dev/nvme0n1p4

# 旧 p4 を削除
sudo sgdisk -d 4 /dev/nvme0n1

# p4: 150 GiB (fast pool 用)
sudo sgdisk -n "4:0:+150GiB" -t "4:8e00" /dev/nvme0n1

# p5: 残り全て (~601 GiB, osd pool 用)
sudo sgdisk -n "5:0:0" -t "5:8e00" /dev/nvme0n1

# カーネルのパーティションテーブルを更新
sudo partx -u /dev/nvme0n1
sudo udevadm settle

# 確認
lsblk /dev/nvme0n1
# nvme0n1p4 → 150G
# nvme0n1p5 → ~601G
```

## Phase 3: LXD 再初期化・ストレージプール作成

```bash
cd ~/HomeLab

# LXD ネットワーク初期化 + fast pool (p4, thin) + osd pool (p5, thick) 作成
bash scripts/00-lxd-init.sh
```

実行後の確認:

```bash
lxc storage list
# NAME   DRIVER  ...
# fast   lvm     /dev/nvme0n1p4   ← thin (デフォルト)
# osd    lvm     /dev/nvme0n1p5   ← thick

# osd pool に thin pool が存在しないことを確認
lxc storage show osd | grep thinpool
# (何も表示されなければ OK)
```

## Phase 4: クラスター再構築

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
bash 12-install-rook-ceph.sh  # Rook-Ceph (OSD: 200 GiB × 3, thick)
```

### 適用される etcd タイムアウト設定

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

## Phase 5: Kubernetes マニフェスト適用

```bash
kubectl apply -f k8s/namespaces/
kubectl apply -f k8s/infra/
kubectl apply -f k8s/storage/
kubectl apply -f k8s/database/
kubectl apply -f k8s/observability/
kubectl apply -f k8s/operations/
```

## 事後検証

```bash
# 1. ノードのルートディスクが fast pool を使っているか確認
lxc config device show k8s-cp-1 | grep pool   # pool: fast
lxc config device show k8s-wk-1 | grep pool   # pool: fast

# 2. Ceph 健全性
kubectl exec -n storage rook-ceph-tools-<pod> -- ceph status
# health: HEALTH_OK が目標

# 3. etcd slow fdatasync が出ていないか (30分観察)
kubectl logs -n kube-system etcd-k8s-cp-2 --since=30m | grep "slow fdatasync"

# 4. apiserver probe 失敗が出ていないか
kubectl get events -n kube-system \
  --field-selector type=Warning,reason=Unhealthy | grep apiserver
```
