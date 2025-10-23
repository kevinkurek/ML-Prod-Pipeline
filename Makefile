# ---- Config (override at runtime: make apply AWS_REGION=us-west-2 PREFIX=condor) ----
AWS_REGION ?= us-west-2
PREFIX ?= condor
AWS_PROFILE ?= kevin_sandbox

# Resolve ACCOUNT_ID dynamically
ACCOUNT_ID := $(shell AWS_PROFILE=$(AWS_PROFILE) AWS_REGION=$(AWS_REGION) aws sts get-caller-identity --query Account --output text 2>/dev/null)

ECR_TRAINING ?= $(ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/condor-training:latest
ECR_INFERENCE ?= $(ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/condor-inference:latest

export AWS_PROFILE
export AWS_REGION
export AWS_DEFAULT_REGION=$(AWS_REGION)
export AWS_SDK_LOAD_CONFIG=1

.PHONY: whoami ecr-login build push build-push bootstrap plan apply outputs destroy plan-destroy nuke-ecr

whoami:
	@echo "Profile: $(AWS_PROFILE)  Region: $(AWS_REGION)  Account: $(ACCOUNT_ID)"

# ---- ECR: build & push images ----
ecr-login: whoami
	aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com

build:
	docker build -t condor-training:latest services/training
	docker build -t condor-inference:latest services/inference

# make sure terraform apply has been run to create ECR repos before pushing
push: ecr-login
	docker tag condor-training:latest  $(ECR_TRAINING)
	docker tag condor-inference:latest $(ECR_INFERENCE)
	docker push $(ECR_TRAINING)
	docker push $(ECR_INFERENCE)

build-push: build push

# ---- Terraform lifecycle ----
bootstrap:
	cd infra/terraform && terraform init -reconfigure

plan:
	cd infra/terraform && terraform plan -var="prefix=$(PREFIX)" -var="region=$(AWS_REGION)"

apply:
	cd infra/terraform && terraform apply -auto-approve -var="prefix=$(PREFIX)" -var="region=$(AWS_REGION)"

outputs:
	cd infra/terraform && terraform output

plan-destroy:
	cd infra/terraform && terraform plan -destroy -var="prefix=$(PREFIX)" -var="region=$(AWS_REGION)"

destroy:
	cd infra/terraform && terraform destroy -auto-approve -var="prefix=$(PREFIX)" -var="region=$(AWS_REGION)"

# ---- Helpers to clean ECR if needed before destroy ----
nuke-ecr:
	@repos=$$(aws ecr describe-repositories --region "$(AWS_REGION)" --query 'repositories[].repositoryName' --output text) ; \
	if [ -z "$$repos" ]; then echo "No ECR repos"; else \
	 for r in $$repos; do echo "Deleting $$r (force)"; aws ecr delete-repository --repository-name "$$r" --region "$(AWS_REGION)" --force; done ; fi