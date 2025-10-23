import os, json, boto3, pandas as pd

def main():
    runtime = boto3.client('sagemaker-runtime')
    endpoint = os.environ.get("SM_ENDPOINT","condor-xgb")
    # Example batch
    rows = [{
        "dte":1,"mid_dist":0.004,"wings":0.018,"atm_iv":0.13,"skew":-0.02,"rv5":0.08,"trend1d":0.001
    }]
    payload = json.dumps(rows[0])
    resp = runtime.invoke_endpoint(EndpointName=endpoint, ContentType="application/json", Body=payload)
    print(resp['Body'].read().decode())

if __name__ == "__main__":
    main()
