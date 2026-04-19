# Alloy External Agents

クラスター外のマシンからメトリクス・ログを収集して homelab の Mimir / Loki へ送信する Alloy 設定。

| ファイル | 対象 | 収集内容 |
|----------|------|----------|
| `config.windows.alloy` | Windows | システムメトリクス、イベントログ |

## 共通設定

### 送信先エンドポイント

| 送信先 | URL |
|--------|-----|
| Mimir  | `https://homelab.local/mimir/api/v1/push` |
| Loki   | `https://homelab.local/loki/loki/api/v1/push` |

### homelab CA 証明書の取得

どのプラットフォームでも TLS 接続に homelab CA 証明書が必要。

```bash
kubectl get secret homelab-ca-secret -n infra \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > homelab-ca.crt
```

### hosts ファイルへの追記

`homelab.local` を MetalLB の IP に解決させる。

---

## Windows (`config.windows.alloy`)

### CA 証明書のインストール

Alloy は LocalSystem アカウントで動作するため、**`LocalMachine\Root`** にインストールする必要がある。`CurrentUser\Root` では認識されない。

管理者 PowerShell で実行:

```powershell
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
