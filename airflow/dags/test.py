# airflow/dags/test.py
from datetime import datetime
from airflow import DAG
from airflow.providers.standard.operators.python import PythonOperator

def say_hello(ds: str):
    print("👋 Hello from inside Airflow!")
    print("Execution date (ds):", ds)
    return "Hello world!"

def show_context(**context):
    for k, v in context.items():
        print(f"{k}: {v}")
    return "done"

with DAG(
    dag_id="hello_world",
    start_date=datetime(2025, 1, 1),
    schedule=None,       # manual trigger only
    catchup=False,
    tags=["smoke"],
) as dag:
    hello_task = PythonOperator(
        task_id="print_hello",
        python_callable=say_hello,
        op_kwargs={"ds": "{{ ds }}"},  # inject templated ds
    )

    context_task = PythonOperator(
        task_id="show_context",
        python_callable=show_context,
    )

    hello_task >> context_task

if __name__ == "__main__":
    dag.test()