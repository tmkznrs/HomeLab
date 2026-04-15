# kube-apiserver メモリ使用率が高い

## 発生日時

2026-04-15

## 症状

`kubectl top nodes` で k8s-cp-1 のメモリ使用率が 83%（3339Mi）と他のコントロールプレーンノード（70%, 73%）より高い状態だった。

```
k8s-cp-1   161m   8%   3339Mi   83%
k8s-cp-2   123m   6%   2828Mi   70%
k8s-cp-3   119m   5%   2954Mi   73%
```

## 原因

`kube-apiserver-k8s-cp-1` が 830Mi を消費しており、他の apiserver（645Mi, 617Mi）より約 200Mi 多かった。

k8s-cp-1 は kube-vip の VIP（10.10.0.10）を持つリーダーノードのため、クライアント接続が集中しやすい。

加えて、`--max-requests-inflight`（デフォルト 400）と `--max-mutating-requests-inflight`（デフォルト 200）がホームラボ規模に対して過大だった。

## 対処

`/etc/kubernetes/manifests/kube-apiserver.yaml` に以下を追加（全コントロールプレーンノード）:

```yaml
- --max-requests-inflight=150
- --max-mutating-requests-inflight=50
```

保存後、kubelet が kube-apiserver を自動再起動する。

## 結果

| | 変更前 | 変更後 |
|---|---|---|
| k8s-cp-1 ノード使用率 | 83% (3339Mi) | 77% (3103Mi) |
| kube-apiserver-k8s-cp-1 | 830Mi | 531Mi |

kube-apiserver 単体で約 300Mi 削減。
