# ML Production Pipeline (Starter)

This is a **code-first** starter to deploy a minimal ML pipeline on AWS using:
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

make whoami
make bootstrap
make plan
make apply
make build-push
make outputs
```

## 