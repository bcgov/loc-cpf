import argparse
import csv
import os
import re
import time
from urllib.parse import urlparse, urljoin

import requests

ENV_URLS = {
    "local": "http://0.0.0.0:3000/api/jobs",
    "dev": "https://cpf-dev.apps.gov.bc.ca/api/jobs",
    "test": "https://cpf-test.apps.gov.bc.ca/api/jobs",
    "prod": "https://cpf.apps.gov.bc.ca/api/jobs",
}


def log(msg):
    print(time.strftime("%Y/%m/%d|%H:%M:%S|") + msg)


def is_url(value):
    return re.match(r"^(https|ftp)s?://", value or "") is not None


def detect_delimiter(path):
    return "\t" if path.lower().endswith(".tsv") else ","


parser = argparse.ArgumentParser(description="Submit and poll geocoder job.")
parser.add_argument("--env", choices=["local", "dev", "test", "prod"], default="dev", required=True, help="Target environment")
parser.add_argument("--api-token", required=True, help="API token")
parser.add_argument("--input-file", required=True, help="Local input file path OR input URL")
parser.add_argument("--output-file", default="geocoder_results.csv", help="Local output file path")
parser.add_argument("--error-file", default=None, help="Optional local error file path (defaults to <output-file>.errors.csv)")
parser.add_argument("--max-wait", type=int, default=600, help="Max wait time in seconds")
parser.add_argument("--poll-interval", type=float, default=2.0, help="Polling interval in seconds")
args = parser.parse_args()

jobs_url = ENV_URLS[args.env]
origin = f"{urlparse(jobs_url).scheme}://{urlparse(jobs_url).netloc}"

data = {
    "api_token": args.api_token,
    "endpoint_name": "Geocode",
    "options[name1]": "value1", # please update with your actual option names and values as needed
    "options[name2]": "value2",
    "options[name3]": "value3",
    "input_data_content_type": "text/tsv" if args.input_file.lower().endswith(".tsv") else "text/csv",
    "output_data_content_type": "text/tsv" if args.output_file.lower().endswith(".tsv") else "text/csv",
}

log(f"Submitting job to: {jobs_url}")

if is_url(args.input_file):
    data["input_data_url"] = args.input_file
    submit_resp = requests.post(jobs_url, data=data, timeout=60)
else:
    with open(args.input_file, "rb") as f:
        submit_resp = requests.post(jobs_url, data=data, files={"input_data_file": f}, timeout=60)

print("Submit Status Code:", submit_resp.status_code)
print("Submit Response Body:", submit_resp.text)
submit_resp.raise_for_status()

job_id = str(submit_resp.json()["id"])
job_url = f"{jobs_url}/{job_id}"

start = time.time()
job_status = None
job_payload = None

while True:
    log(f"Checking status of job {job_id} at: {job_url}")
    r = requests.get(job_url, params={"api_token": args.api_token}, timeout=30)
    r.raise_for_status()
    job_payload = r.json()
    job_status = (job_payload.get("status") or "").lower()

    if job_status in ("completed", "failed", "terminated"):
        break

    if time.time() - start > args.max_wait:
        raise TimeoutError(f"Maximum wait time ({args.max_wait}s) exceeded")

    time.sleep(max(1.0, args.poll_interval))

if job_status != "completed":
    raise RuntimeError(f"Job did not complete successfully. Final status: {job_status}")

error_message = job_payload.get("error_message")
error_url = job_payload.get("error_file_url")

if error_message:
    log(f"Job completed with warnings: {error_message}")

if error_url:
    if error_url.startswith("/"):
        error_url = urljoin(origin, error_url)

    error_file_path = args.error_file or f"{args.output_file}.errors.csv"
    log(f"Error file found. Downloading from: {error_url}")

    err_resp = requests.get(error_url, params={"api_token": args.api_token}, stream=True, timeout=120)
    err_resp.raise_for_status()

    with open(error_file_path, "wb") as ef:
        for chunk in err_resp.iter_content(chunk_size=8192):
            if chunk:
                ef.write(chunk)

    log(f"Saved error file to: {error_file_path}")

result_url = job_payload.get("output_file_url")
if not result_url:
    raise RuntimeError("Job completed but output_file_url is missing")

if result_url.startswith("/"):
    result_url = urljoin(origin, result_url)

log(f"Downloading results from: {result_url}")
download_resp = requests.get(result_url, params={"api_token": args.api_token}, stream=True, timeout=120)
download_resp.raise_for_status()

with open(args.output_file, "wb") as f:
    for chunk in download_resp.iter_content(chunk_size=8192):
        if chunk:
            f.write(chunk)

log(f"Processing results from local file: {args.output_file}")
delimiter = detect_delimiter(args.output_file)
count = 0
total_score = 0.0

with open(args.output_file, "r", newline="", encoding="utf-8-sig") as f:
    reader = csv.DictReader(f, delimiter=delimiter)
    for row in reader:
        score = row.get("score")
        if not score:
            continue
        try:
            total_score += float(score)
            count += 1
        except ValueError:
            pass

if count == 0:
    log("No numeric score rows found.")
else:
    log(f"Average Score: {total_score / count}")