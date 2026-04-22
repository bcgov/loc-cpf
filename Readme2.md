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

## 4) Error handling (current behavior + potential improvements)

### 4.1 Current implemented behavior
- API create/destroy endpoints rescue exceptions and return `422` with error message.
- Unauthorized API access returns `401`.
- Sidekiq jobs (`GeocoderMasterSkJob`, `GeocoderWorkerSkJob`) set `retry: false` (no automatic retries).
- If master job processing fails, it is marked `success: false`.
- If worker job processing fails, it is marked `success: false`.
- If geocoder API fails for a row inside a worker job, processing continues for other rows; failed row is emitted as an empty/default output row.
- Master status becomes `failed` if any worker job is failed.

### 4.2 Potential ways to handle failures (not fully implemented yet)
- Add automatic retries with backoff for transient errors (network/geocoder/Valkey outages).
- Separate retry policies for:
  - master fan-out failures,
  - worker API call failures,
  - result merge/finalization failures.
- Add dead-letter queue or failed-job table for manual replay.
- Support partial rerun of failed worker jobs without rerunning entire master job.
- Add timeout/circuit-breaker controls around external geocoder API calls.
- Persist structured error details (error type, stack/context, retryability) for API visibility.
- Add alerting/metrics for failed jobs, retry counts, queue backlog, and processing latency.

## OpenAPI YAML

See `api_params.yaml` for full parameter and schema definitions.
