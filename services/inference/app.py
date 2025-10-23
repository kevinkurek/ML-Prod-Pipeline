from fastapi import FastAPI
import xgboost as xgb, numpy as np, os, boto3, json, pandas as pd

app = FastAPI()
_model = None

def load_model():
    global _model
    if _model is None:
        path = os.environ.get("MODEL_PATH","model.json")
        if not os.path.exists(path):
            s3 = boto3.client("s3")
            s3.download_file(os.environ["ARTIFACTS_BUCKET"], os.environ["MODEL_KEY"], path)
        _model = xgb.Booster(); _model.load_model(path)
    return _model

@app.post("/predict")
def predict(payload: dict):
    m = load_model()
    cols = ["dte","mid_dist","wings","atm_iv","skew","rv5","trend1d"]
    X = pd.DataFrame([{k: payload[k] for k in cols}])
    p = float(m.predict(xgb.DMatrix(X))[0])
    return {"p_inside": p, "label": int(p>=0.5)}
