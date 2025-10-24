# ---- Config (override at runtime: make apply AWS_REGION=us-west-2 PREFIX=condor) ----
AWS_REGION ?= us-west-2
PREFIX ?= condor
# AWS_PROFILE ?= $(if $(CI),,$(shell echo kevin_sandbox)) # Only default to kevin_sandbox if we're running interactively (not CI)

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
# PROFILE_FLAG := $(if $(AWS_PROFILE),--profile $(AWS_PROFILE),)

.PHONY: whoami ecr-login build push build-push bootstrap plan apply outputs destroy plan-destroy nuke-ecr setup prep-data

setup:
	python3 -m venv .venv
	. .venv/bin/activate && pip install --upgrade pip && pip install -r requirements.txt

prep-data:
	python tools/prepare_data.py --bucket $$(cd infra/terraform && terraform output -raw data_bucket) --prefix features/ --min_rows 10000 --region $(AWS_REGION)

whoami:
	@echo "Profile: $${AWS_PROFILE:-<none>}  Region: $(AWS_REGION)"
	aws sts get-caller-identity --region $(AWS_REGION)

# ---- ECR: build & push images ----
ecr-login: whoami
	@ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text --region $(AWS_REGION)); \
	echo "Using Account $$ACCOUNT_ID"; \
	aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $$ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com

build:
	# Ensure amd64 images for SageMaker + consistent CI builds
	docker buildx build --platform linux/amd64 -t condor-training:latest services/training --load
	docker buildx build --platform linux/amd64 -t condor-inference:latest services/inference --load

# make sure terraform apply has been run to create ECR repos before pushing
push: ecr-login
	@ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text --region $(AWS_REGION)); \
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
	@repos=$$(aws ecr describe-repositories --region "$(AWS_REGION)" --query 'repositories[].repositoryName' --output text) ; \
	if [ -z "$$repos" ]; then echo "No ECR repos"; else \
	 for r in $$repos; do echo "Deleting $$r (force)"; aws ecr delete-repository --repository-name "$$r" --region "$(AWS_REGION)" --force; done ; fi


# ---- SageMaker cleanup ----
.PHONY: sm-status sm-teardown

sm-status:
	@echo "Endpoint status:"
	-aws sagemaker describe-endpoint --endpoint-name condor-xgb --region $(AWS_REGION) --query '{Name:EndpointName,Status:EndpointStatus,Config:EndpointConfigName}' --output table || true
	@echo "Endpoint configs (condor):"
	-aws sagemaker list-endpoint-configs --name-contains condor --region $(AWS_REGION) --query 'EndpointConfigs[].EndpointConfigName' --output table || true
	@echo "Models (condor):"
	-aws sagemaker list-models --name-contains condor --region $(AWS_REGION) --query 'Models[].ModelName' --output table || true

# Deletes endpoint -> its config -> its models (derived from the config)
sm-teardown:
	@EP=condor-xgb; \
	CFG=$$(aws sagemaker describe-endpoint --endpoint-name $$EP --region $(AWS_REGION) --query EndpointConfigName --output text 2>/dev/null || true); \
	echo "Deleting SageMaker endpoint: $$EP (config=$$CFG)"; \
	aws sagemaker delete-endpoint --endpoint-name $$EP --region $(AWS_REGION) 2>/dev/null || true; \
	aws sagemaker wait endpoint-deleted --endpoint-name $$EP --region $(AWS_REGION) 2>/dev/null || true; \
	if [ -n "$$CFG" ] && [ "$$CFG" != "None" ]; then \
	  echo "Deleting endpoint config: $$CFG"; \
	  MODELS=$$(aws sagemaker describe-endpoint-config --endpoint-config-name $$CFG --region $(AWS_REGION) --query 'ProductionVariants[].ModelName' --output text 2>/dev/null || true); \
	  aws sagemaker delete-endpoint-config --endpoint-config-name $$CFG --region $(AWS_REGION) 2>/dev/null || true; \
	  for m in $$MODELS; do \
	    if [ -n "$$m" ] && [ "$$m" != "None" ]; then \
	      echo "Deleting model: $$m"; \
	      aws sagemaker delete-model --model-name "$$m" --region $(AWS_REGION) 2>/dev/null || true; \
	    fi; \
	  done; \
	fi

# ---- S3 cleanup (empties the condor* buckets from TF outputs) ----
.PHONY: empty-buckets
empty-buckets:
	@DATA_BUCKET=$$(cd infra/terraform && terraform output -raw data_bucket 2>/dev/null || true); \
	ART_BUCKET=$$(cd infra/terraform && terraform output -raw artifacts_bucket 2>/dev/null || true); \
	LOGS_BUCKET=$$(cd infra/terraform && terraform output -raw logs_bucket 2>/dev/null || true); \
	for B in $$DATA_BUCKET $$ART_BUCKET $$LOGS_BUCKET; do \
	  if [ -n "$$B" ]; then \
	    echo "Emptying s3://$$B ..."; \
	    aws s3 rm "s3://$$B" --recursive --region "$(AWS_REGION)" || true; \
	  fi; \
	done

# ---- Full teardown (endpoint + buckets + ecr + terraform destroy) ----
.PHONY: down
down: sm-teardown empty-buckets nuke-ecr destroy

# ---- Quick monthly cost check (requires Cost Explorer enabled) ----
.PHONY: cost
cost:
	@echo -n "Month-to-date blended cost (USD): "; \
	aws ce get-cost-and-usage \
	  --time-period Start=$$(date -v1d +%Y-%m-01),End=$$(date -v+1m -v1d +%Y-%m-01) \
	  --granularity MONTHLY \
	  --metrics BlendedCost \
	  --region us-east-1 \
	  --query 'ResultsByTime[0].Total.BlendedCost.Amount' \
	  --output text 2>/dev/null || echo "Enable Cost Explorer first"