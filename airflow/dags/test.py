# airflow/dags/test.py
from datetime import datetime
from airflow import DAG
from airflow.operators.empty import EmptyOperator

with DAG(
    dag_id="hello_world",
    start_date=datetime(2025, 1, 1),
    schedule=None,       # manual only
    catchup=False,
    tags=["smoke"],
) as dag:
    EmptyOperator(task_id="ping")


if __name__ == "__main__":
    dag.test()