# dags/condor_ml_pipeline.py
from __future__ import annotations
from datetime import datetime
from airflow import DAG
from airflow.models import Variable
from airflow.providers.amazon.aws.operators.sagemaker import (
    SageMakerTrainingOperator,
    SageMakerModelOperator,
    SageMakerEndpointConfigOperator,
    SageMakerEndpointOperator,
)
from airflow.providers.amazon.aws.operators.ecs import EcsRunTaskOperator
from airflow.providers.amazon.aws.sensors.sagemaker import SageMakerEndpointSensor
from airflow.operators.python import PythonOperator

# ----- Airflow Variables (fail fast if missing) -----
ecs_cluster_arn = Variable.get("ecs_cluster_arn")
features_task_def_arn = Variable.get("features_task_def_arn")
private_subnets = Variable.get("private_subnets")  # JSON string -> use fromjson in template
ecs_sg_ids = Variable.get("ecs_sg_ids")            # JSON string -> use fromjson in template

sagemaker_role_arn = Variable.get("sagemaker_role_arn")
training_image_uri = Variable.get("training_image_uri")
inference_image_uri = Variable.get("inference_image_uri")
data_bucket = Variable.get("data_bucket")
artifacts_bucket = Variable.get("artifacts_bucket")

default_args = {
    "owner": "ml",
    "retries": 0,
}

with DAG(
    dag_id="condor_ml_pipeline",
    start_date=datetime(2025, 10, 1),
    schedule="@daily",
    catchup=False,
    default_args=default_args,
    tags=["condor", "ml"],
) as dag:

    # 1) Build features on Fargate → write to s3://<data_bucket>/features/...
    build_features = EcsRunTaskOperator(
        task_id="build_features",
        cluster=ecs_cluster_arn,
        task_definition=features_task_def_arn,
        launch_type="FARGATE",
        network_configuration={
            "awsvpcConfiguration": {
                # NOTE: store these Airflow Variables as JSON arrays and parse with fromjson
                "subnets": "{{ var.value.private_subnets | fromjson }}",
                "securityGroups": "{{ var.value.ecs_sg_ids | fromjson }}",
                "assignPublicIp": "DISABLED",
            }
        },
        aws_conn_id="aws_default",
    )

    # Compose TrainingJobName from execution date (unique per day)
    # Airflow will render {{ ds_nodash }} to YYYYMMDD
    training_job_name = "condor-xgb-{{ ds_nodash }}"

    # 2) Train on SageMaker
    sm_train = SageMakerTrainingOperator(
        task_id="train",
        config={
            "TrainingJobName": training_job_name,
            "RoleArn": sagemaker_role_arn,
            "AlgorithmSpecification": {
                "TrainingImage": training_image_uri,
                "TrainingInputMode": "File",
            },
            "InputDataConfig": [
                {
                    "ChannelName": "train",
                    "DataSource": {
                        "S3DataSource": {
                            "S3Uri": f"s3://{data_bucket}/features/",
                            "S3DataType": "S3Prefix",
                            "S3DataDistributionType": "FullyReplicated",
                        }
                    },
                }
            ],
            "OutputDataConfig": {"S3OutputPath": f"s3://{artifacts_bucket}/models/"},
            "ResourceConfig": {
                # keep dev-cheap; bump as needed
                "InstanceType": "ml.t3.medium",
                "InstanceCount": 1,
                "VolumeSizeInGB": 10,
            },
            "StoppingCondition": {"MaxRuntimeInSeconds": 900},
            # Add Spot if you like (ensure role perms incl. checkpoint S3)
            # "EnableManagedSpotTraining": True,
            # "CheckpointConfig": {
            #     "S3Uri": f"s3://{artifacts_bucket}/checkpoints/",
            #     "LocalPath": "/opt/ml/checkpoints",
            # },
        },
        wait_for_completion=True,  # block until the training job ends
        check_interval=30,
        aws_conn_id="aws_default",
    )

    # 2b) Resolve ModelDataUrl reliably by describing the training job
    def grab_model_data_url(**context):
        import boto3
        ti = context["ti"]
        job_name = context["templates_dict"]["job_name"]
        sm = boto3.client("sagemaker")
        resp = sm.describe_training_job(TrainingJobName=job_name)
        model_s3 = resp["ModelArtifacts"]["S3ModelArtifacts"]
        ti.xcom_push(key="model_data_url", value=model_s3)

    get_model_data = PythonOperator(
        task_id="get_model_data",
        python_callable=grab_model_data_url,
        templates_dict={"job_name": training_job_name},
    )

    # 3) Register a Model using inference image + artifact
    create_model = SageMakerModelOperator(
        task_id="create_model",
        config={
            "ModelName": training_job_name,  # tie model name to training job date
            "PrimaryContainer": {
                "Image": inference_image_uri,
                "ModelDataUrl": "{{ ti.xcom_pull(task_ids='get_model_data', key='model_data_url') }}",
                "Mode": "SingleModel",
            },
            "ExecutionRoleArn": sagemaker_role_arn,
        },
        aws_conn_id="aws_default",
    )

    # 4) Serverless endpoint config (cheapest for POC)
    create_cfg = SageMakerEndpointConfigOperator(
        task_id="create_cfg",
        config={
            "EndpointConfigName": "condor-xgb-cfg-{{ ds_nodash }}",
            "ProductionVariants": [
                {
                    "ModelName": training_job_name,
                    "VariantName": "AllTraffic",
                    "ServerlessConfig": {"MemorySizeInMB": 2048, "MaxConcurrency": 1},
                }
            ],
        },
        aws_conn_id="aws_default",
    )

    # 5) Deploy endpoint (create or update "condor-xgb")
    deploy = SageMakerEndpointOperator(
        task_id="deploy",
        config={
            "EndpointName": "condor-xgb",
            "EndpointConfigName": "condor-xgb-cfg-{{ ds_nodash }}",
        },
        wait_for_completion=True,
        check_interval=30,
        aws_conn_id="aws_default",
    )

    # 6) Health check
    health = SageMakerEndpointSensor(
        task_id="healthcheck",
        endpoint_name="condor-xgb",
        poke_interval=30,
        timeout=1800,
        aws_conn_id="aws_default",
    )

    build_features >> sm_train >> get_model_data >> create_model >> create_cfg >> deploy >> health