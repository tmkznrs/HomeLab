クラスターの健全性を確認する。

```bash
kubectl get nodes -o wide
kubectl top nodes
kubectl get pods -A | grep -v -E "Running|Completed"
kubectl get events -A --field-selector type=Warning --sort-by='.lastTimestamp' | tail -20
```
