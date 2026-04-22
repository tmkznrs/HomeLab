# Alloy External Agents

クラスター外のマシンからメトリクス・ログを収集して homelab の Mimir / Loki へ送信する Alloy 設定。

| ファイル | 対象 | 収集内容 |
|----------|------|----------|
| `config.linux.alloy` | Linux (Ubuntu 等) | システムメトリクス、ジャーナルログ |
| `config.windows.alloy` | Windows | システムメトリクス、イベントログ |

## 共通設定

### 送信先エンドポイント

| 送信先 | URL |
|--------|-----|
| Mimir  | `https://homelab.local/mimir/api/v1/push` |
| Loki   | `https://homelab.local/loki/api/v1/push` |

### homelab CA 証明書の取得

どのプラットフォームでも TLS 接続に homelab CA 証明書が必要。cert-manager の CA ローテーション時（namespace 移行や手動再作成）には再取得・再インストールが必要。

```bash
kubectl get secret homelab-ca-secret -n infra \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > homelab-ca.crt
```

### hosts ファイルへの追記

`homelab.local` を MetalLB の IP に解決させる。

```
10.10.0.100  homelab.local
```

---

## Linux (`config.linux.alloy`)

systemd journal と node メトリクスを収集する汎用 Linux 設定。LXD ホストや任意の Ubuntu マシンで使用可能。

### セットアップ（推奨: スクリプト実行）

```bash
sudo bash scripts/11-install-host-alloy.sh
```

スクリプトは冪等実行可能。以下を自動で行う:

1. Grafana APT リポジトリを追加して `alloy` をインストール
2. homelab CA 証明書をシステム CA ストアに登録 (`update-ca-certificates`)
3. `/etc/hosts` に `10.10.0.100 homelab.local` を追加（未追加の場合のみ）
4. `config.linux.alloy` を `/etc/alloy/config.alloy` へ配置
5. `alloy` ユーザーを `systemd-journal` グループに追加（journal 読み取り権限）
6. `alloy` サービスを有効化・起動

### 動作確認

- Alloy UI: `http://localhost:12345`
- Grafana → Explore → Mimir: `{job="linux-host"}`
- Grafana → Explore → Loki: `{job="linux-host-journal"}`

---

## Windows (`config.windows.alloy`)

### CA 証明書のインストール

Alloy は LocalSystem アカウントで動作するため、**`LocalMachine\Root`** にインストールする必要がある。`CurrentUser\Root` では認識されない。

管理者 PowerShell で実行:

```powershell
# 古い CA を削除してから新しい CA をインストール
Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like "*homelab*" } | Remove-Item
Import-Certificate -FilePath homelab-ca.crt -CertStoreLocation Cert:\LocalMachine\Root
```

確認:

```powershell
Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like "*homelab*" }
```

### hosts ファイル

```powershell
Add-Content C:\Windows\System32\drivers\etc\hosts "10.10.0.100  homelab.local"
```

### インストールと起動

1. [Grafana Alloy](https://grafana.com/docs/alloy/latest/get-started/install/windows/) の MSI をインストール
2. `config.windows.alloy` を配置:
   ```
   C:\Program Files\GrafanaLabs\Alloy\config.alloy
   ```
3. サービス再起動:
   ```powershell
   Restart-Service "Alloy"
   ```

### 動作確認

- Alloy UI: `http://localhost:12345`
- Grafana → Explore → Mimir: `{job="windows"}`
- Grafana → Explore → Loki: `{job="windows-events"}`

---

## 死活監視（クラスター側）

外部マシンの死活監視は Alloy 自体が停止すると途切れるため、クラスター側の単一レプリカ Alloy Deployment（`k8s/observability/10-alloy-probe/`）から ICMP プローブで監視する。

- Grafana → Explore → Mimir: `probe_success{job="external-probe"}`
- `probe_duration_seconds{job="external-probe"}` で RTT を確認
