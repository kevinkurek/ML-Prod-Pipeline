#!/usr/bin/env python3
"""
Quick load / latency warm-up script for a SageMaker real-time (serverless or non-serverless) endpoint.
Sends N JSON inference requests and prints basic stats so CloudWatch ModelLatency metrics appear faster.

Usage examples:
  python tools/load_test_endpoint.py --endpoint condor-xgb --region us-west-2 --count 200 --concurrency 20

Notes:
- Keep total request volume modest (a few hundred) to avoid unnecessary cost.
- For reproducibility the base payload can be fixed; use --randomize to vary features slightly.
- Requires AWS credentials in environment or AWS_PROFILE configured.
- ModelLatency in CloudWatch can lag a few minutes even after requests are sent.
"""
import argparse, json, os, random, time, statistics
from concurrent.futures import ThreadPoolExecutor, as_completed
import boto3

BASE_PAYLOAD = {
    "dte": 1,
    "mid_dist": 0.004,
    "wings": 0.018,
    "atm_iv": 0.13,
    "skew": -0.02,
    "rv5": 0.08,
    "trend1d": 0.001,
}

def make_payload(randomize: bool) -> dict:
    if not randomize:
        return BASE_PAYLOAD
    # Small perturbations within plausible ranges
    p = dict(BASE_PAYLOAD)
    p["dte"] = random.randint(1, 7)
    p["mid_dist"] = round(random.uniform(0.002, 0.010), 6)
    p["wings"] = round(random.uniform(0.010, 0.040), 6)
    p["atm_iv"] = round(random.uniform(0.10, 0.25), 5)
    p["skew"] = round(random.uniform(-0.04, 0.04), 5)
    p["rv5"] = round(random.uniform(0.05, 0.20), 5)
    p["trend1d"] = round(random.uniform(-0.005, 0.005), 6)
    return p


def invoke(client, endpoint: str, payload: dict) -> float:
    start = time.time()
    body = json.dumps(payload).encode("utf-8")
    resp = client.invoke_endpoint(
        EndpointName=endpoint,
        ContentType="application/json",
        Accept="application/json",
        Body=body,
    )
    # Optionally parse response to ensure it's valid
    _ = resp["Body"].read()
    return time.time() - start


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", required=True, help="SageMaker endpoint name")
    ap.add_argument("--region", required=True, help="AWS region")
    ap.add_argument("--count", type=int, default=100, help="Total requests to send")
    ap.add_argument("--concurrency", type=int, default=10, help="Parallel threads")
    ap.add_argument("--randomize", action="store_true", help="Randomize payload values per request")
    ap.add_argument("--profile", default=os.environ.get("AWS_PROFILE"), help="AWS profile (optional if env creds present)")
    args = ap.parse_args()

    session_kwargs = {}
    if args.profile:
        session_kwargs["profile_name"] = args.profile
    session = boto3.Session(**session_kwargs)
    client = session.client("sagemaker-runtime", region_name=args.region)

    print(f"Sending {args.count} requests to endpoint '{args.endpoint}' (region={args.region}, concurrency={args.concurrency})")
    latencies = []
    errors = 0

    with ThreadPoolExecutor(max_workers=args.concurrency) as ex:
        futures = [ex.submit(invoke, client, args.endpoint, make_payload(args.randomize)) for _ in range(args.count)]
        for fut in as_completed(futures):
            try:
                lat = fut.result()
                latencies.append(lat)
            except Exception as e:
                errors += 1
                print(f"Error: {e}")

    if latencies:
        p50 = statistics.median(latencies)
        p95 = statistics.quantiles(latencies, n=100)[94] if len(latencies) >= 20 else max(latencies)
        avg = statistics.mean(latencies)
        print("--- Summary ---")
        print(f"Requests: {len(latencies)} success / {errors} errors")
        print(f"Latency avg={avg*1000:.1f}ms p50={p50*1000:.1f}ms p95={p95*1000:.1f}ms max={max(latencies)*1000:.1f}ms")
    else:
        print("All requests failed.")

    print("NOTE: CloudWatch metrics (ModelLatency) may appear after a short delay.")

if __name__ == "__main__":
    main()
