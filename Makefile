# ---- Config (override at runtime: make apply AWS_REGION=us-west-2 PREFIX=condor) ----
AWS_REGION ?= us-west-2
PREFIX ?= condor
AWS_PROFILE ?= kevin_sandbox

# Resolve ACCOUNT_ID dynamically (do NOT precompute at parse time in CI)
# ACCOUNT_ID := $(shell AWS_PROFILE=$(AWS_PROFILE) AWS_REGION=$(AWS_REGION) aws sts get-caller-identity --query Account --output text 2>/dev/null)

# These will be tagged at runtime after ACCOUNT_ID is resolved inside targets
# ECR_TRAINING ?= $(ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/condor-training:latest
# ECR_INFERENCE ?= $(ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/condor-inference:latest

# Do not export AWS_PROFILE globally; CI does not have this profile.
# export AWS_PROFILE
export AWS_REGION
export AWS_DEFAULT_REGION=$(AWS_REGION)
export AWS_SDK_LOAD_CONFIG=1

# Add --profile only if AWS_PROFILE is set (great for local, harmless in CI)
PROFILE_FLAG := $(if $(AWS_PROFILE),--profile $(AWS_PROFILE),)

.PHONY: whoami ecr-login build push build-push bootstrap plan apply outputs destroy plan-destroy nuke-ecr setup prep-data

setup:
	python3 -m venv .venv
	. .venv/bin/activate && pip install --upgrade pip && pip install -r requirements.txt

prep-data:
	python tools/prepare_data.py --bucket $$(cd infra/terraform && terraform output -raw data_bucket) --prefix features/ --min_rows 10000 --region $(AWS_REGION)

whoami:
	@echo "Profile: $${AWS_PROFILE:-<none>}  Region: $(AWS_REGION)"
	aws sts get-caller-identity --region $(AWS_REGION) $(PROFILE_FLAG)

# ---- ECR: build & push images ----
ecr-login: whoami
	@ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text --region $(AWS_REGION) $(PROFILE_FLAG)); \
	echo "Using Account $$ACCOUNT_ID"; \
	aws ecr get-login-password --region $(AWS_REGION) $(PROFILE_FLAG) | docker login --username AWS --password-stdin $$ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com

build:
	# Ensure amd64 images for SageMaker + consistent CI builds
	docker buildx build --platform linux/amd64 -t condor-training:latest services/training --load
	docker buildx build --platform linux/amd64 -t condor-inference:latest services/inference --load

# make sure terraform apply has been run to create ECR repos before pushing
push: ecr-login
	@ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text --region $(AWS_REGION) $(PROFILE_FLAG)); \
	ECR_TRAINING=$$ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com/condor-training:latest; \
	ECR_INFERENCE=$$ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com/condor-inference:latest; \
	echo "Pushing to $$ECR_TRAINING and $$ECR_INFERENCE"; \
	docker tag condor-training:latest  $$ECR_TRAINING; \
	docker tag condor-inference:latest $$ECR_INFERENCE; \
	docker push $$ECR_TRAINING; \
	docker push $$ECR_INFERENCE

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
	@repos=$$(aws ecr describe-repositories --region "$(AWS_REGION)" $(PROFILE_FLAG) --query 'repositories[].repositoryName' --output text) ; \
	if [ -z "$$repos" ]; then echo "No ECR repos"; else \
	 for r in $$repos; do echo "Deleting $$r (force)"; aws ecr delete-repository --repository-name "$$r" --region "$(AWS_REGION)" $(PROFILE_FLAG) --force; done ; fi