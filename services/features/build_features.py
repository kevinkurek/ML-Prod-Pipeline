#!/usr/bin/env python3
import os, io, time
import numpy as np
import pandas as pd
import boto3

# ---------- config via env (set these in ECS task or Airflow overrides) ----------
AWS_REGION  = os.getenv("AWS_REGION", "us-west-2")
DATA_BUCKET = os.getenv("DATA_BUCKET")              # REQUIRED
OUT_PREFIX  = os.getenv("OUT_PREFIX", "features/")  # matches SageMaker input
MIN_ROWS    = int(os.getenv("MIN_ROWS", "11000"))
LOCAL_CSV   = os.getenv("LOCAL_CSV", "synthetic_condor.csv")

if not DATA_BUCKET:
    raise SystemExit("DATA_BUCKET not set (export it in ECS task env).")

# ---------- same synth logic as prep-data ----------
def make_synth(n, seed=7):
    rng = np.random.default_rng(seed)
    spot = rng.normal(5000, 40, n)
    dte = rng.integers(1, 8, n)
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
    return pd.DataFrame(dict(
        dte=dte, mid_dist=mid_dist, wings=wings, atm_iv=atm_iv,
        skew=skew, rv5=rv5, trend1d=trend1d, target=y
    ))

def main():
    # seed with optional local file for continuity
    if os.path.exists(LOCAL_CSV):
        base = pd.read_csv(LOCAL_CSV)
    else:
        base = pd.DataFrame(columns=["dte","mid_dist","wings","atm_iv","skew","rv5","trend1d","target"])

    need = max(0, MIN_ROWS - len(base))
    df = pd.concat([base, make_synth(need) if need > 0 else base.iloc[0:0]], ignore_index=True) if need > 0 else base

    # ensure both classes exist
    if "target" not in df or df["target"].nunique() < 2:
        df = pd.concat([df, make_synth(max(1000, int(0.1*MIN_ROWS)))], ignore_index=True)

    df = df.sample(frac=1.0, random_state=42).reset_index(drop=True)

    # write CSV to the same prefix SageMaker reads
    key = f"{OUT_PREFIX.rstrip('/')}/condor_train_{time.strftime('%Y%m%d_%H%M%S')}.csv"
    buf = io.BytesIO()
    df.to_csv(buf, index=False)
    buf.seek(0)

    s3 = boto3.client("s3", region_name=AWS_REGION)
    s3.upload_fileobj(buf, DATA_BUCKET, key)
    print(f"Uploaded {len(df):,} rows to s3://{DATA_BUCKET}/{key}")

if __name__ == "__main__":
    main()