# Phased Plan — CBCI on AWS

Status legend: `TODO` | `NEXT` | `IN PROGRESS` | `DONE` | `🛑 HUMAN`

---

## Phase 0 — Project bootstrap [DONE]
Project scaffold, .gitignore, README, CLAUDE.md, PLAN.md, folder structure, pre-commit hook, first commit.

---

## Phase 1 — Terraform remote state [DONE]
Claude Code does:
- Write `terraform/00-bootstrap/main.tf`: S3 bucket `cbci-lab-tfstate-<accountId>` (versioning, encryption, public access block) and DynamoDB table `cbci-lab-tf-locks`
- `terraform init` + `terraform plan` (show plan to owner)
- After owner says "apply", run `terraform apply`
- Commit: `phase 1: tf remote state backend`

Gate: owner verifies bucket and table exist in AWS Console.

---

## Phase 2 — VPC + networking [DONE]
Claude Code does:
- Write `terraform/10-network/`:
  - Use `terraform-aws-modules/vpc/aws` v5.x
  - VPC 10.0.0.0/16, 3 AZs, 3 public + 3 private subnets
  - Single NAT gateway (cost mode)
  - Subnet tags: `kubernetes.io/role/elb=1` (public), `kubernetes.io/role/internal-elb=1` (private), `karpenter.sh/discovery=cbci-lab` (private)
  - S3 backend pointing at Phase 1 bucket
- `plan` → show → apply on approval
- Commit: `phase 2: VPC with 3 AZs + single NAT`

Cost: NAT gateway ~$1/day.
Gate: owner sees VPC in Console.

---

## Phase 3 — EKS cluster + system node group [DONE]
Claude Code does:
- Write `terraform/20-eks/`:
  - Use `terraform-aws-modules/eks/aws` v20.x
  - EKS 1.31, private API endpoint, public access restricted to owner's home IP
  - Managed node group `system`: 2× t3.medium on-demand, in private subnets
  - OIDC provider for IRSA
  - Add-ons: vpc-cni, coredns, kube-proxy, aws-ebs-csi-driver, aws-efs-csi-driver, metrics-server
- Apply on approval
- Verify `kubectl get nodes` shows 2 Ready nodes
- Commit: `phase 3: EKS 1.31 + system node group + OIDC`

Cost: EKS control plane ~$2.40/day (24/7).
Gate: owner sees cluster healthy.

---

## Phase 4 — Karpenter + workload NodePools [NEXT]
Claude Code does:
- IAM roles for Karpenter node + controller (with IRSA)
- Install Karpenter via Helm, pinned version
- Two NodePools + one EC2NodeClass:
  - `controllers`: on-demand, t3.large/t3.xlarge
  - `agents`: spot+on-demand, taint `workload=agents:NoSchedule`
- Smoke test: throwaway pod scales up and back down
- Commit: `phase 4: Karpenter + NodePools`

Gate: owner confirms Karpenter scaled up and back down.

---

## Phase 5 — EFS filesystem + StorageClass
Claude Code does:
- Write `terraform/30-storage/`:
  - KMS key with rotation
  - EFS filesystem: `performance_mode=generalPurpose`, `throughput_mode=elastic`
  - Mount targets in all 3 private subnets
  - Security group allowing NFS (2049) from EKS node SG
  - Access Points: `/oc` and `/devflow`
- Write `k8s/storageclass-efs.yaml` with `provisioningMode: efs-ap`, `reclaimPolicy: Retain`
- Smoke test: test PVC + 2 pods in different AZs write/read same file
- Commit: `phase 5: EFS + StorageClass + cross-AZ RWX verified`

Gate: owner sees EFS in Console and confirms smoke test passed.

---

## Phase 6 — Ingress, DNS, TLS
Claude Code does:
- AWS Load Balancer Controller via Helm with IRSA
- ExternalDNS with IRSA (if owner has a domain)
- ACM certificate for `*.<domain>` (DNS-validated)
- Throwaway nginx test with HTTPS
- Commit: `phase 6: ingress + DNS + TLS`

Gate: owner confirms test URL works (or acknowledges no-domain path).

---

## Phase 7 — CBCI install: Operations Center only, no CasC yet
Claude Code does:
- Pin CloudBees Helm chart version
- Write `helm/values-base.yaml` — OC only, EFS storage, ALB ingress, resources, IRSA SA
- Create `cloudbees` namespace
- `helm install`
- Print OC URL

🛑 **HUMAN:** Owner completes setup wizard, enters CBCI trial license, creates admin, confirms UI loads.

Gate: owner says "OC is up, proceed"

---

## Phase 8 — OC CasC bundle 🛑 HUMAN PRIMARY
Owner writes `casc/oc-bundle/` (bundle.yaml, jenkins.yaml, plugins.yaml, items.yaml).
Owner creates ConfigMap, updates Helm values, upgrades chart.
Claude Code helps with YAML syntax.

Gate: owner says "CasC loaded, changes apply, proceed"

---

## Phase 9 — First managed controller (single replica) 🛑 HUMAN PRIMARY
Owner writes `casc/controller-bundles/devflow/`, declares controller in OC items.yaml, runs test pipeline on pod agent.

Gate: owner says "controller up, test pipeline green, proceed"

---

## Phase 10 — Active-active HA 🛑 HUMAN PRIMARY
Enable HA (2+ replicas), test failover, verify HPA scales on load.

Gate: owner says "HA working, failover verified"

---

## Phase 11 — Observability
Claude Code installs kube-prometheus-stack + Fluent Bit.
🛑 **HUMAN:** Owner enables CBCI metrics endpoint in CasC, imports Grafana dashboard, adds probes.

Gate: Grafana dashboard populated.

---

## Phase 12 — Secrets + SSO 🛑 HUMAN PRIMARY
External Secrets Operator, Secrets Manager entries, ExternalSecret resources, SSO in CasC.

Gate: SSO works, no static creds in Git.

---

## Phase 13 — Backup + DR drill
Claude Code sets up AWS Backup for EFS + Velero for K8s.
🛑 **HUMAN:** Owner runs DR drill — delete namespace, restore, time the RTO, document in runbook.

Gate: RTO measured and documented.

---

## Phase 14 — Migrate CasC to SCM (GitOps) 🛑 HUMAN PRIMARY
Bundle Service polling Git, retire ConfigMap delivery, PR-driven CasC changes.

Gate: full GitOps loop proven.

---

## Session hygiene
Start: `aws sts get-caller-identity`, `git pull`, check PLAN.md for NEXT.
End: commit, push, lab-stop, update PLAN.md.
Nuclear: `terraform destroy` in reverse order.