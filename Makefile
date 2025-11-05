# Load .env but do NOT blindly export all keys (avoid overriding AWS creds)
ifneq (,$(wildcard .env))
include .env
export AWS_REGION GITHUB_TOKEN PREFIX AWS_PROFILE
endif

# Some defaults
export AWS_DEFAULT_REGION=$(AWS_REGION)
export AWS_SDK_LOAD_CONFIG=1

# --- Python venv wiring ---
VENV_DIR := .venv
PYTHON   := $(VENV_DIR)/bin/python
PIP      := $(VENV_DIR)/bin/pip

# ---------- Image/ECR config ----------
PLATFORM        ?= linux/amd64
TRAINING_IMAGE  ?= condor-training
INFERENCE_IMAGE ?= condor-inference
FEATURES_IMAGE  ?= condor-features
BATCH_REPO      ?= condor-batch

# EXPLANATION: default prefix for resource names (can be overridden in .env)
# .PHONY EXPLANATION: make targets that are not files - without this, if a file named "build" existed, `make build` would think it's up to date and do nothing
.PHONY: whoami ecr-login build push build-push bootstrap plan apply outputs destroy plan-destroy nuke-ecr setup prep-data env-check

# EXPLANATION: check environment variables were loaded correctly
env-check:
	@set -e; \
	ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text --region "$(AWS_REGION)"); \
	echo "AWS_REGION=$(AWS_REGION)"; \
	echo "GITHUB_TOKEN set? $${GITHUB_TOKEN:+yes}${GITHUB_TOKEN:+" (length $$(( $${#GITHUB_TOKEN} )))"}"; \
	echo "AWS_PROFILE=$${AWS_PROFILE:-<none>}"; \
	echo "TRAINING_IMAGE=$(TRAINING_IMAGE)"; \
	echo "INFERENCE_IMAGE=$(INFERENCE_IMAGE)"; \
	echo "FEATURES_IMAGE=$(FEATURES_IMAGE)"; \
	echo "BATCH_REPO=$(BATCH_REPO)"; \
	echo "TRAIN  = $$ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com/$(TRAINING_IMAGE):latest"; \
	echo "INFER  = $$ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com/$(INFERENCE_IMAGE):latest"; \
	echo "FEATURE= $$ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com/$(FEATURES_IMAGE):latest"; \
	echo "BATCH  = $$ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com/$(BATCH_REPO):latest"

# EXPLANATION: setup python virtual environment and install dependencies
setup:
	python3 -m venv $(VENV_DIR)
	$(PIP) install --upgrade pip
	$(PIP) install -r requirements.txt

# EXPLANATION: prepare data and upload to S3 bucket
prep-data:
	$(PYTHON) tools/prepare_data.py --bucket $$(cd infra/terraform && terraform output -raw data_bucket) --prefix features/ --min_rows 10000 --region $(AWS_REGION)

# EXPLANATION: show the AWS identity being used
whoami:
	@echo "Profile: $${AWS_PROFILE:-<none>}  Region: $(AWS_REGION)"
	aws sts get-caller-identity --region $(AWS_REGION)

# ---- ECR: build & push images ----

# EXPLANATION: login to ECR using AWS CLI
ecr-login: whoami
	@ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text --region $(AWS_REGION)); \
	echo "Using Account $$ACCOUNT_ID"; \
	aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $$ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com

# EXPLANATION: build the Docker images for features, training, and inference
build:
	# Ensure amd64 images for SageMaker + consistent CI builds
	docker build --platform $(PLATFORM) -t $(FEATURES_IMAGE):latest  services/features  --load
	docker build --platform $(PLATFORM) -t $(TRAINING_IMAGE):latest  services/training  --load
	docker build --platform $(PLATFORM) -t $(INFERENCE_IMAGE):latest services/inference --load
	docker build --platform $(PLATFORM) -t $(BATCH_REPO):latest services/batch --load

# EXPLANATION: confirm ecr-login has been done, tag and push images to ECR
# NOTE: make sure terraform apply has been run to create ECR repos before pushing
push: ecr-login
	@set -e; \
	ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text --region $(AWS_REGION)); \
	ECR_TRAINING=$$ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com/$(TRAINING_IMAGE):latest; \
	ECR_INFERENCE=$$ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com/$(INFERENCE_IMAGE):latest; \
	ECR_FEATURES=$$ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com/$(FEATURES_IMAGE):latest; \
	ECR_BATCH=$$ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com/$(BATCH_REPO):latest; \
	echo "Pushing:"; \
	echo "  $(TRAINING_IMAGE):latest  -> $$ECR_TRAINING"; \
	echo "  $(INFERENCE_IMAGE):latest -> $$ECR_INFERENCE"; \
	echo "  $(FEATURES_IMAGE):latest  -> $$ECR_FEATURES"; \
	echo "  $(BATCH_REPO):latest      -> $$ECR_BATCH"; \
	docker tag $(TRAINING_IMAGE):latest  $$ECR_TRAINING;  docker push $$ECR_TRAINING; \
	docker tag $(INFERENCE_IMAGE):latest $$ECR_INFERENCE; docker push $$ECR_INFERENCE; \
	docker tag $(FEATURES_IMAGE):latest  $$ECR_FEATURES;  docker push $$ECR_FEATURES; \
	docker tag $(BATCH_REPO):latest      $$ECR_BATCH;      docker push $$ECR_BATCH;

# EXPLANATION: build and push images in 1 step rather than individually
build-push: build push

# ---- Terraform lifecycle ----

# EXPLANATION: setup terraform - download providers, initializing the backend, preparing the working directory
bootstrap:
	cd infra/terraform && terraform init -reconfigure

# EXPLANATION: show what terraform will set up and/or change
plan:
	cd infra/terraform && terraform plan -var="prefix=$(PREFIX)" -var="region=$(AWS_REGION)"

# EXPLANATION: apply the terraform changes (create/update infrastructure)
apply:
	cd infra/terraform && terraform apply -auto-approve -var="prefix=$(PREFIX)" -var="region=$(AWS_REGION)"

# EXPLANATION: show the terraform outputs (e.g., bucket names, role ARNs)
outputs:
	cd infra/terraform && terraform output

# EXPLANATION: show what terraform will destroy
plan-destroy:
	cd infra/terraform && terraform plan -destroy -var="prefix=$(PREFIX)" -var="region=$(AWS_REGION)"

# EXPLANATION: destroy all terraform-managed infrastructure
destroy:
	cd infra/terraform && terraform destroy -auto-approve -var="prefix=$(PREFIX)" -var="region=$(AWS_REGION)"

# ---- Helpers to clean ECR if needed before destroy ----

# EXPLANATION: delete all ECR repositories in the region (force delete all images)
nuke-ecr:
	@repos=$$(aws ecr describe-repositories --region "$(AWS_REGION)" --query 'repositories[].repositoryName' --output text) ; \
	if [ -z "$$repos" ]; then echo "No ECR repos"; else \
	 for r in $$repos; do echo "Deleting $$r (force)"; aws ecr delete-repository --repository-name "$$r" --region "$(AWS_REGION)" --force; done ; fi

# --- SageMaker training and endpoint creation ---
.PHONY: sm-train sm-create-endpoint sm-smoke-test sm-logs

# Train a model on SageMaker using the training image and data in S3
sm-train:
	@set -e; \
	ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text --region $(AWS_REGION)); \
	DATA_BUCKET=$$(terraform -chdir=infra/terraform output -raw data_bucket); \
	ART_BUCKET=$$(terraform -chdir=infra/terraform output -raw artifacts_bucket); \
	ROLE_ARN=$$(terraform -chdir=infra/terraform output -raw sagemaker_role_arn 2>/dev/null || echo ""); \
	if [ -z "$$ROLE_ARN" ]; then echo "❌ Missing ROLE_ARN from Terraform outputs"; exit 1; fi; \
	TRAIN_IMAGE="$$ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com/condor-training:latest"; \
	JOB="condor-xgb-$$(date +%Y%m%d%H%M%S)"; \
	echo "🚀 Starting SageMaker training job: $$JOB"; \
	aws sagemaker create-training-job \
	  --region "$(AWS_REGION)" \
	  --training-job-name "$$JOB" \
	  --role-arn "$$ROLE_ARN" \
	  --algorithm-specification TrainingImage="$$TRAIN_IMAGE",TrainingInputMode=File \
	  --input-data-config "$$(printf '[{"ChannelName":"train","DataSource":{"S3DataSource":{"S3Uri":"s3://%s/features/","S3DataType":"S3Prefix","S3DataDistributionType":"FullyReplicated"}}}]' $$DATA_BUCKET)" \
	  --output-data-config S3OutputPath="s3://$$ART_BUCKET/models/" \
	  --resource-config InstanceType=ml.m5.large,InstanceCount=1,VolumeSizeInGB=10 \
	  --stopping-condition MaxRuntimeInSeconds=900,MaxWaitTimeInSeconds=1800 \
	  --enable-managed-spot-training \
	  --checkpoint-config S3Uri="s3://$$ART_BUCKET/checkpoints/",LocalPath="/opt/ml/checkpoints"; \
	echo "⏳ Waiting for training job $$JOB to complete..."; \
	aws sagemaker wait training-job-completed-or-stopped --training-job-name "$$JOB" --region "$(AWS_REGION)"; \
	echo "✅ Training completed successfully!"

# Create SageMaker endpoint from the most recent training job
sm-create-endpoint:
	@set -e; \
	ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text --region $(AWS_REGION)); \
	ART_BUCKET=$$(cd infra/terraform && terraform output -raw artifacts_bucket); \
	ROLE_ARN=$$(cd infra/terraform && terraform output -raw sagemaker_role_arn 2>/dev/null || echo ""); \
	if [ -z "$$ROLE_ARN" ]; then echo "Missing ROLE_ARN from Terraform outputs"; exit 1; fi; \
	JOB=$$(aws sagemaker list-training-jobs \
	  --region "$(AWS_REGION)" \
	  --sort-by CreationTime --sort-order Descending \
	  --max-results 1 \
	  --query 'TrainingJobSummaries[0].TrainingJobName' --output text); \
	echo "Using training job: $$JOB"; \
	MODEL_DATA=$$(aws sagemaker describe-training-job \
	  --region "$(AWS_REGION)" \
	  --training-job-name "$$JOB" \
	  --query 'ModelArtifacts.S3ModelArtifacts' --output text); \
	echo "Model artifact: $$MODEL_DATA"; \
	INF_IMAGE="$$ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com/condor-inference:latest"; \
	echo "Registering model..."; \
	aws sagemaker create-model \
	  --region "$(AWS_REGION)" \
	  --model-name "$$JOB" \
	  --primary-container Image="$$INF_IMAGE",ModelDataUrl="$$MODEL_DATA",Mode=SingleModel \
	  --execution-role-arn "$$ROLE_ARN"; \
	echo "Creating endpoint config..."; \
	aws sagemaker create-endpoint-config \
	  --region "$(AWS_REGION)" \
	  --endpoint-config-name "condor-xgb-sls" \
	  --production-variants "[{\"ModelName\":\"$$JOB\",\"VariantName\":\"AllTraffic\",\"ServerlessConfig\":{\"MemorySizeInMB\":2048,\"MaxConcurrency\":1}}]"; \
	echo "Deploying endpoint..."; \
	aws sagemaker create-endpoint \
	  --region "$(AWS_REGION)" \
	  --endpoint-name "condor-xgb" \
	  --endpoint-config-name "condor-xgb-sls"; \
	echo "Waiting for endpoint to become InService (≈10min first time)..."; \
	aws sagemaker wait endpoint-in-service --endpoint-name "condor-xgb" --region "$(AWS_REGION)"; \
	echo "✅ Endpoint ready."; \
	aws sagemaker describe-endpoint --endpoint-name "condor-xgb" --region "$(AWS_REGION)" --query '{Status:EndpointStatus, Arn:EndpointArn}' --output table

# Simple local payload sanity test (requires payload.json)
sm-smoke-test:
	@set -e; \
	if [ ! -f payload.json ]; then \
	  echo '{"dte":1,"mid_dist":0.004,"wings":0.018,"atm_iv":0.13,"skew":-0.02,"rv5":0.08,"trend1d":0.001}' > payload.json; \
	  echo "Created default payload.json"; \
	fi; \
	echo "Invoking condor-xgb endpoint..."; \
	aws sagemaker-runtime invoke-endpoint \
	  --region "$(AWS_REGION)" \
	  --endpoint-name "condor-xgb" \
	  --content-type "application/json" \
	  --accept "application/json" \
	  --body fileb://payload.json out.json; \
	echo "✅ Response:"; \
	cat out.json; echo

sm-logs:
	@aws logs get-log-events \
	  --region $(AWS_REGION) \
	  --log-group-name /aws/sagemaker/Endpoints/condor-xgb \
	  --log-stream-name "$$(aws logs describe-log-streams \
	        --log-group-name /aws/sagemaker/Endpoints/condor-xgb \
	        --order-by LastEventTime \
	        --descending \
	        --query 'logStreams[0].logStreamName' \
	        --output text)" \
	  --limit 10 \
	  --query 'events[].{Time:@.timestamp,Message:@.message}' \
	  --output table

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
	@bash -lc 'set -euo pipefail; cd infra/terraform || exit 1; \
	for key in data_bucket artifacts_bucket logs_bucket; do \
	  val=$$(terraform output -raw $$key 2>/dev/null || echo ""); \
	  case "$$val" in \
	    "") echo "Skip $$key (missing)"; continue;; \
	    *[!a-z0-9.-]*) echo "Skip $$key (invalid: $$val)"; continue;; \
	  esac; \
	  echo "Checking s3://$$val ..."; \
	  if aws s3api head-bucket --bucket "$$val" --region "$(AWS_REGION)" 2>/dev/null; then \
	    echo "Emptying s3://$$val ..."; \
	    aws s3 rm "s3://$$val" --recursive --region "$(AWS_REGION)" || true; \
	  else \
	    echo "Skip $$key (head-bucket failed or access denied: $$val)"; \
	  fi; \
	done'

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

# --- Airflow commands ---
.PHONY: af-list af-errors af-render af-test af-shell af-vars af-var-set af-trigger


# EXPLANATION: list all dags in Airflow
af-list:
	docker compose -f airflow/docker-compose.yml exec airflow-apiserver airflow dags list

# EXPLANATION: list any import errors for dags in Airflow
af-errors:
	docker compose -f airflow/docker-compose.yml exec airflow-apiserver airflow dags list-import-errors || true

# EXPLANATION: render a specific task instance in Airflow
# usage: make af-render DAG=condor_ml_pipeline TASK=train DS=2025-10-26
af-render:
	docker compose -f airflow/docker-compose.yml exec airflow-apiserver airflow tasks render $(DAG) $(TASK) $(DS)

# EXPLANATION: test a specific task instance in Airflow
# usage: make af-test DAG=condor_ml_pipeline TASK=train DS=2025-10-26 - tests the "train" task of the "condor_ml_pipeline" dag for logical date 2025-10-26
af-test:
	docker compose -f airflow/docker-compose.yml exec airflow-apiserver airflow tasks test $(DAG) $(TASK) $(DS)

# EXPLANATION: trigger a DAG run in Airflow for a specific logical date (or now if not specified)
af-trigger:
	@LD=$${DS:+$${DS}T00:00:00Z}; \
	[ -n "$$LD" ] || LD=$$(date -u +%Y-%m-%dT%H:%M:%SZ); \
	echo "Triggering $(DAG) at $$LD"; \
	docker compose -f airflow/docker-compose.yml exec airflow-apiserver \
	  airflow dags trigger "$(DAG)" --logical-date "$$LD" --conf '{}'

# EXPLANATION: open a shell into the Airflow API server container
af-shell:
	docker compose -f airflow/docker-compose.yml exec airflow-apiserver bash

# EXPLANATION: set dummy Airflow Variables for local testing
af-vars:
	docker compose -f airflow/docker-compose.yml exec airflow-apiserver bash -lc '\
	airflow variables set sagemaker_role_arn "arn:aws:iam::123:role/dummy" && \
	airflow variables set training_image_uri "111.dkr.ecr.us-west-2.amazonaws.com/condor-training:latest" && \
	airflow variables set inference_image_uri "111.dkr.ecr.us-west-2.amazonaws.com/condor-inference:latest" && \
	airflow variables set data_bucket "condor-data-x" && \
	airflow variables set artifacts_bucket "condor-artifacts-x" && \
	airflow variables set ecs_cluster_arn "arn:aws:ecs:us-west-2:123:cluster/dummy" && \
	airflow variables set features_task_def_arn "arn:aws:ecs:us-west-2:123:task-definition/dummy:1" && \
	airflow variables set private_subnets "subnet-aaa,subnet-bbb" && \
	airflow variables set ecs_sg_ids "sg-xxx,sg-yyy" \
	'	

# --- Airflow: load Variables from Terraform outputs ---
.PHONY: af-vars-from-tf-min af-vars-from-tf af-vars-clear af-vars-show

# EXPLANATION: set Airflow Variables from Terraform outputs (minimal set for SageMaker training & inference)
af-vars-from-tf-min:
	@cd infra/terraform && \
	ROLE_ARN=$$(terraform output -raw sagemaker_role_arn) && \
	DATA_BUCKET=$$(terraform output -raw data_bucket) && \
	ART_BUCKET=$$(terraform output -raw artifacts_bucket) && \
	ECS_CLUSTER=$$(terraform output -raw ecs_cluster_arn) && \
	ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text --region $(AWS_REGION)) && \
	TRAIN_IMAGE="$$ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com/condor-training:latest" && \
	INF_IMAGE="$$ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com/condor-inference:latest" && \
	echo "Setting Airflow Variables from Terraform and ECR…" && \
	docker compose -f ../../airflow/docker-compose.yml exec \
	  -e ROLE_ARN="$$ROLE_ARN" \
	  -e DATA_BUCKET="$$DATA_BUCKET" \
	  -e ART_BUCKET="$$ART_BUCKET" \
	  -e ECS_CLUSTER="$$ECS_CLUSTER" \
	  -e TRAIN_IMAGE="$$TRAIN_IMAGE" \
	  -e INF_IMAGE="$$INF_IMAGE" \
	  airflow-apiserver bash -lc '\
	    airflow variables set sagemaker_role_arn "$$ROLE_ARN" && \
	    airflow variables set data_bucket "$$DATA_BUCKET" && \
	    airflow variables set artifacts_bucket "$$ART_BUCKET" && \
	    airflow variables set ecs_cluster_arn "$$ECS_CLUSTER" && \
	    airflow variables set training_image_uri "$$TRAIN_IMAGE" && \
	    airflow variables set inference_image_uri "$$INF_IMAGE" && \
	    airflow variables set private_subnets "[]" && \
	    airflow variables set ecs_sg_ids "[]" \
	  '

# EXPLANATION: set Airflow Variables from Terraform outputs (full set including networking info)
af-vars-from-tf:
	@cd infra/terraform && \
	ROLE_ARN=$$(terraform output -raw sagemaker_role_arn) && \
	DATA_BUCKET=$$(terraform output -raw data_bucket) && \
	ART_BUCKET=$$(terraform output -raw artifacts_bucket) && \
	ECS_CLUSTER=$$(terraform output -raw ecs_cluster_arn) && \
	SUBNETS_JSON=$$(terraform output -json private_subnets) && \
	SGS_JSON=$$(terraform output -json ecs_security_group_ids) && \
	FEATURES_TD=$$(terraform output -raw features_task_def_arn) && \
	ACCOUNT_ID=$$(aws sts get-caller-identity --query Account --output text --region "$(AWS_REGION)") && \
	TRAIN_IMAGE="$$ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com/condor-training:latest" && \
	INFER_IMAGE="$$ACCOUNT_ID.dkr.ecr.$(AWS_REGION).amazonaws.com/condor-inference:latest" && \
	echo "Setting Airflow Variables from Terraform and ECR…" && \
	docker compose -f ../../airflow/docker-compose.yml exec \
	  -e ROLE_ARN="$$ROLE_ARN" \
	  -e DATA_BUCKET="$$DATA_BUCKET" \
	  -e ART_BUCKET="$$ART_BUCKET" \
	  -e ECS_CLUSTER="$$ECS_CLUSTER" \
	  -e SUBNETS_JSON="$$SUBNETS_JSON" \
	  -e SGS_JSON="$$SGS_JSON" \
	  -e TRAIN_IMAGE="$$TRAIN_IMAGE" \
	  -e INFER_IMAGE="$$INFER_IMAGE" \
	  -e FEATURES_TD="$$FEATURES_TD" \
	  airflow-apiserver bash -lc '\
	    airflow variables set sagemaker_role_arn "$$ROLE_ARN" && \
	    airflow variables set data_bucket "$$DATA_BUCKET" && \
	    airflow variables set artifacts_bucket "$$ART_BUCKET" && \
	    airflow variables set ecs_cluster_arn "$$ECS_CLUSTER" && \
	    airflow variables set private_subnets "$$SUBNETS_JSON" && \
	    airflow variables set ecs_sg_ids "$$SGS_JSON" && \
	    airflow variables set training_image_uri "$$TRAIN_IMAGE" && \
	    airflow variables set inference_image_uri "$$INFER_IMAGE" && \
	    airflow variables set features_task_def_arn "$$FEATURES_TD" \
	  '

# EXPLANATION: show current Airflow Variables relevant to this project
af-vars-show:
	docker compose -f airflow/docker-compose.yml exec airflow-apiserver bash -lc '\
	  for k in sagemaker_role_arn data_bucket artifacts_bucket ecs_cluster_arn private_subnets ecs_sg_ids training_image_uri inference_image_uri features_task_def_arn; do \
	    v=$$(airflow variables get $$k 2>/dev/null || true); \
	    if [ -n "$$v" ]; then echo "$$k=$$v"; else echo "$$k=<MISSING>"; fi; \
	  done \
	'

# EXPLANATION: clear relevant Airflow Variables to start fresh
af-vars-clear:
	docker compose -f airflow/docker-compose.yml exec airflow-apiserver bash -lc '\
	  for k in sagemaker_role_arn data_bucket artifacts_bucket ecs_cluster_arn \
	           features_task_def_arn private_subnets ecs_sg_ids \
	           training_image_uri inference_image_uri; do \
	    airflow variables delete $$k || true; \
	  done \
	'