# ML Production Pipeline

This is a **code-first** starter to deploy a minimal ML pipeline on AWS using:
- **Terraform (infra coordination)**
- **Github Actions (auto-deployment of images to ECR)**
- **Docker + ECS (Fargate first, EC2-ready)**
- **SageMaker** for training/hosting
- **MWAA (managed Airflow)** for orchestration
- **ECR, S3, CloudWatch, IAM**

## Quick Start
The Makefile has automated a ton of the build steps.
```bash
# 1. Start in project root, creates virtual env (.venv) & installs requirements
$ cd ml-prod-pipeline
$ make setup
>>
  (.venv folder now in root directory)

# 2. Run AWS configure to set up the AWS IAM user
$ aws configure
>>
  (Follow prompts)

# 3. Set up terraform resources - VPC, ECR, ECS, etc.
$ make boostrap
>> initializes terraform

$ make plan
>> shows terraform plan

$ make apply
>> applies terraform plan and deploys AWS resources

# 4. Build Docker images & push to ECR
$ make build-push
>> will see images inside AWS ECR

# 5. Create and send data to S3 buckets created by terraform
# NOTE: this step generates synthetic data to the bucket if there isn't any present so the example can run.
$ make prep-data
>>
  Uploaded 10,000 rows to s3://condor-data-xxxx/features/condor_train_20xxxxx.csv

# 6. Create a sagemaker training job from that uploaded data
$ make sm-train
>>
   🚀 Starting SageMaker training job: condor-xgb-xxx
   {
      "TrainingJobArn": "arn:aws:sagemaker:us-west-2:xxx:training-job/condor-xgb-xxx"
   }
   ⏳ Waiting for training job condor-xgb-xxx to complete...
   ✅ Training completed successfully!

# 7. Create an endpoint from that trained model - registers model, endpoint config, & deploys endpoint
$ make sm-create-endpoint
>>
   Waiting for endpoint to become InService (≈10min first time)...
   ✅ Endpoint ready.
   -------------------------------------------------------------------------------
   |                              DescribeEndpoint                               |
   +----------------------------------------------------------------+------------+
   |                               Arn                              |  Status    |
   +----------------------------------------------------------------+------------+
   |  arn:aws:sagemaker:us-west-2:xxx:endpoint/condor-xgb           |  InService |
   +----------------------------------------------------------------+------------+

# 8. Send a smoke test to the API
$ make sm-smoke-test
>>
   Invoking condor-xgb endpoint...
   {
      "ContentType": "application/json",
      "InvokedProductionVariant": "AllTraffic"
   }
   ✅ Response:
   {"prob_end_between":0.0185269583016634,"prediction":0}

# 9. View logs for API request sent
$ make sm-logs
>>
   ----------------------------------------------------------------------------------------------
   |                                        GetLogEvents                                        |
   +---------------------------------------------------------------------------+----------------+
   |                                  Message                                  |     Time       |
   +---------------------------------------------------------------------------+----------------+
   |  INFO:     Started server process [15]                                    |  1761329136964 |
   |  INFO:     Waiting for application startup.                               |  1761329136965 |
   |  INFO:     Application startup complete.                                  |  1761329136965 |
   |  INFO:     Uvicorn running on http://0.0.0.0:8080 (Press CTRL+C to quit)  |  1761329136965 |
   |  INFO:     127.0.0.1:38402 - "GET /ping HTTP/1.1" 200 OK                  |  1761329138587 |
   |  INFO:     127.0.0.1:38412 - "POST /invocations HTTP/1.1" 200 OK          |  1761329139244 |
   +---------------------------------------------------------------------------+----------------+

```

## Tear Down Everything
```bash
# Tear down everyting. 
# make down = sm-teardown empty-buckets nuke-ecr destroy
# sm-teardown - tear down all sagemaker services
# empty-buckets - clear all s3 buckets
# nuke-ecr - clear all images inside ecr
# destory - tear down all terraform resources - VPC, Subnets, NAT Gateway, IGW, ECR, S3, etc..
$ make down
>>
  Deleting SageMaker endpoint: condor-xgb
  ...
  Destroy complete! Resources: 32 destroyed.
```

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
export AWS_REGION=us-west-2
export AWS_SDK_LOAD_CONFIG=1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo $ACCOUNT_ID
>>
    1......xxx

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

## Look at API endpoint logs
```bash
# see the last 10 call logs to SageMaker Endpoint
aws logs get-log-events \
  --region us-west-2 \
  --log-group-name /aws/sagemaker/Endpoints/condor-xgb \
  --log-stream-name "$(aws logs describe-log-streams \
        --log-group-name /aws/sagemaker/Endpoints/condor-xgb \
        --order-by LastEventTime \
        --descending \
        --query 'logStreams[0].logStreamName' \
        --output text)" \
  --limit 10 \
  --query 'events[].{Time:@.timestamp,Message:@.message}' \
  --output table
>>
   ----------------------------------------------------------------------------------------------
   |                                        GetLogEvents                                        |
   +---------------------------------------------------------------------------+----------------+
   |                                  Message                                  |     Time       |
   +---------------------------------------------------------------------------+----------------+
   |  INFO:     Started server process [15]                                    |  1761329136964 |
   |  INFO:     Waiting for application startup.                               |  1761329136965 |
   |  INFO:     Application startup complete.                                  |  1761329136965 |
   |  INFO:     Uvicorn running on http://0.0.0.0:8080 (Press CTRL+C to quit)  |  1761329136965 |
   |  INFO:     127.0.0.1:38402 - "GET /ping HTTP/1.1" 200 OK                  |  1761329138587 |
   |  INFO:     127.0.0.1:38412 - "POST /invocations HTTP/1.1" 200 OK          |  1761329139244 |
   +---------------------------------------------------------------------------+----------------+
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

## Local Airflow Dev
```bash
cd airflow
docker compose up -d
```

## Confirm airflow-apiserver sees local dags
```bash

# confirm your local DAGs are there 
docker compose exec airflow-apiserver ls -la /opt/airflow/dags
>>
  test.py
  condor_pipeline.py

# confirm no upload errors in the DAG
docker compose exec airflow-apiserver airflow dags list-import-errors
>>
  "No data found" means it worked.

# list all DAGs (examples will be there too)
docker compose exec airflow-apiserver airflow dags list | grep -i condor
```