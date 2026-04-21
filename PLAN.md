# Phased Plan — CBCI on AWS

Status legend: `TODO` | `NEXT` | `IN PROGRESS` | `DONE`

Claude Code implements every phase end-to-end. The owner approves plans before state-changing actions. No hand-written YAML, Terraform, or Helm values expected from the owner.

---

## Phase 0 — Project bootstrap [DONE]
Project scaffold, .gitignore, README, CLAUDE.md, PLAN.md, folder structure, pre-commit hook, first commit.

---

## Phase 1 — Terraform remote state [DONE]
Claude Code wrote `terraform/00-bootstrap/main.tf`: S3 bucket `cbci-lab-tfstate-<accountId>` (versioning, encryption, public access block) and DynamoDB table `cbci-lab-tf-locks`. Applied, committed.

Gate met: owner verified bucket and table exist in AWS Console.

---

## Phase 2 — VPC + networking [DONE]
Claude Code wrote `terraform/10-network/` using `terraform-aws-modules/vpc/aws` v5.x: VPC 10.0.0.0/16, 3 AZs, 3 public + 3 private subnets, single NAT gateway, subnet tags for EKS and Karpenter discovery. Remote state in Phase 1 bucket. Applied, committed.

Cost: NAT gateway ~$1/day.
Gate met: owner saw VPC in Console.

---

## Phase 3 — EKS cluster + system node group [DONE]
Claude Code wrote `terraform/20-eks/` using `terraform-aws-modules/eks/aws` v20.x: EKS 1.31, private API endpoint with restricted public access, managed node group `system` (2× t3.medium on-demand in private subnets), OIDC provider for IRSA, add-ons (vpc-cni, coredns, kube-proxy, aws-ebs-csi-driver, aws-efs-csi-driver, metrics-server). Applied, `kubectl get nodes` verified 2 Ready nodes, committed.

Cost: EKS control plane ~$2.40/day (24/7).
Gate met: owner saw cluster healthy.

---

## Phase 4 — Karpenter + workload NodePools [DONE]
Claude Code does:
- IAM roles for Karpenter node + controller (with IRSA)
- Install Karpenter via Helm, pinned version
- Two NodePools + one EC2NodeClass:
  - `controllers`: on-demand, t3.large/t3.xlarge, label `nodepool=controllers`
  - `agents`: spot+on-demand fallback, t3.medium/t3.large/m5.large, taint `workload=agents:NoSchedule`, label `nodepool=agents`
- EC2NodeClass: AL2023, subnet and SG discovery by `karpenter.sh/discovery=cbci-lab`
- Smoke test: deploy throwaway pod tolerating agent taint → Karpenter provisions node in ~60s → delete pod → node consolidates away
- Commit: `phase 4: Karpenter + NodePools`

Gate: owner approves "proceed."

---

## Phase 5 — EFS filesystem + StorageClass [DONE]
Claude Code does:
- Write `terraform/30-storage/`:
  - KMS key with rotation enabled
  - EFS filesystem: `performance_mode=generalPurpose`, `throughput_mode=elastic`, KMS-encrypted
  - Mount targets in all 3 private subnets
  - Security group allowing NFS (2049) from EKS node SG
  - Access Points: `/oc` (uid/gid 1000) and `/devflow` (uid/gid 1000)
- Write `k8s/storageclass-efs.yaml`: `provisioner: efs.csi.aws.com`, `provisioningMode: efs-ap`, `reclaimPolicy: Retain`
- Apply TF, apply StorageClass
- Smoke test: create test PVC + two pods in different AZs, write file from pod A, read from pod B — confirm RWX works cross-AZ, delete test
- Commit: `phase 5: EFS + KMS + StorageClass + cross-AZ RWX verified`

Gate: owner approves "proceed."

---

## Phase 6 — Ingress, DNS, TLS [DONE]
Claude Code does:
- Install AWS Load Balancer Controller via Helm with IRSA (pinned version)
- If owner has a domain: install ExternalDNS via Helm with IRSA, pointing at Route 53 hosted zone. If no domain: skip ExternalDNS, use raw ALB hostnames.
- If owner has a domain: create ACM certificate for `*.<domain>` (DNS-validated)
- Smoke test: deploy throwaway nginx + Ingress with ALB annotations → verify HTTPS works end-to-end → delete test
- Commit: `phase 6: ingress + DNS + TLS plumbing verified`

Gate: owner approves "proceed" (confirming whether a domain is in use).

---

## Phase 7 — CBCI install: Operations Center [DONE]
Claude Code does:
- Add CloudBees Helm repo, pin chart version
- Write `helm/values-base.yaml` — OC only (controllers come in Phase 9), EFS storage, ALB ingress, resource requests/limits, IRSA-annotated ServiceAccount
- Create `cloudbees` namespace
- `helm install cbci cloudbees/cloudbees-core -n cloudbees -f helm/values-base.yaml`
- Wait for OC pod Ready
- Retrieve OC initial admin password from pod logs
- Trial license: owner provides key if purchased, otherwise use built-in evaluation
- Complete setup wizard programmatically via API/CLI if possible, or document one-time UI click-through
- Verify OC UI loads via ALB URL
- Commit: `phase 7: CBCI OC installed`

Gate: owner visits OC URL, confirms it loads, approves "proceed."

---

## Phase 8 — OC CasC bundle (ConfigMap delivery) [DONE]
Claude Code does:
- Write `casc/oc-bundle/bundle.yaml` — id, version, description
- Write `casc/oc-bundle/jenkins.yaml` — local admin security realm (SSO comes in 12a), authorization strategy
- Write `casc/oc-bundle/plugins.yaml` — base plugin list, pinned versions
- Write `casc/oc-bundle/items.yaml` — empty for now (controllers declared in Phase 9)
- Create ConfigMap: `kubectl create configmap oc-casc-bundle --from-file=casc/oc-bundle/ -n cloudbees`
- Update `helm/values-base.yaml` to mount the ConfigMap as CasC source
- `helm upgrade cbci ...`
- Restart OC pod, verify bundle loaded in Manage Jenkins → CasC
- Commit: `phase 8: OC CasC bundle via ConfigMap`

Gate: owner approves "proceed."

---

## Phase 9 — First managed controller (single replica) [DONE]
devflow controller provisioned via Helm values, CasC bundle delivered via EFS at `/var/jenkins_home/casc-bundle/`. javaOptions set via OC Groovy: `-Dcore.casc.config.bundle=/var/jenkins_home/casc-bundle`. Both devflow and test1 controllers running.

Note: `managedMaster` kind in OC items.yaml causes `CasCInvalidKindException` on every OC pod restart in CBCI 2.555.x. Items.yaml removed from OC bundle; controllers persist on EFS and reconnect on OC startup.

---

## Phase 10 — Active-active HA [DONE]
devflow and test1 both running 2 replicas (active-active). Replication set via OC Groovy: `config.replication = new Replication(2, 4, 70)`. Both controllers share EFS access points for RWX storage.

---

## Phase 11 — Observability [DONE]
- kube-prometheus-stack v83.6.0 installed in `monitoring` namespace; 46 targets all healthy
- Grafana running with 30 dashboards (all standard k8s dashboards + Jenkins performance dashboard); access via `kubectl port-forward svc/kube-prometheus-stack-grafana 3000:3000 -n monitoring`, credentials: `admin / cbci-grafana-admin`
- Fluent Bit v0.57.3 (chart) DaemonSet running on all 7 nodes, shipping logs to CloudWatch `/aws/eks/cbci-lab` via IRSA role `cbci-lab-fluent-bit`
- Note: Jenkins Prometheus plugin not in CloudBees CAP; controller-level Jenkins metrics not available via Prometheus. k8s-level metrics (CPU, memory, restarts) covered by kube-state-metrics + node-exporter.

Gate met: 46 Prometheus targets healthy, CloudWatch log streams verified, Grafana dashboards populated.

---

## Phase 12a — Entra ID SAML SSO [NEXT]
Identity provider: owner's personal Microsoft Entra tenant (free tier — no license purchase).
Plugin: Jenkins SAML Plugin, pinned in `plugins.yaml`.

Entra-side setup (owner clicks through the Entra admin UI with Claude Code's exact click-path and values):
- Create a SAML Enterprise Application for CBCI
- Create AD groups: `cbci-admins`, `cbci-devflow-admins`, `cbci-devflow-developers`, `cbci-readonly`
- Assign self + one test user to groups
- Provide Claude Code with the federation metadata URL, entity ID, and SAML signing certificate

CBCI-side setup (Claude Code does):
- Add `saml` plugin to `plugins.yaml` at pinned version
- Configure SAML security realm in OC `jenkins.yaml` — entity ID, reply URL, metadata URL, attribute mappings for groups, NameID format
- Configure group-based RBAC in `rbac.yaml` — map Entra group names to Jenkins global + per-controller roles
- Reload bundle
- Test: log in as admin test user (observes admin permissions), log in as developer test user (observes restricted permissions)
- Troubleshoot any entity ID / reply URL / certificate / NameID format mismatches
- Commit: `phase 12a: Entra SAML SSO with group-based RBAC`

Gate: owner logs in via Entra as both admin and developer, confirms correct permissions in each case, approves "proceed."

---

## Phase 12b — Secrets management
Claude Code does:
- Install External Secrets Operator via Helm (pinned) with IRSA
- Create ClusterSecretStore pointing at AWS Secrets Manager
- For each credential CBCI needs: create Secrets Manager entry + corresponding `ExternalSecret` resource
- Update CBCI CasC to reference synced secrets via Jenkins credential providers
- Audit all Git-tracked files for hardcoded credentials (grep for common patterns)
- Commit: `phase 12b: secrets via ESO + Secrets Manager`

Gate: owner approves "proceed."

---

## Phase 13 — Backup + DR drill
Claude Code does:
- Enable AWS Backup plan for EFS filesystem — daily snapshot, 7-day retention
- Install Velero via Helm with AWS plugin + IRSA, S3 bucket for backups
- Schedule daily Velero backup of `cloudbees` namespace, 7-day retention
- Run DR drill: delete `cloudbees` namespace, restore from Velero, measure RTO
- Document results and runbook in `docs/runbooks/dr-restore.md`
- Print measured RTO to owner
- Commit: `phase 13: backup + DR drill, RTO documented`

Gate: owner approves "proceed."

---

## Phase 14 — Migrate CasC to SCM (GitOps Bundle Service)
Claude Code does:
- Create Git structure for CasC bundles (subdirectory of this repo or separate repo — owner decides)
- Configure OC Bundle Service to poll the Git source
- Retire ConfigMap-based delivery
- Make a test change via PR → merge → watch OC pick it up → verify controllers reconcile
- Document GitOps workflow in `docs/runbooks/casc-gitops.md`
- Commit: `phase 14: CasC via SCM Bundle Service — project complete`

Gate: owner approves "project complete."

---

## Session hygiene
Start: `aws sts get-caller-identity`, `git pull`, check PLAN.md for NEXT.
End: commit, push, lab-stop, update PLAN.md.
Nuclear: `terraform destroy` in reverse order (40 → 30 → 20 → 10, keep 00 bootstrap).