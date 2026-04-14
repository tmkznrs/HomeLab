# CPU Throttling の検出

## 発生日時

2026-04-14

## 症状

Grafana ダッシュボードで CPU Throttling が記録されていた。

## 検出クエリ

```promql
count(sum(rate(container_cpu_cfs_throttled_seconds_total[15m])) by (pod) > 0)
```

## 調査結果

| Pod | Throttle 率 | CPU limit | 平均使用量 |
|---|---|---|---|
| mimir-distributor × 2 | 0.011〜0.014 | 200m | 16〜17m |
| postgres-cluster × 3 | 0.007〜0.009 | 200m | 6〜14m |
| mimir-ingester × 2 | 0.003 | 500m | 24〜48m |
| mimir-querier × 2 | 0.0001〜0.0002 | 300m | 微小 |
| mimir-query-frontend × 2 | 0.0001 | 200m | 微小 |

## 原因

Kubernetes の CPU limit は Linux CFS スケジューラーの 100ms ウィンドウで管理される。
平均使用量が limit を大きく下回っていても、100ms 内の瞬間バーストで throttle が発生する。

## 対応方針

クラスター全体の CPU 使用率がワーカーノードで 8〜11% 程度と余裕があり、
Throttle 値も 0.01 台と小さいため、実際のパフォーマンス影響はほぼない。
現時点では対応不要と判断。

対応が必要になった場合は CPU limit を削除して request のみにする（CFS throttle の根本対策）。
