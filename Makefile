# ---- Config (override at runtime: make apply AWS_REGION=us-west-2 PREFIX=condor) ----
AWS_REGION ?= us-west-2
PREFIX ?= condor

# Do not export AWS_PROFILE globally; CI does not have this profile.
# export AWS_PROFILE
export AWS_REGION
export AWS_DEFAULT_REGION=$(AWS_REGION)
export AWS_SDK_LOAD_CONFIG=1

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
	docker build --platform linux/amd64 -t condor-training:latest services/training --load
	docker build --platform linux/amd64 -t condor-inference:latest services/inference --load

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