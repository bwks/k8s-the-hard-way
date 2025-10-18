# k8s-the-hard-way
Buidling Kubernetes with Sherpa

## Restart DNS service
```
kubectl delete pod -n kube-system -l k8s-app=coredns
```
