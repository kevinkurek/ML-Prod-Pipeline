#!/usr/bin/env python3
import argparse, os, io, sys, time
import pandas as pd
import numpy as np
import boto3

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
    df = pd.DataFrame(dict(
        dte=dte, mid_dist=mid_dist, wings=wings, atm_iv=atm_iv,
        skew=skew, rv5=rv5, trend1d=trend1d, target=y
    ))
    return df

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bucket", required=True)
    ap.add_argument("--prefix", default="features/")
    ap.add_argument("--local_csv", default="synthetic_condor.csv",
                    help="existing small CSV to include if present (optional)")
    ap.add_argument("--min_rows", type=int, default=10000)
    ap.add_argument("--region", default=os.getenv("AWS_REGION", "us-west-2"))
    args = ap.parse_args()

    # load local CSV if exists
    if os.path.exists(args.local_csv):
        base = pd.read_csv(args.local_csv)
    else:
        base = pd.DataFrame(columns=["dte","mid_dist","wings","atm_iv","skew","rv5","trend1d","target"])

    need = max(0, args.min_rows - len(base))
    if need > 0:
        synth = make_synth(need)
        df = pd.concat([base, synth], ignore_index=True)
    else:
        df = base

    # ensure both classes exist
    if "target" not in df or df["target"].nunique() < 2:
        extra = make_synth(max(1000, int(0.1*args.min_rows)))
        df = pd.concat([df, extra], ignore_index=True)

    # shuffle rows for good measure
    df = df.sample(frac=1.0, random_state=42).reset_index(drop=True)

    # upload
    key = f"{args.prefix.rstrip('/')}/condor_train_{time.strftime('%Y%m%d_%H%M%S')}.csv"
    buf = io.BytesIO()
    df.to_csv(buf, index=False)
    buf.seek(0)

    s3 = boto3.client("s3", region_name=args.region)
    s3.upload_fileobj(buf, args.bucket, key)

    print(f"Uploaded {len(df):,} rows to s3://{args.bucket}/{key}")

if __name__ == "__main__":
    main()