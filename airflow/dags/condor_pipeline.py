# dags/condor_ml_pipeline.py
from __future__ import annotations
from datetime import datetime
from airflow import DAG
from airflow.providers.amazon.aws.operators.sagemaker import (
    SageMakerTrainingOperator,
    SageMakerModelOperator,
    SageMakerEndpointConfigOperator,
    SageMakerEndpointOperator,
)
from airflow.providers.amazon.aws.operators.ecs import EcsRunTaskOperator
from airflow.providers.amazon.aws.sensors.sagemaker import SageMakerEndpointSensor
from airflow.providers.standard.operators.python import PythonOperator

default_args = {"owner": "ml", "retries": 0}

with DAG(
    dag_id="condor_ml_pipeline",
    start_date=datetime(2025, 10, 1),
    schedule="@daily",
    catchup=False,
    default_args=default_args,
    tags=["condor", "ml"],
) as dag:

    # 1) Build features on Fargate → write to s3://<data_bucket>/features/...
    # All config comes from Airflow Variables via Jinja, so the DAG can import even if Variables are not set yet.
    build_features = EcsRunTaskOperator(
        task_id="build_features",
        cluster="{{ var.value.ecs_cluster_arn }}",
        task_definition="{{ var.value.features_task_def_arn }}",
        launch_type="FARGATE",
        network_configuration={
            "awsvpcConfiguration": {
                "subnets": "{{ var.value.private_subnets | default('[]') | fromjson }}",
                "securityGroups": "{{ var.value.ecs_sg_ids | default('[]') | fromjson }}",
                "assignPublicIp": "DISABLED",
            }
        },
        overrides={
            # minimal stub; replace with your container name/env if needed
            # "containerOverrides": [{"name": "features", "environment": [{"name":"FOO","value":"bar"}]}]
        },
        aws_conn_id="aws_default",
    )

    # Compose TrainingJobName from execution date (unique per day), rendered by Airflow at runtime
    training_job_name = "condor-xgb-{{ ds_nodash }}"

    # 2) Train on SageMaker
    sm_train = SageMakerTrainingOperator(
        task_id="train",
        config={
            "TrainingJobName": training_job_name,
            "RoleArn": "{{ var.value.sagemaker_role_arn }}",
            "AlgorithmSpecification": {
                "TrainingImage": "{{ var.value.training_image_uri }}",
                "TrainingInputMode": "File",
            },
            "InputDataConfig": [
                {
                    "ChannelName": "train",
                    "DataSource": {
                        "S3DataSource": {
                            "S3Uri": "s3://{{ var.value.data_bucket }}/features/",
                            "S3DataType": "S3Prefix",
                            "S3DataDistributionType": "FullyReplicated",
                        }
                    },
                }
            ],
            "OutputDataConfig": {
                "S3OutputPath": "s3://{{ var.value.artifacts_bucket }}/models/"
            },
            "ResourceConfig": {
                # keep dev-cheap; bump as needed
                "InstanceType": "ml.t3.medium",
                "InstanceCount": 1,
                "VolumeSizeInGB": 10,
            },
            "StoppingCondition": {"MaxRuntimeInSeconds": 900},
            # Example if you want Spot later:
            # "EnableManagedSpotTraining": True,
            # "CheckpointConfig": {
            #     "S3Uri": "s3://{{ var.value.artifacts_bucket }}/checkpoints/",
            #     "LocalPath": "/opt/ml/checkpoints",
            # },
        },
        wait_for_completion=True,
        check_interval=30,
        aws_conn_id="aws_default",
    )

    # 2b) Describe the training job to get ModelArtifacts.S3ModelArtifacts
    def grab_model_data_url(**context):
        import boto3, os
        sm = boto3.client("sagemaker", region_name=os.getenv("AWS_REGION", "us-west-2"))
        job_name = context["templates_dict"]["job_name"]
        resp = sm.describe_training_job(TrainingJobName=job_name)
        context["ti"].xcom_push(key="model_data_url", value=resp["ModelArtifacts"]["S3ModelArtifacts"])

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
                "Image": "{{ var.value.inference_image_uri }}",
                "ModelDataUrl": "{{ ti.xcom_pull(task_ids='get_model_data', key='model_data_url') }}",
                "Mode": "SingleModel",
            },
            "ExecutionRoleArn": "{{ var.value.sagemaker_role_arn }}",
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

if __name__ == "__main__":
    dag.test()