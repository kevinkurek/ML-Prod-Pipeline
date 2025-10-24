# ML Production Pipeline (Starter)

This is a **code-first** starter to deploy a minimal ML pipeline on AWS using:
- **Terraform (infra coordination)**
- **Github Actions (auto-deployment of images to ECR)**
- **Docker + ECS (Fargate first, EC2-ready)**
- **SageMaker** for training/hosting
- **MWAA (managed Airflow)** for orchestration
- **ECR, S3, CloudWatch, IAM**

## Quick Start
1. Install: Terraform, AWS CLI, Docker, Python 3.11.
2. **Login to AWS** (`aws configure`) and ensure your user has admin in a sandbox account.
3. Build & push containers to ECR:
   ```bash
   make build-push
   ```
4. Provision baseline infra (VPC, S3, ECR, ECS cluster, IAM):
   ```bash
   cd infra/terraform
   terraform init
   terraform apply -var="prefix=condor" -var="region=us-west-2"
   ```
5. Upload Airflow DAGs to the MWAA bucket (if created) or run Airflow locally (docker-compose to be added).
6. Trigger the `condor_ml_pipeline` DAG and verify the SageMaker endpoint `condor-xgb` becomes **InService**.

> Notes:
> - MWAA & SageMaker infra are partially stubbed—keep/extend as needed.
> - The **toy model** is not finance advice; it's just demo scaffolding.

## Repo Layout
```
ml-prod-pipeline/
├─ infra/terraform/    # IaC (Terraform)
├─ services/           # Dockerized services (training/inference/batch)
├─ airflow/            # MWAA DAGs and plugins
├─ sagemaker/          # Optional SageMaker pipeline/registry helpers
├─ Makefile            # Convenience targets
└─ docker-compose.yml  # Local dev (optional)
```

## Terraform commands
```bash
cd infra/terraform
terraform init

# re-format then init
terraform fmt -recursive
terraform init

# view terraform plan
terraform plan -var="prefix=condor" -var="region=us-west-2"

# apply terraform plan
terraform apply -auto-approve -var="prefix=condor" -var="region=us-west-2"


#### if you want to start from scratch

# nuke all images and repos inside ECR
for REPO in $(aws ecr describe-repositories --region "$AWS_REGION" --query 'repositories[].repositoryName' --output text); do
  echo "Deleting repo $REPO (force)..."
  aws ecr delete-repository --repository-name "$REPO" --region "$AWS_REGION" --force
done

# view destory terraform plan
terraform plan -destroy -var="prefix=condor" -var="region=us-west-2"

# actually destroy terraform resources
terraform destroy -auto-approve -var="prefix=condor" -var="region=us-west-2"



#### confirm all terraform related resources are destroyed

# VPCs (should show only default 172.31.0.0/16)
aws ec2 describe-vpcs --region "$AWS_REGION" \
  --query 'Vpcs[].CidrBlock' --output text || echo "No VPCs found"

# S3 buckets (any condor-related buckets)
[ -z "$(aws s3 ls | grep condor)" ] && echo "No condor buckets" || aws s3 ls | grep condor

# ECR repositories
[ -z "$(aws ecr describe-repositories --region "$AWS_REGION" --query 'repositories[].repositoryName' --output text)" ] \
  && echo "No ECR repos" \
  || aws ecr describe-repositories --region "$AWS_REGION" --query 'repositories[].repositoryName' --output text

# IAM roles (any containing 'condor')
[ -z "$(aws iam list-roles --query 'Roles[?contains(RoleName, `condor`)].RoleName' --output text)" ] \
  && echo "No condor IAM roles" \
  || aws iam list-roles --query 'Roles[?contains(RoleName, `condor`)].RoleName' --output text

# Optional: SageMaker endpoints (confirm no active ones remain)
[ -z "$(aws sagemaker list-endpoints --region "$AWS_REGION" --query 'Endpoints[?contains(EndpointName, `condor`)].EndpointName' --output text)" ] \
  && echo "No condor SageMaker endpoints" \
  || aws sagemaker list-endpoints --region "$AWS_REGION" --query 'Endpoints[?contains(EndpointName, `condor`)].EndpointName' --output text
```

## After terraform resources are created
```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
export AWS_PROFILE=kevin_sandbox
export AWS_REGION=us-west-2
export AWS_SDK_LOAD_CONFIG=1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo $ACCOUNT_ID
>>
    17......80

ART_BUCKET=$(terraform output -raw artifacts_bucket)
echo $ART_BUCKET
>>
   condor-artifacts-f.....

# go back to home directory
cd ../../

# Log in to your account's ECR
aws ecr get-login-password --region $AWS_REGION \
| docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com
Login Succeeded
>>
Login Succeeded

# push image to ECR
make build-push ACCOUNT_ID="${ACCOUNT_ID}" AWS_REGION="${AWS_REGION}"
```

## Streamline via Makefile
```bash
# once per shell
export AWS_PROFILE=kevin_sandbox
export AWS_REGION=us-west-2

make whoami      # confirm creds are set
make setup       # confirm local .venv is set
make bootstrap   # terraform init
make plan        # terraform plan
make apply       # terraform apply - VPC, S3, ECR, ECS, IAM
make outputs     # confirm terraform built correctly
make prep-data   # push dataset to s3
make build-push  # push train & inference images to ECR
```

## Confirm terraform & account
```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_ARN=$(aws iam get-role --role-name condor-sagemaker-exec --query Role.Arn --output text)
ART_BUCKET=$(cd infra/terraform && terraform output -raw artifacts_bucket)
DATA_BUCKET=$(cd infra/terraform && terraform output -raw data_bucket)
echo "ACCOUNT_ID=$ACCOUNT_ID
ROLE_ARN=$ROLE_ARN
ART_BUCKET=$ART_BUCKET
DATA_BUCKET=$DATA_BUCKET
AWS_REGION=$AWS_REGION"
```

## Start a SageMaker training job
```bash

# confirm data is in s3
aws s3 ls "s3://${DATA_BUCKET}/features/" --region "$AWS_REGION"

# start a training job
TRAIN_IMAGE="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/condor-training:latest"
JOB="condor-xgb-$(date +%Y%m%d%H%M%S)"

aws sagemaker create-training-job \
  --region "$AWS_REGION" \
  --training-job-name "$JOB" \
  --role-arn "$ROLE_ARN" \
  --algorithm-specification TrainingImage="$TRAIN_IMAGE",TrainingInputMode=File \
  --input-data-config "[{\"ChannelName\":\"train\",\"DataSource\":{\"S3DataSource\":{\"S3Uri\":\"s3://${DATA_BUCKET}/features/\",\"S3DataType\":\"S3Prefix\",\"S3DataDistributionType\":\"FullyReplicated\"}}}]" \
  --output-data-config S3OutputPath="s3://${ART_BUCKET}/models/" \
  --resource-config InstanceType=ml.m5.large,InstanceCount=1,VolumeSizeInGB=10 \
  --stopping-condition MaxRuntimeInSeconds=900,MaxWaitTimeInSeconds=1800 \
  --enable-managed-spot-training \
  --checkpoint-config S3Uri="s3://${ART_BUCKET}/checkpoints/",LocalPath="/opt/ml/checkpoints"

# wait for training job return status
aws sagemaker wait training-job-completed-or-stopped --training-job-name "$JOB" --region "$AWS_REGION"
```

## Debug a SageMaker training job
```bash
# Will see this inside SageMaker AI -> Training Jobs
   condor-xgb-20xxxxxxxx 10/23/2025, 12:40:44 PM

# get the log stream if you encounter a failure
aws logs describe-log-streams \
  --log-group-name /aws/sagemaker/TrainingJobs \
  --log-stream-name-prefix "$JOB" \
  --query 'logStreams[].logStreamName' --output text \
  --region "$AWS_REGION"
>>
  condor-xgb-20251023124715/algo-1-1761248879

# get the logs out of that value
aws logs get-log-events \
  --log-group-name /aws/sagemaker/TrainingJobs \
  --log-stream-name "condor-xgb-20251023124715/algo-1-1761248879" \
  --limit 200 --query 'events[].message' --output text \
  --region "$AWS_REGION"
>>
  [FATAL tini (7)] exec python failed: Exec format error
# ^ means you built your image on apple silicon but sagemaker expected linux/amd64, needed to add --platform linux/amd64 to Makefile for images being built before pushed to ECR

# confirm they're now amd64
docker inspect condor-training:latest | grep Architecture
>>
  "Architecture": "amd64",
```

## Deploying an endpoint
```bash
# Most recent training job
JOB=$(aws sagemaker list-training-jobs \
  --region "$AWS_REGION" \
  --sort-by CreationTime --sort-order Descending \
  --max-results 1 \
  --query 'TrainingJobSummaries[0].TrainingJobName' --output text)

echo "Using training job: $JOB"

# see the model artifact in s3
MODEL_DATA=$(aws sagemaker describe-training-job \
  --region "$AWS_REGION" \
  --training-job-name "$JOB" \
  --query 'ModelArtifacts.S3ModelArtifacts' --output text)

echo "MODEL_DATA=$MODEL_DATA"

# register model in sagemaker
INF_IMAGE="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/condor-inference:latest"

# you must supply the specific endpoint here to avoid sagemakers error
# Model entrypoint executable "serve" was not found in container PATH
aws sagemaker create-model \
  --region "$AWS_REGION" \
  --model-name "$JOB" \
  --primary-container Image="$INF_IMAGE",ModelDataUrl="$MODEL_DATA",Mode=SingleModel \
  --execution-role-arn "$ROLE_ARN"

# create serverless endpoint config - this is cheapest for POC
aws sagemaker create-endpoint-config \
  --region "$AWS_REGION" \
  --endpoint-config-name "condor-xgb-sls" \
  --production-variants "[{\"ModelName\":\"${JOB}\",\"VariantName\":\"AllTraffic\",\"ServerlessConfig\":{\"MemorySizeInMB\":2048,\"MaxConcurrency\":1}}]"

# create a new endpoint
aws sagemaker create-endpoint \
  --region "$AWS_REGION" \
  --endpoint-name "condor-xgb" \
  --endpoint-config-name "condor-xgb-sls"

aws sagemaker wait endpoint-in-service --endpoint-name "condor-xgb" --region "$AWS_REGION"
>>
  (This takes some time... about 10min for me first time)
  "EndpointArn": "arn:aws:sagemaker..../condor-xgb"



# OR update an existing endpoint if you have one already
aws sagemaker update-endpoint \
  --region "$AWS_REGION" \
  --endpoint-name "condor-xgb" \
  --endpoint-config-name "condor-xgb-sls"

aws sagemaker wait endpoint-in-service --endpoint-name "condor-xgb" --region "$AWS_REGION"

# SMOKE TEST the endpoint
aws sagemaker-runtime invoke-endpoint \
  --region "$AWS_REGION" \
  --endpoint-name "condor-xgb" \
  --content-type "application/json" \
  --accept "application/json" \
  --body fileb://payload.json \
  out.json && cat out.json
  >>
    {"prob_end_between":0.729040265083313,"prediction":1}% 
```

## Cleanup an endpoint
```bash
aws sagemaker delete-endpoint --endpoint-name "condor-xgb" --region "$AWS_REGION"
aws sagemaker delete-endpoint-config --endpoint-config-name "condor-xgb-sls" --region "$AWS_REGION"
aws sagemaker delete-model --model-name "$JOB" --region "$AWS_REGION"
```

## Rough billing approximation command
```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date -v1d +%Y-%m-01),End=$(date -v+1m -v1d +%Y-%m-01) \
  --granularity MONTHLY \
  --metrics "BlendedCost" \
  --region us-east-1 \
  --query 'ResultsByTime[0].Total.BlendedCost.Amount' \
  --output text
>>
  2.2969
```