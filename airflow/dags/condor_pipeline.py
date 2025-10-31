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
from botocore.exceptions import ClientError

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
    FEATURES_ARN = Variable.get("features_task_def_arn", default_var="")
    SUBNETS = json.loads(Variable.get("private_subnets", default_var="[]"))
    SG_IDS = json.loads(Variable.get("ecs_sg_ids", default_var="[]"))
    ROLE_ARN = Variable.get("sagemaker_role_arn")
    TRAIN_IMG = Variable.get("training_image_uri")
    INFER_IMG = Variable.get("inference_image_uri")
    DATA_BUCKET = Variable.get("data_bucket")
    ART_BUCKET = Variable.get("artifacts_bucket")

    # EXPLANATION: ECS task to build features dataset and upload to S3
    if FEATURES_ARN:
        build_features = EcsRunTaskOperator(
            task_id="build_features",
            cluster=Variable.get("ecs_cluster_arn"),
            task_definition=FEATURES_ARN,
            launch_type="FARGATE",
            network_configuration={
                "awsvpcConfiguration": {
                    "subnets": SUBNETS,
                    "securityGroups": SG_IDS,
                    "assignPublicIp": "DISABLED",
                }
            },
            overrides={},
            aws_conn_id="aws_default",
        )
    else:
        build_features = EmptyOperator(task_id="build_features_skip")

    training_job_name = "condor-xgb-{{ ts_nodash }}"

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

    # EXPLANATION: custom PythonOperator to grab the S3 URL of trained model artifacts from completed training job
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

    # EXPLANATION: manual retrieve the S3 URL of the trained model artifacts from the completed training job
    # create_model = SageMakerModelOperator(
    #     task_id="create_model",
    #     config={
    #         "ModelName": training_job_name,
    #         "PrimaryContainer": {
    #             "Image": INFER_IMG,
    #             "ModelDataUrl": "{{ ti.xcom_pull(task_ids='get_model_data', key='model_data_url') }}",
    #             "Mode": "SingleModel",
    #         },
    #         "ExecutionRoleArn": ROLE_ARN,
    #     },
    #     aws_conn_id="aws_default",
    # )

    # EXPLANATION: register the trained model into SageMaker Model Registry and pick the latest Approved version
    def register_and_pick_model(**ctx):
        import boto3, os
        sm = boto3.client("sagemaker", region_name=os.getenv("AWS_REGION","us-west-2"))
        group = "condor-xgb"

        # idempotent: create or ignore if exists
        try:
            sm.create_model_package_group(ModelPackageGroupName=group)
        except ClientError as e:
            code = e.response.get("Error", {}).get("Code")
            msg  = e.response.get("Error", {}).get("Message", "")
            if not (code == "ValidationException" and "already exists" in msg):
                raise

        # get model data from prior task
        model_data = ctx["ti"].xcom_pull(task_ids="get_model_data", key="model_data_url")

        # register this training output
        pkg = sm.create_model_package(
            ModelPackageGroupName=group,
            InferenceSpecification={"Containers":[{"Image": INFER_IMG, "ModelDataUrl": model_data}]},
            ModelApprovalStatus="Approved",  # or "PendingManualApproval"
        )
        this_pkg_arn = pkg["ModelPackageArn"]

        # pick latest Approved (fallback to this one)
        resp = sm.list_model_packages(
            ModelPackageGroupName=group,
            ModelApprovalStatus="Approved",
            SortBy="CreationTime", SortOrder="Descending", MaxResults=1,
        )
        latest = resp["ModelPackageSummaryList"][0]["ModelPackageArn"] if resp.get("ModelPackageSummaryList") else this_pkg_arn

        ctx["ti"].xcom_push(key="model_package_arn", value=this_pkg_arn)
        ctx["ti"].xcom_push(key="approved_pkg_arn", value=latest)

    register_model = PythonOperator(task_id="register_model", python_callable=register_and_pick_model)

    create_model = SageMakerModelOperator(
    task_id="create_model",
    config={
        "ModelName": training_job_name,
        "Containers": [ { "ModelPackageName": "{{ ti.xcom_pull('register_model', key='approved_pkg_arn') }}" } ],
        "ExecutionRoleArn": ROLE_ARN,
    },
    aws_conn_id="aws_default",
    )

    create_cfg = SageMakerEndpointConfigOperator(
        task_id="create_cfg",
        config={
            "EndpointConfigName": "condor-xgb-cfg-{{ ts_nodash }}",
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
            "EndpointConfigName": "condor-xgb-cfg-{{ ts_nodash }}",
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

    # EXPLANATION: define task dependencies for simple workflow
    # build_features >> sm_train >> get_model_data >> create_model >> create_cfg >> deploy >> health

    # EXPLANATION: define task dependencies for auto-promotion workflow
    build_features >> sm_train >> get_model_data >> register_model >> create_model >> create_cfg >> deploy >> health


if __name__ == "__main__":
    dag.test()