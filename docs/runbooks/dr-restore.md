# CBCI Lab — DR Restore Runbook

## Backup architecture

| Layer | Tool | Scope | Schedule | Retention |
|---|---|---|---|---|
| Kubernetes resources | Velero v1.18.0 | `cloudbees` namespace | Daily 02:00 UTC | 7 days |
| EFS data | AWS Backup | EFS `fs-0b4f7798361a31568` | Daily 03:00 UTC | 7 days |

Backups stored in S3 `cbci-lab-velero-835090871306` (versioned, private).

## Drill results (2026-04-21)

| Event | Time (CDT) | Elapsed |
|---|---|---|
| Drill start / namespace delete | 05:37:47 | 0s |
| Namespace fully terminated | 05:47:55 | ~10m |
| Velero restore initiated | 05:48:06 | — |
| Velero restore completed | 05:48:18 | 12s |
| PV claimRefs cleared (manual) | 05:48:30 | — |
| All PVCs Bound | 05:48:45 | — |
| OC pod Ready | 05:50:35 | **RTO: ~2m 29s from restore** |

**RTO (restore-to-serving): ~2.5 minutes**

The 10-minute namespace termination was unusual — caused by a stale `metrics.k8s.io/v1beta1` API discovery entry blocking the `kubernetes` finalizer. A forced finalizer removal was needed. In a normal cluster this step would be faster.

## Step-by-step restore procedure

### Prerequisites
- `velero` CLI installed and configured (`velero backup get` works)
- `kubectl` access to the cluster
- EFS data is safe (reclaimPolicy: Retain — PVs survive namespace deletion)

### 1. Identify the backup to restore from
```bash
velero backup get
# Pick the most recent "Completed" backup, e.g.:
BACKUP=pre-dr-drill-20260421-053700
```

### 2. Delete the damaged namespace (if not already gone)
```bash
kubectl delete namespace cloudbees
# If stuck in Terminating, force-remove the finalizer:
kubectl get namespace cloudbees -o json | \
  python3 -c "import json,sys; ns=json.load(sys.stdin); ns['spec']['finalizers']=[]; print(json.dumps(ns))" | \
  kubectl replace --raw /api/v1/namespaces/cloudbees/finalize -f -
```

### 3. Restore from Velero
```bash
velero restore create dr-restore-$(date +%Y%m%d) \
  --from-backup $BACKUP \
  --wait
```
Expected: `PartiallyFailed` is OK — the `TargetGroupBinding` errors are self-healing (AWS LBC recreates them from the restored Ingresses).

### 4. Clear PV claimRefs so EFS PVs rebind
```bash
# List Released EFS PVs
kubectl get pv | grep -E "Released.*efs-ap"

# Clear each one
for PV in <pv-name-1> <pv-name-2> ...; do
  kubectl patch pv "$PV" --type=merge -p '{"spec":{"claimRef": null}}'
done
```
Within ~10s the PVCs should move to Bound.

### 5. Wait for OC to be Ready
```bash
kubectl wait --for=condition=Ready pod/cjoc-0 -n cloudbees --timeout=5m
```

### 6. Verify
```bash
kubectl get pods -n cloudbees
kubectl get ingress -n cloudbees
curl -s -o /dev/null -w "%{http_code}" https://cjoc.myhomettbros.com/cjoc/login
# Expected: 200 or 302
```

## Known restore caveats

- **TargetGroupBinding errors**: Always occur on restore because old ALB target groups are gone. Self-healing — AWS LBC recreates them within 2-3 minutes.
- **PV claimRef must be cleared**: Velero restores PVCs with new UIDs but the static EFS PVs still have the old UID in their claimRef. Manual patch required.
- **EFS data is NOT restored by Velero**: Only Kubernetes resources are restored. EFS data persists because `reclaimPolicy: Retain`. In a true data-loss scenario, use AWS Backup to restore the EFS filesystem.
