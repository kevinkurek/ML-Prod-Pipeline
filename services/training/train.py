import os, json, boto3
import numpy as np, pandas as pd, xgboost as xgb
from sklearn.model_selection import train_test_split
from sklearn.metrics import roc_auc_score

def make_toy(n=5000, seed=7):
    rng = np.random.default_rng(seed)
    spot = rng.normal(5000, 40, n)
    dte = rng.integers(1, 7, n)
    short_put = spot - rng.uniform(20, 50, n)
    short_call = spot + rng.uniform(20, 50, n)
    mid = (short_put + short_call)/2
    mid_dist = np.abs(spot - mid)/spot
    wings = (short_call - short_put)/spot
    atm_iv = rng.uniform(0.10, 0.25, n)
    skew = rng.uniform(-0.04, 0.04, n)
    rv5 = rng.uniform(0.05, 0.20, n)
    trend1d = rng.normal(0, 0.003, n)
    logit = -3.0 + (-6.0*mid_dist) + (-2.0*wings) + (-2.0*atm_iv) + (-0.5*rv5) + (0.8*(trend1d>0))
    p = 1/(1+np.exp(-logit))
    y = (rng.uniform(0,1,n) < p).astype(int)
    X = pd.DataFrame(dict(
        dte=dte, mid_dist=mid_dist, wings=wings, atm_iv=atm_iv, skew=skew, rv5=rv5, trend1d=trend1d
    ))
    return X, y

def main():
    bucket = os.environ.get("ARTIFACTS_BUCKET", "REPLACE_ME_BUCKET")
    model_key = os.environ.get("MODEL_KEY", "models/condor_xgb.json")
    X, y = make_toy()
    Xtr, Xte, ytr, yte = train_test_split(X, y, test_size=0.2, random_state=42, stratify=y)
    dtr, dte = xgb.DMatrix(Xtr, label=ytr), xgb.DMatrix(Xte, label=yte)
    params = {"objective":"binary:logistic","eval_metric":"auc","eta":0.1,"max_depth":4}
    bst = xgb.train(params, dtr, num_boost_round=200, evals=[(dte,"valid")])
    auc = roc_auc_score(yte, (bst.predict(dte)))
    print(f"AUC={{auc:.3f}}")
    bst.save_model("model.json")
    s3 = boto3.client("s3")
    try:
        s3.upload_file("model.json", bucket, model_key)
        with open("metrics.json","w") as f: json.dump({"auc":float(auc)}, f)
        s3.upload_file("metrics.json", bucket, "metrics/latest.json")
    except Exception as e:
        print("Upload skipped or failed:", e)

if __name__ == "__main__":
    main()
