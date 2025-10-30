# dags/condor_pipeline.py
from __future__ import annotations
from datetime import datetime
from airflow import DAG
from airflow.providers.amazon.aws.operators.sagemaker import (
    SageMakerTrainingOperator, SageMakerModelOperator,
    SageMakerEndpointConfigOperator, SageMakerEndpointOperator,
)
from airflow.providers.amazon.aws.operators.ecs import EcsRunTaskOperator
from airflow.providers.amazon.aws.sensors.sagemaker import SageMakerEndpointSensor
from airflow.providers.standard.operators.python import PythonOperator
from airflow.providers.standard.operators.empty import EmptyOperator
import json
from airflow.models import Variable

default_args = {"owner": "ml", "retries": 0}

with DAG(
    dag_id="condor_ml_pipeline",
    start_date=datetime(2025, 10, 1),
    schedule="@daily",
    catchup=False,
    default_args=default_args,
    tags=["condor", "ml"],
) as dag:

    # Parse-time lookups (safe defaults)
    features_td = Variable.get("features_task_def_arn", default_var="")
    subnets = json.loads(Variable.get("private_subnets", default_var="[]"))
    sgs = json.loads(Variable.get("ecs_sg_ids", default_var="[]"))
    ROLE_ARN = Variable.get("sagemaker_role_arn")
    TRAIN_IMG = Variable.get("training_image_uri")
    INFER_IMG = Variable.get("inference_image_uri")
    DATA_BUCKET = Variable.get("data_bucket")
    ART_BUCKET = Variable.get("artifacts_bucket")

    if features_td:
        build_features = EcsRunTaskOperator(
            task_id="build_features",
            cluster=Variable.get("ecs_cluster_arn"),
            task_definition=features_td,
            launch_type="FARGATE",
            network_configuration={
                "awsvpcConfiguration": {
                    "subnets": subnets,
                    "securityGroups": sgs,
                    "assignPublicIp": "DISABLED",
                }
            },
            overrides={},
            aws_conn_id="aws_default",
        )
    else:
        build_features = EmptyOperator(task_id="build_features_skip")

    training_job_name = "condor-xgb-{{ ds }}"

    sm_train = SageMakerTrainingOperator(
        task_id="train",
        config={
            "TrainingJobName": training_job_name,
            "RoleArn": ROLE_ARN,
            "AlgorithmSpecification": {
                "TrainingImage": TRAIN_IMG,
                "TrainingInputMode": "File",
            },
            "InputDataConfig": [{
                "ChannelName": "train",
                "DataSource": {"S3DataSource": {
                    "S3Uri": f"s3://{DATA_BUCKET}/features/",
                    "S3DataType": "S3Prefix",
                    "S3DataDistributionType": "FullyReplicated",
                }},
            }],
            "OutputDataConfig": {
                "S3OutputPath": f"s3://{ART_BUCKET}/models/"
            },
            "ResourceConfig": {
                "InstanceType": "ml.m5.large",
                "InstanceCount": 1,
                "VolumeSizeInGB": 10,
            },
            "StoppingCondition": {"MaxRuntimeInSeconds": 900},
        },
        wait_for_completion=True,
        check_interval=30,
        aws_conn_id="aws_default",
    )

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

    create_model = SageMakerModelOperator(
        task_id="create_model",
        config={
            "ModelName": training_job_name,
            "PrimaryContainer": {
                "Image": INFER_IMG,
                "ModelDataUrl": "{{ ti.xcom_pull(task_ids='get_model_data', key='model_data_url') }}",
                "Mode": "SingleModel",
            },
            "ExecutionRoleArn": ROLE_ARN,
        },
        aws_conn_id="aws_default",
    )

    create_cfg = SageMakerEndpointConfigOperator(
        task_id="create_cfg",
        config={
            "EndpointConfigName": "condor-xgb-cfg-{{ ds }}",
            "ProductionVariants": [{
                "ModelName": training_job_name,
                "VariantName": "AllTraffic",
                "ServerlessConfig": {"MemorySizeInMB": 2048, "MaxConcurrency": 1},
            }],
        },
        aws_conn_id="aws_default",
    )

    deploy = SageMakerEndpointOperator(
        task_id="deploy",
        config={
            "EndpointName": "condor-xgb",
            "EndpointConfigName": "condor-xgb-cfg-{{ ds }}",
        },
        wait_for_completion=True,
        check_interval=30,
        aws_conn_id="aws_default",
    )

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