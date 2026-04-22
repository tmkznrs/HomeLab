#!/usr/bin/env bash
# 11-install-host-alloy.sh — LXD ホストへ Alloy エージェントをインストール
# ホスト OS のメトリクスとジャーナルログを Mimir/Loki へ送信する
# sudo で実行すること

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SRC="${SCRIPT_DIR}/../alloy/config.linux.alloy"
CONFIG_DST="/etc/alloy/config.alloy"
CA_DST="/usr/local/share/ca-certificates/homelab-ca.crt"
HOSTS_ENTRY="10.10.0.100  homelab.local"

# sudo 実行時は呼び出し元ユーザーの kubeconfig を使用
if [[ -z "${KUBECONFIG:-}" ]]; then
  _SUDO_HOME=$(getent passwd "${SUDO_USER:-$(logname 2>/dev/null || echo administrator)}" | cut -d: -f6)
  export KUBECONFIG="${_SUDO_HOME}/.kube/config"
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "[ERROR] このスクリプトは root 権限が必要です。sudo で実行してください:"
  echo "  sudo bash $0"
  exit 1
fi

# ── 1. Grafana APT リポジトリ追加 ─────────────────────────────────────────────
echo "[INFO] Grafana APT リポジトリを設定..."

if ! dpkg -l alloy &>/dev/null; then
  apt-get install -y gpg curl

  KEYRING="/etc/apt/keyrings/grafana.gpg"
  if [[ ! -f "$KEYRING" ]]; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://apt.grafana.com/gpg.key \
      | gpg --dearmor -o "$KEYRING"
    echo "[OK] GPG キーをインポート: $KEYRING"
  else
    echo "[SKIP] GPG キーは既に存在: $KEYRING"
  fi

  SOURCES_FILE="/etc/apt/sources.list.d/grafana.list"
  if [[ ! -f "$SOURCES_FILE" ]]; then
    echo "deb [signed-by=${KEYRING}] https://apt.grafana.com stable main" \
      > "$SOURCES_FILE"
    echo "[OK] APT ソースを追加: $SOURCES_FILE"
  else
    echo "[SKIP] APT ソースは既に存在: $SOURCES_FILE"
  fi

  apt-get update -q
  apt-get install -y alloy
  echo "[OK] Alloy をインストール"
else
  echo "[SKIP] Alloy は既にインストール済み"
fi

# ── 2. homelab CA 証明書をシステム CA ストアに登録 ────────────────────────────
echo "[INFO] homelab CA 証明書を登録..."

kubectl get secret homelab-ca-secret -n infra \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > "$CA_DST"
update-ca-certificates
echo "[OK] CA 証明書を登録: $CA_DST"

# ── 3. /etc/hosts に homelab.local を追加 ─────────────────────────────────────
if grep -qF "homelab.local" /etc/hosts; then
  echo "[SKIP] /etc/hosts に homelab.local は既に存在"
else
  echo "$HOSTS_ENTRY" >> /etc/hosts
  echo "[OK] /etc/hosts に追加: $HOSTS_ENTRY"
fi

# ── 4. Alloy 設定ファイルを配置 ───────────────────────────────────────────────
echo "[INFO] Alloy 設定ファイルを配置..."
cp "$CONFIG_SRC" "$CONFIG_DST"
echo "[OK] 設定ファイルをコピー: $CONFIG_DST"

# ── 5. alloy ユーザーに journal 読み取り権限を付与 ────────────────────────────
if id -nG alloy | grep -qw systemd-journal; then
  echo "[SKIP] alloy ユーザーは既に systemd-journal グループに所属"
else
  usermod -aG systemd-journal alloy
  echo "[OK] alloy ユーザーを systemd-journal グループに追加"
fi

# ── 6. Alloy サービスを有効化・起動 ───────────────────────────────────────────
echo "[INFO] Alloy サービスを起動..."
systemctl enable alloy
systemctl restart alloy
echo "[OK] Alloy サービス起動完了"

echo ""
echo "=== セットアップ完了 ==="
echo "  Alloy UI:        http://localhost:12345"
echo "  サービス状態:    systemctl status alloy"
echo "  ログ確認:        journalctl -u alloy -f"
echo ""
echo "  Grafana → Explore → Mimir: {job=\"lxd-host\"}"
echo "  Grafana → Explore → Loki:  {job=\"lxd-host-journal\"}"
