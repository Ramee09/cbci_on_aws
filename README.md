# CloudBees CI on AWS EKS

A hands-on implementation of **CloudBees CI (Modern)** running on **Amazon EKS**, mirroring a production Azure AKS deployment. Built as a personal learning lab to deepen AWS and Kubernetes expertise by implementing the full platform end-to-end.

## Target architecture

- **EKS 1.31** — managed Kubernetes control plane
- **Karpenter** — node autoscaling with separate pools for controllers and ephemeral build agents
- **Amazon EFS** (General Purpose + Elastic throughput) — shared RWX storage backing CloudBees CI active-active HA controllers
- **AWS Load Balancer Controller + ACM + Route 53** — HTTPS ingress
- **External Secrets Operator** — syncs AWS Secrets Manager into Kubernetes
- **CloudBees CI** — Operations Center + Managed Controllers, managed entirely via Configuration-as-Code (CasC) bundles
- **kube-prometheus-stack + CloudWatch** — observability
- **AWS Backup + Velero** — two-layer backup strategy

## Status

🚧 Work in progress. See [`PLAN.md`](./PLAN.md) for current phase.

## Disclaimer

Personal learning project, not production code. Do not copy IAM policies, trust relationships, or security settings verbatim into production environments without review.