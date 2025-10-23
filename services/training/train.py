import os, json, glob
import pandas as pd
import numpy as np
import xgboost as xgb
from sklearn.model_selection import train_test_split
from sklearn.metrics import roc_auc_score
from pathlib import Path

MODEL_DIR = Path("/opt/ml/model")
TRAIN_CHANNEL = Path("/opt/ml/input/data/train")
CHECKPOINT_DIR = Path("/opt/ml/checkpoints")

def load_or_make_data():
    # If a CSV exists in the train channel, load it; else synthesize
    csvs = sorted(glob.glob(str(TRAIN_CHANNEL / "*.csv")))
    if csvs:
        df = pd.read_csv(csvs[0])
        # expect columns: dte, mid_dist, wings, atm_iv, skew, rv5, trend1d, target
        X = df[["dte","mid_dist","wings","atm_iv","skew","rv5","trend1d"]]
        y = df["target"].astype(int)
        return X, y

    # synthesize if none found
    rng = np.random.default_rng(7)
    n = 5000
    spot = rng.normal(5000, 40, n)
    dte = rng.integers(1, 7, n)
    short_put  = spot - rng.uniform(20, 50, n)
    short_call = spot + rng.uniform(20, 50, n)
    mid = (short_put + short_call)/2
    mid_dist = np.abs(spot - mid)/spot
    wings = (short_call - short_put)/spot
    atm_iv = rng.uniform(0.10, 0.25, n)
    skew   = rng.uniform(-0.04, 0.04, n)
    rv5    = rng.uniform(0.05, 0.20, n)
    trend1d = rng.normal(0, 0.003, n)
    logit = -3.0 + (-6.0*mid_dist) + (-2.0*wings) + (-2.0*atm_iv) + (-0.5*rv5) + (0.8*(trend1d>0))
    p = 1/(1+np.exp(-logit))
    y = (rng.uniform(0,1,n) < p).astype(int)
    X = pd.DataFrame(dict(dte=dte, mid_dist=mid_dist, wings=wings,
                          atm_iv=atm_iv, skew=skew, rv5=rv5, trend1d=trend1d))
    return X, y

def main():
    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)

    X, y = load_or_make_data()
    Xtr, Xte, ytr, yte = train_test_split(X, y, test_size=0.2, random_state=42, stratify=y)
    dtr, dte = xgb.DMatrix(Xtr, label=ytr), xgb.DMatrix(Xte, label=yte)

    params = {"objective":"binary:logistic","eval_metric":"auc","eta":0.1,"max_depth":4}
    bst = xgb.train(params, dtr, num_boost_round=200, evals=[(dte,"valid")])

    auc = roc_auc_score(yte, bst.predict(dte))
    print(f"AUC={auc:.3f}")

    # Save only to /opt/ml/model — SageMaker will upload it to S3OutputPath for us
    out_path = MODEL_DIR / "model.json"
    bst.save_model(str(out_path))

    # Also drop metrics.json next to model
    with open(MODEL_DIR / "metrics.json","w") as f:
        json.dump({"auc": float(auc)}, f)

if __name__ == "__main__":
    main()