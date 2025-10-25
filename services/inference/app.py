from fastapi import FastAPI, Request, HTTPException
import os
import json
import numpy as np
import pandas as pd
import xgboost as xgb
from typing import List, Dict, Any, Union

app = FastAPI(title="Condor XGB Inference")
_model = None

# The columns and order the model expects
FEATURES = ["dte", "mid_dist", "wings", "atm_iv", "skew", "rv5", "trend1d"]

def _model_path() -> str:
    """
    Where SageMaker places model artifacts:
      - Hosting automatically untars model.tar.gz into /opt/ml/model/
      - If you saved a plain file (e.g., model.json), load it from there.
    Override with MODEL_PATH if needed.
    """
    return os.environ.get("MODEL_PATH", "/opt/ml/model/model.json")

def load_model():
    global _model
    if _model is None:
        path = _model_path()
        if not os.path.exists(path):
            # Optional fallback: allow downloading if you really want to,
            # but not needed in SageMaker Hosting (artifacts are mounted).
            art_bucket = os.environ.get("ARTIFACTS_BUCKET")
            model_key = os.environ.get("MODEL_KEY")
            if not (art_bucket and model_key):
                raise FileNotFoundError(
                    f"Model not found at {path} and ARTIFACTS_BUCKET/MODEL_KEY not set."
                )
            import boto3
            boto3.client("s3").download_file(art_bucket, model_key, path)

        booster = xgb.Booster()
        booster.load_model(path)
        _model = booster
    return _model

def _ensure_dataframe(payload: Union[Dict[str, Any], List[Dict[str, Any]]]) -> pd.DataFrame:
    """
    Accepts:
      - a single JSON object with feature keys
      - a list of such objects
      - {"instances": [...]} (common pattern)
    Returns a DataFrame with the expected FEATURE columns in order.
    """
    if isinstance(payload, dict) and "instances" in payload:
        rows = payload["instances"]
    elif isinstance(payload, list):
        rows = payload
    elif isinstance(payload, dict):
        rows = [payload]
    else:
        raise HTTPException(status_code=400, detail="Unsupported payload format")

    # Validate required keys and order columns
    for i, row in enumerate(rows):
        missing = [c for c in FEATURES if c not in row]
        if missing:
            raise HTTPException(
                status_code=400,
                detail=f"Row {i} missing required features: {missing}"
            )

    df = pd.DataFrame([{k: r[k] for k in FEATURES} for r in rows], columns=FEATURES)
    return df

@app.get("/ping")
def ping():
    # load on first health check; if it fails, SM will mark container unhealthy
    load_model()
    return {"status": "ok"}

@app.post("/invocations")
async def invocations(request: Request):
    try:
        payload = await request.json()
    except Exception:
        # If someone posts text/csv etc., reject clearly
        raise HTTPException(status_code=415, detail="Content-Type must be application/json")

    df = _ensure_dataframe(payload)
    booster = load_model()
    dm = xgb.DMatrix(df)

    probs = booster.predict(dm)
    # Normalize to 1D numpy array
    probs = np.array(probs).reshape(-1)
    preds = (probs >= 0.5).astype(int)

    results = [
        {"prob_end_between": float(p), "prediction": int(y)}
        for p, y in zip(probs, preds)
    ]

    # Return single dict if single-row input for convenience
    return results[0] if isinstance(payload, dict) and "instances" not in payload else results

# Keep your original route if you want a custom endpoint too
@app.post("/predict")
def predict(payload: Dict[str, Any]):
    df = _ensure_dataframe(payload)
    booster = load_model()
    dm = xgb.DMatrix(df)
    p = float(np.array(booster.predict(dm)).reshape(-1)[0])
    return {"prob_end_between": p, "prediction": int(p >= 0.5)}