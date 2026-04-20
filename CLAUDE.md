# CBCI on AWS — Project Context

## What this project is
A personal learning lab to build CloudBees CI (Modern) on AWS EKS, mirroring an existing production deployment that runs on Azure AKS. The owner is porting the platform to AWS to deeply understand both AWS and Kubernetes by implementing it himself.

The owner is a senior Jenkins platform engineer at Mastercard. He already runs Jenkins HA/HS in production. The CBCI knowledge is solid; the AWS + EKS knowledge is what he's building.

## Success criteria
1. CBCI Operations Center running on EKS with ALB ingress and EFS-backed storage
2. At least one managed controller in active-active HA (2 replicas) behind that OC
3. All Jenkins/CBCI configuration managed via CasC bundles — no UI clicking
4. Ephemeral pod-based build agents running on a separate Karpenter node pool
5. Entra ID SAML SSO with group-based RBAC
6. Owner understands every piece well enough to explain it in an interview

## Execution model
Claude Code implements every phase end-to-end — AWS infrastructure, Helm, CBCI CasC bundles, HA enablement, SSO, secrets, backup, observability, and DR drills.

The owner approves plans before state-changing actions and reviews results. The owner does not hand-write CasC YAML, Terraform, or Helm values — Claude Code writes all of it.

Gates between phases:
1. Claude Code summarizes what it's about to do and why
2. Owner approves with "proceed" or gives corrections
3. Claude Code executes (terraform plan → terraform apply on approval, helm install, kubectl apply, etc.)
4. Claude Code verifies the result, prints what was created, commits, pushes
5. Claude Code proposes the next phase

The owner is always in the loop for plan approval but is not required to write code or run commands themselves.

At Phase 12a the owner clicks through the Entra admin UI for tenant-side setup (Enterprise Application creation, group creation, user assignment) because that cannot be automated from CBCI. Claude Code provides the exact click-path, values, and does all the CBCI-side configuration.

## Environment
- AWS account: personal sandbox (account ID in `.env.local`, not committed)
- IAM user: `naga-admin` (used locally via `AWS_PROFILE=cbci-lab`)
- Region: `us-east-1`
- MacBook: Apple Silicon, macOS, zsh
- Tools: Terraform 1.14.8 (via tfenv), AWS CLI 2.34, kubectl 1.35, Helm 4.1, eksctl 0.225, Docker 29, VS Code

## Architecture decisions (do not change without asking)
| Decision | Choice | Why |
|---|---|---|
| Region | us-east-1 | Cheapest, most service coverage |
| VPC CIDR | 10.0.0.0/16, 3 AZs | Standard 3-AZ layout |
| NAT | Single NAT gateway in one AZ | Cost — lab, not prod (~$32/mo) |
| EKS version | 1.31 | Latest stable at time of build |
| Node strategy | Managed node group for system pods; Karpenter for controllers + agents | Stability for platform, agility for workloads |
| Karpenter NodePools | 3 — system (managed), controllers (on-demand), agents (spot+on-demand with taint) | Agent churn must not evict controllers |
| Controller storage | Amazon EFS, General Purpose performance, Elastic throughput, KMS-encrypted | CBCI HA active-active needs RWX; Elastic is best for spiky Jenkins I/O |
| EFS layout | One filesystem, Access Point per controller | Clean per-controller blast radius |
| Ingress | AWS Load Balancer Controller with ALB | AWS-native, WAF-ready, ACM integration |
| DNS | Route 53 + ExternalDNS | Auto records from Ingress |
| TLS | ACM certificate (DNS-validated) | Free, auto-renewing |
| Identity/SSO | Microsoft Entra ID (owner's personal tenant), SAML 2.0, group-based RBAC | Mirrors Mastercard production pattern; SAML preferred over OIDC for CBCI active-active HA compatibility; local admin first, SSO added in Phase 12a |
| SAML plugin | Jenkins SAML Plugin (not the Azure AD plugin) | More portable, better-documented, easier to swap IdPs later |
| Secrets | AWS Secrets Manager + External Secrets Operator | No static creds in Git |
| Backup | AWS Backup for EFS + Velero for K8s resources | Two layers, both required |
| Observability | kube-prometheus-stack + Fluent Bit → CloudWatch | Free, industry-standard |
| CBCI CasC delivery | Start with ConfigMap-mounted bundles; migrate to SCM/Bundle Service in Phase 14 | Learn moving parts before full GitOps |

## Working rules for Claude Code
1. **Never commit secrets.** If the owner ever pastes a secret, stop and warn them.
2. **Always show terraform plan before apply.** Never run `terraform apply -auto-approve`.
3. **Incremental commits.** After each successful phase, commit with a message like `phase 1: VPC + subnets + NAT applied`.
4. **Cost awareness.** Before creating anything that costs money (NAT gateway, EKS, EFS), mention the running cost.
5. **Use us-east-1.** Never create resources in other regions without asking.
6. **Profile discipline.** All AWS commands must use `--profile cbci-lab` or rely on `AWS_PROFILE=cbci-lab` being set.
7. **Pin versions.** Providers, Helm charts, Karpenter, EKS, add-ons must have pinned versions — no `latest`.
8. **Idempotency.** All scripts and TF must be safe to re-run.
9. **Summarize plans before state-changing actions.** Get "proceed" approval before terraform apply, helm install, or any resource creation.
10. **Ask before deviating.** If a decision above looks wrong based on what you discover, stop and ask.

## How to start a session
1. Run `aws sts get-caller-identity` and confirm account matches `.env.local` and user is `naga-admin`
2. Read `PLAN.md` and find where work last left off
3. Summarize the current phase and next action before doing anything

## How to end a session
1. Run `./scripts/lab-stop.sh` if nodes are running
2. Commit and push the session's work
3. Update `PLAN.md` — mark phases DONE, mark the next one NEXT
4. Print estimated cost if anything is still running