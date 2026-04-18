# Headlamp OIDC セッションが切れる問題

## 症状

Headlamp に Authentik OIDC でサインインしても、Authentik の `access_token_validity` に設定した時間が経過するとセッションが切れてサインイン画面に戻る。

## 調査結果

- Authentik はリフレッシュトークンを正常に発行している（`offline_access` スコープ、有効期限 30 日）
- Authentik のトークンエンドポイントへのリフレッシュリクエストが、トークン失効後 10 分以上経ってから届く（遅すぎる）
- Headlamp はトークン失効前にプロアクティブなリフレッシュを行わない
- 結果として `access_token_validity` の値がそのままセッション継続時間となる

## 現在の回避策

Authentik admin UI → Applications → Providers → headlamp → Edit → **Access Token validity** を希望するセッション継続時間に設定する。

現在の設定: `minutes=30`（30 分でセッション切れ）

## 根本的な解決策（未実施）

Headlamp の前段に **oauth2-proxy** を導入する。oauth2-proxy がトークン失効前にプロアクティブなリフレッシュを行い、長期セッションを維持する。

## 関連情報

- Headlamp: v0.41.0
- Authentik: `access_token_validity = minutes=5`（デフォルト）→ `minutes=30`（現在）
- Headlamp GitHub issue: [#3143](https://github.com/kubernetes-sigs/headlamp/issues/3143)（OIDC リフレッシュ関連）
