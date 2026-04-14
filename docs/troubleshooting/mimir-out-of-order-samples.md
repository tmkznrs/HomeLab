# Mimir: out-of-order samples エラー

## 発生日時

2026-04-14

## 症状

Alloy (`alloy-nwrwm`) のログに以下のエラーが出力されていた。

```
level=error msg="non-recoverable error" component_id=prometheus.remote_write.mimir
err="server returned HTTP status 400 Bad Request: send data to ingesters:
failed pushing to ingester mimir-ingester-1: user=anonymous:
the sample has been rejected because another sample with a more recent timestamp
has already been ingested and out-of-order samples are not allowed
(err-mimir-sample-out-of-order).
The affected sample has timestamp 2026-04-14T13:31:08.872Z and is from series
kubelet_image_pull_duration_seconds_bucket{...} (sampled 1/10)"
```

## 原因

Mimir はデフォルトで時系列の逆順サンプル（out-of-order samples）を拒否する。
Alloy Pod の再起動や WAL リプレイにより、すでに取り込んだタイムスタンプより古いサンプルが
再送されたことで発生。

## 対処

### 1. Mimir ingester メモリ増量

`k8s/observability/07-mimir/values.yaml`

```yaml
ingester:
  resources:
    requests:
      memory: 512Mi
    limits:
      memory: 1Gi  # 512Mi → 1Gi に変更
```

### 2. out-of-order time window を許容

`k8s/observability/07-mimir/values.yaml` の `mimir.structuredConfig.limits` に追記：

```yaml
limits:
  compactor_blocks_retention_period: 168h
  out_of_order_time_window: 10m  # 追加
```

10分以内の古いサンプルを受け入れることで、Alloy 再起動時の再送エラーを解消。

## 反映コマンド

```bash
helm upgrade mimir grafana/mimir-distributed \
  -n observability \
  -f k8s/observability/07-mimir/values.yaml
```
