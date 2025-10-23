from datetime import datetime
from airflow import DAG
from airflow.providers.amazon.aws.operators.sagemaker import (
    SageMakerTrainingOperator, SageMakerModelOperator, SageMakerEndpointConfigOperator, SageMakerEndpointOperator
)
from airflow.providers.amazon.aws.sensors.sagemaker import SageMakerEndpointSensor
from airflow.providers.amazon.aws.operators.ecs import EcsRunTaskOperator

default_args = {"owner":"ml","retries":0}

with DAG(
    dag_id="condor_ml_pipeline",
    start_date=datetime(2025,10,1),
    schedule="@daily",
    catchup=False,
    default_args=default_args,
    tags=["condor","ml"],
):
    build_features = EcsRunTaskOperator(
        task_id="build_features",
        cluster="{{ var.value.ecs_cluster_arn }}",
        task_definition="{{ var.value.features_task_def_arn }}",
        launch_type="FARGATE",
        network_configuration={
            "awsvpcConfiguration":{
                "subnets":"{{ var.value.private_subnets }}".split(","),
                "securityGroups":"{{ var.value.ecs_sg_id }}".split(","),
                "assignPublicIp":"DISABLED"
            }
        }
    )

    sm_train = SageMakerTrainingOperator(
        task_id="train",
        config={
          "TrainingJobName": "condor-xgb-{{ ds_nodash }}",
          "RoleArn": "{{ var.value.sagemaker_role_arn }}",
          "AlgorithmSpecification": {"TrainingImage": "{{ var.value.training_image_uri }}","TrainingInputMode":"File"},
          "InputDataConfig": [{
            "ChannelName":"train",
            "DataSource":{"S3DataSource":{"S3Uri":"s3://{{ var.value.data_bucket }}/features/","S3DataType":"S3Prefix","S3DataDistributionType":"FullyReplicated"}}
          }],
          "OutputDataConfig":{"S3OutputPath":"s3://{{ var.value.artifacts_bucket }}/models/"},
          "ResourceConfig":{"InstanceType":"ml.m5.xlarge","InstanceCount":1,"VolumeSizeInGB":30},
          "StoppingCondition":{"MaxRuntimeInSeconds":3600}
        },
        aws_conn_id="aws_default"
    )

    create_model = SageMakerModelOperator(
        task_id="create_model",
        config={
            "ModelName":"condor-xgb-{{ ds_nodash }}",
            "PrimaryContainer":{
                "Image":"{{ var.value.inference_image_uri }}",
                "ModelDataUrl":"{{ task_instance.xcom_pull('train','Return')['ModelArtifacts']['S3ModelArtifacts'] }}"
            },
            "ExecutionRoleArn":"{{ var.value.sagemaker_role_arn }}"
        }
    )

    create_cfg = SageMakerEndpointConfigOperator(
        task_id="create_cfg",
        config={
            "EndpointConfigName":"condor-xgb-cfg-{{ ds_nodash }}",
            "ProductionVariants":[{"ModelName":"condor-xgb-{{ ds_nodash }}","VariantName":"AllTraffic","InitialInstanceCount":1,"InstanceType":"ml.m5.large"}]
        }
    )

    deploy = SageMakerEndpointOperator(
        task_id="deploy",
        config={"EndpointName":"condor-xgb","EndpointConfigName":"condor-xgb-cfg-{{ ds_nodash }}"},
        wait_for_completion=True
    )

    health = SageMakerEndpointSensor(
        task_id="healthcheck", endpoint_name="condor-xgb", poke_interval=30, timeout=1800
    )

    build_features >> sm_train >> create_model >> create_cfg >> deploy >> health
