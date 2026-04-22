# LOC-CPF API and Processing Guide

This document explains user flow, app configuration, work processing logic, and current error handling for LOC-CPF.

## 1) User logic (SSO, token, API usage)

### 1.1 Login with SSO
1. Open the app in your browser:
   - `https://cpf-dev.apps.gov.bc.ca` (dev)
2. Complete SSO login.
3. After login, your user session is active.

### 1.2 Create API token (browser only)
Token creation requires an authenticated SSO session and must be done in the browser.
**API creation of tokens is not supported.**

1. After SSO login, visit: `https://cpf-dev.apps.gov.bc.ca/users/tokens`
2. Click **Create token** and copy the generated token value.
3. Optionally set an expiry date.

> Token management (viewing and revoking existing tokens) is also available at the same URL.

### 1.3 Submit jobs and fetch results using API token
Jobs API base path:
- `/api/jobs`

Authentication for jobs endpoints:
- Provide `api_token` as a request parameter, or
- provide `HTTP_X_USERINFO` header (Kong user info) for internal auth flow.

#### Create a job
`POST /api/jobs`

Required fields:
- `api_token`
- `endpoint_name` (currently `Geocode`)
- One input source:
  - `input_data_file` (file upload), or
  - `input_data_url` (URL), or
  - `input_data` (raw CSV/TSV text)

Example:
```bash
curl -X POST "https://cpf-dev.apps.gov.bc.ca/api/jobs" \
  -F "api_token=<api_token>" \
  -F "endpoint_name=Geocode" \
  -F "input_data_content_type=text/csv" \
  -F "output_data_content_type=text/csv" \
  -F "input_data_file=@/path/to/input.csv"
```

Create response:
```json
{ "id": 123 }
```

#### Check job status
`GET /api/jobs/:id?api_token=<api_token>`

Example:
```bash
curl "https://cpf-dev.apps.gov.bc.ca/api/jobs/123?api_token=<api_token>"
```

Response contains status and output URL when ready:
```json
{
  "id": 123,
  "status": "completed",
  "created_at": "2026-04-22 18:05:00",
  "total_rows": 100,
  "total_worker_jobs": 1,
  "completed_worker_jobs": 1,
  "input_file_url": "/rails/active_storage/blobs/...",
  "output_file_url": "/rails/active_storage/blobs/...",
  "error_file_url": null,
  "error_message": null,
  "options": []
}
```

#### List jobs
`GET /api/jobs?api_token=<api_token>&page=1&page_size=25`

#### Download output file
Use `output_file_url` from the job payload.
If the URL is relative, prepend app host and include `api_token` when requesting.

## 2) App configurations

### 2.1 MySQL database
Database config is in `config/database.yml`:
- Adapter: `mysql2`
- Host: `DB_HOST` (default `127.0.0.1`)
- Production password: `DATABASE_PASSWORD`

Main connection options:
- `DATABASE_URL` can be used to override/merge Rails DB settings.
- Development DB defaults to:
  - database: `cpf-database-dev`
  - username: `root`
- Production DB defaults to:
  - database: `cpf-database`
  - username: `cpf-user`

### 2.2 SeaweedFS object storage (Active Storage S3-compatible)
File storage config is in `config/storage.yml`.

Local SeaweedFS setup uses Active Storage `local` service with S3-compatible endpoint:
- `endpoint: http://localhost:8333`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_S3_BUCKET`
- `force_path_style: true`

OpenShift/remote setup uses Active Storage `ocp` service:
- `endpoint: ENV["AWS_S3_ENDPOINT"]`
- same AWS-style credentials/bucket env vars as above.

Environment-specific behavior:
- Development: `config.active_storage.service = :local`
- Production: `config.active_storage.service = :ocp`

### 2.3 Valkey in-memory queue service (Redis protocol)
Sidekiq is configured in `config/initializers/sidekiq.rb`:
- `REDIS_URL` controls queue backend URL.
- default: `redis://localhost:6379/0`

This Redis-compatible endpoint can be Valkey.

Queue config:
- `config/sidekiq.yml` defines queues and weights:
  - `geocoder_master_sk_job`
  - `geocoder_worker_sk_job`
  - `default`
- Worker concurrency is set in Sidekiq config (`:concurrency: 5`).

## 3) Work logic (master job -> worker jobs -> joined result)

1. User submits `POST /api/jobs` with endpoint `Geocode` and input data.
2. `Api::JobsController#create` validates request, creates `GeocoderMasterJob`, attaches input file, saves API options/content-type, and enqueues the master Sidekiq job.
3. `GeocoderMasterSkJob` executes:
   - marks master job started,
   - streams and reads the input CSV/TSV from Active Storage,
   - splits rows into chunks using `worker_options.max_worker_row_count` from `config/cpf_config.yaml`,
   - creates one `GeocoderWorkerJob` per chunk and attaches chunk file,
   - enqueues each worker job,
   - marks master job completed for fan-out step with `total_jobs` and `total_rows`.
4. Each `GeocoderWorkerSkJob` executes:
   - reads its chunk file,
   - builds request parameters from endpoint defaults + job options + row values,
   - calls BC Address Geocoder API (`addresses.json`),
   - writes normalized output rows,
   - attaches worker output CSV to Active Storage,
   - marks worker job complete and increments `master_job.completed_jobs`.
5. After each worker completes, master `generate_result_file` checks completion:
   - when `completed_jobs == total_jobs`, it merges worker output files (ordered by worker id),
   - writes one combined final output CSV,
   - attaches final output file to the master job.
6. Client polls `GET /api/jobs/:id` until status is `completed`, then downloads `output_file_url`.

Typical statuses observed from model logic:
- `submitted`, `scheduled`, `in_progress`, `finalizing`, `completed`, `failed`, `terminated`

## 4) Error handling

### 4.1 Master job errors (fatal job-level failures)

If the master job fails during:
- input file parsing (CSV/TSV structure error),
- worker job creation (database write failure),
- transaction rollback,

Then:
- Master job is marked `success: false` with `completed_at` set.
- `error_message` is populated with a short error description (truncated to 255 chars).
- No worker jobs are created or enqueued (transaction rollback).
- Status becomes `failed`.
- API response includes the error message in `error_message` field.

### 4.2 Worker job errors (two-tier: fatal or row-level)

#### Fatal worker job errors (cannot parse chunk file or crash before row processing)
If a worker job fails to:
- read or parse its input chunk file,
- contact the app or database,

Then:
- Worker job is marked `success: false` with `completed_at` set.
- `error_message` is set to describe the failure.
- No output file is attached.
- Master job status eventually becomes `failed` (because a worker is failed).

#### Row-level worker errors (individual geocoder API failures or bad row data)
If a row within a worker job fails to:
- pass validation (missing required fields),
- get a geocoding result from the Geocoder API,
- parse API response,

Then:
- The specific row is NOT written to the output file.
- Instead, it is written to the worker job's `error_file` (CSV format) with columns:
  - `sequenceNumber` (row identifier)
  - `yourId` (user-supplied ID)
  - `addressString` (the input address that failed)
  - `errorMessage` (reason for failure)
- Worker job continues processing remaining rows.
- Worker job is marked `success: true` (partial success) with `error_message` describing the count of failed rows.
- Worker job's `completed_jobs` counter is incremented normally.

### 4.3 Master result generation and error file merging

After all workers complete:
1. Master merges all worker output files into one final `output_file`.
2. Master checks if any worker has a non-empty `error_file`.
3. If worker error files exist:
   - Master merges all worker error files into one master `error_file` (same CSV format).
   - Master sets `error_message` to indicate total count of failed rows across all workers.
   - Master status becomes `completed` (despite partial failures).
4. If no worker error files exist:
   - Master `error_file` is purged.
   - Master `error_message` is cleared.
   - Master status becomes `completed` (fully successful).

### 4.4 API response with errors

Job status response includes:
```json
{
  "id": 123,
  "status": "completed",
  "error_message": "Completed with 5 failed rows",
  "error_file_url": "/rails/active_storage/blobs/...",
  "output_file_url": "/rails/active_storage/blobs/...",
  ...
}
```

or on fatal master/worker failure:
```json
{
  "id": 123,
  "status": "failed",
  "error_message": "master_failed: CSV parse error at line 10",
  ...
}
```

Clients should:
- Check `status` to determine overall completion.
- If `status == "completed"` and `error_message` is present, download both `output_file_url` and `error_file_url` to see successful and failed rows separately.
- If `status == "failed"`, check `error_message` for the reason and retry if appropriate.

### 4.5 Job retry policy

- Sidekiq jobs have `retry: false` (no automatic retries).
- Transient failures (network hiccups, temporary database unavailability) will cause the job to be marked as failed immediately.
- Users can manually resubmit the same job after addressing the underlying issue (e.g., service recovery, geocoder API availability).
- Failed row retries (within a job) are not supported; users must resubmit the entire job to retry all rows.

## OpenAPI YAML

See `api_params.yaml` for full parameter and schema definitions.

## 5) Local development quick start

### 5.1 Start SeaweedFS (S3-compatible object storage)

```bash
export AWS_ACCESS_KEY_ID=local_test_key_id
export AWS_SECRET_ACCESS_KEY=local_test_secret
export AWS_S3_BUCKET=cpf

./seaweedfs/weed mini -dir=./seaweedfs/data
# S3 Endpoint: http://localhost:8333
```

### 5.2 Start Valkey (Redis-compatible queue backend)

```bash
# Start
brew services start valkey

# Check status
brew services info valkey

# Stop
brew services stop valkey
```

### 5.3 Start Sidekiq worker

```bash
bundle exec sidekiq
```

Sidekiq will connect to `redis://localhost:6379/0` by default and process jobs from the configured queues.

### 5.4 Submit a test job

```bash
python3 sample_client_script.py \
  --env local \
  --api-token <your-api-token> \
  --input-file example.csv \
  --output-file results.csv \
  --max-wait 120
```

The script will:
1. Submit the job to the local API (`http://0.0.0.0:3000/api/jobs`).
2. Poll job status until completion.
3. Download the result file and print average score.
4. If errors occur, download and save the error file.
