# CBCI on AWS — single-command platform management
# Usage: make <target> ENV=dev|stage
#
# Prerequisites: AWS CLI configured, kubectl installed, Helm 4+, Terraform 1.14+

ENV     ?= dev
PROFILE ?= cbci-lab

-include environments/$(ENV)/env.sh

.PHONY: help plan apply bootstrap destroy stop start status

help:
	@echo "CBCI on AWS — available targets:"
	@echo ""
	@echo "  make plan      ENV=dev    Terraform plan across all modules"
	@echo "  make apply     ENV=dev    Terraform apply all modules (requires approval)"
	@echo "  make bootstrap ENV=dev    Install Helm charts + provision controllers"
	@echo "  make stop      ENV=dev    Scale nodes to 0 (pause lab, save cost)"
	@echo "  make start     ENV=dev    Scale nodes back up"
	@echo "  make status    ENV=dev    Show cluster and pod health"
	@echo "  make destroy   ENV=dev    Destroy all infrastructure (DESTRUCTIVE)"
	@echo ""

plan:
	@echo "=== Terraform plan — ENV=$(ENV) ==="
	@for mod in 10-network 20-eks 30-storage 40-addons 50-ingress 60-platform; do \
	  echo "--- $$mod ---"; \
	  cd terraform/$$mod && \
	  terraform init -backend-config="key=$$mod/terraform.tfstate" -reconfigure -input=false && \
	  terraform plan -var-file="../../environments/$(ENV)/terraform.tfvars" -input=false; \
	  cd ../..; \
	done

apply:
	@echo "=== Terraform apply — ENV=$(ENV) ==="
	@echo "This will create/modify AWS infrastructure. Ctrl-C to abort."
	@sleep 3
	@for mod in 10-network 20-eks 30-storage 40-addons 50-ingress 60-platform; do \
	  echo "--- Applying $$mod ---"; \
	  cd terraform/$$mod && \
	  terraform init -backend-config="key=$$mod/terraform.tfstate" -reconfigure -input=false && \
	  terraform apply -var-file="../../environments/$(ENV)/terraform.tfvars" -input=false -auto-approve; \
	  cd ../..; \
	done

bootstrap:
	@echo "=== Bootstrap Helm + CBCI — ENV=$(ENV) ==="
	AWS_PROFILE=$(PROFILE) bash scripts/bootstrap.sh $(ENV)

stop:
	AWS_PROFILE=$(PROFILE) bash scripts/lab-stop.sh

start:
	AWS_PROFILE=$(PROFILE) bash scripts/lab-start.sh

status:
	@echo "=== Nodes ===" && kubectl get nodes -o wide
	@echo ""
	@echo "=== CloudBees pods ===" && kubectl get pods -n cloudbees
	@echo ""
	@echo "=== Controllers ===" && \
	  kubectl exec -n cloudbees cjoc-0 -- sh -c \
	    "grep -h 'localEndpoint' /var/jenkins_home/jobs/devflow/config.xml /var/jenkins_home/jobs/test1/config.xml 2>/dev/null || echo 'controllers not yet provisioned'"

destroy:
	@echo "=== DESTRUCTIVE: terraform destroy — ENV=$(ENV) ==="
	@echo "This destroys ALL infrastructure. Type 'yes' to confirm."
	@read CONFIRM && [ "$$CONFIRM" = "yes" ] || (echo "Aborted." && exit 1)
	@for mod in 60-platform 50-ingress 40-addons 30-storage 20-eks 10-network; do \
	  echo "--- Destroying $$mod ---"; \
	  cd terraform/$$mod && \
	  terraform destroy -var-file="../../environments/$(ENV)/terraform.tfvars" -input=false -auto-approve; \
	  cd ../..; \
	done
