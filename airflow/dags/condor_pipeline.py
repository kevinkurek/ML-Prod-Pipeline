# dags/condor_ml_pipeline.py
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
from airflow.operators.empty import EmptyOperator

default_args = {"owner": "ml", "retries": 0}

with DAG(
    dag_id="condor_ml_pipeline",
    start_date=datetime(2025, 10, 1),
    schedule="@daily",
    catchup=False,
    default_args=default_args,
    tags=["condor", "ml"],
) as dag:

    # Expect these Airflow Variables:
    #  - ecs_cluster_arn, features_task_def_arn
    #  - private_subnets (comma-separated), ecs_sg_ids (comma-separated)
    #  - sagemaker_role_arn, training_image_uri, inference_image_uri
    #  - data_bucket, artifacts_bucket

    features_td = "{{ var.value.features_task_def_arn | default('') }}"
    if features_td:
        build_features = EcsRunTaskOperator(
            task_id="build_features",
            cluster="{{ var.value.ecs_cluster_arn }}",
            task_definition=features_td,
            launch_type="FARGATE",
            network_configuration={
                "awsvpcConfiguration": {
                    "subnets": "{{ var.value.private_subnets | default('[]') | fromjson }}",
                    "securityGroups": "{{ var.value.ecs_sg_ids | default('[]') | fromjson }}",
                    "assignPublicIp": "DISABLED",
                }
            },
            overrides={},
            aws_conn_id="aws_default",
        )
    else:
        build_features = EmptyOperator(task_id="build_features_skip")

    training_job_name = "condor-xgb-{{ ds_nodash }}"

    sm_train = SageMakerTrainingOperator(
        task_id="train",
        config={
            "TrainingJobName": training_job_name,
            "RoleArn": "{{ var.value.get('sagemaker_role_arn') }}",
            "AlgorithmSpecification": {
                "TrainingImage": "{{ var.value.get('training_image_uri') }}",
                "TrainingInputMode": "File",
            },
            "InputDataConfig": [{
                "ChannelName": "train",
                "DataSource": {"S3DataSource": {
                    "S3Uri": "s3://{{ var.value.get('data_bucket') }}/features/",
                    "S3DataType": "S3Prefix",
                    "S3DataDistributionType": "FullyReplicated",
                }},
            }],
            "OutputDataConfig": {
                "S3OutputPath": "s3://{{ var.value.get('artifacts_bucket') }}/models/"
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
                "Image": "{{ var.value.get('inference_image_uri') }}",
                "ModelDataUrl": "{{ ti.xcom_pull(task_ids='get_model_data', key='model_data_url') }}",
                "Mode": "SingleModel",
            },
            "ExecutionRoleArn": "{{ var.value.get('sagemaker_role_arn') }}",
        },
        aws_conn_id="aws_default",
    )

    create_cfg = SageMakerEndpointConfigOperator(
        task_id="create_cfg",
        config={
            "EndpointConfigName": "condor-xgb-cfg-{{ ds_nodash }}",
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
            "EndpointConfigName": "condor-xgb-cfg-{{ ds_nodash }}",
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