# LOC-CPF API and Processing Guide

This document explains user flow, app configuration, work processing logic, and current error handling for LOC-CPF.

## 1) User logic (SSO, token, API usage)

Authentication for jobs endpoints:
- Dev/test/prod: provide Kong consumer API key as `apikey` in the request header or query parameter.
  - The app assumes Kong has already authenticated and authorized the request before it reaches the app.
- Local: provide `api_token` as a request parameter, or provide `HTTP_X_USERINFO` header for internal auth flow.

### 1.1 Browser access for the app
- Dev/test/prod: browser access is protected by Kong + Keycloak SSO, and the app receives user info from Kong.
- Local: browser access uses a dummy admin user.

### 1.2 Create API token (local only)
Token creation is only for local testing and is done in the browser.

1. Open the local app:
   - `http://0.0.0.0:3000`
2. Visit: `http://0.0.0.0:3000/users/tokens`
3. Click **Create token** and copy the generated token value.
4. Optionally set an expiry date.

> Token management (viewing and revoking existing tokens) is available only in local development.

### 1.3 Submit jobs and fetch results using API token
Jobs API base paths:
- `http://0.0.0.0:3000/api/` (local)

### 1.4 Access through API Gateway (Kong consumer apikey)
On Dev, Test and Prod, users can access the Batch Geocoder using the consumer apikey for Geocoder.
You can either use an existing Geocoder apikey or get a new one by:

1. Apply Geocoder access in the API Gateway
2. Create a new apikey

Job API base paths:
- `https://geocoderdlv.api.gov.bc.ca/batch/` (dev)
- `https://geocodertst.api.gov.bc.ca/batch/` (test)
- `https://geocoder.api.gov.bc.ca/batch/` (prod)

#### Create a job
`POST /batch/jobs` on dev/test/prod, or `POST /api/jobs` locally

Required fields:
- `apikey` for dev/test/prod
- `api_token` for local
- `endpoint_name` (currently `Geocode`)
- One input source:
  - `input_data_file` (file upload), or
  - `input_data_url` (URL), or
  - `input_data` (raw CSV/TSV text)

Optional fields:
- `output_file_format` (`csv` or `tsv`, default: `csv`)

Example:
```bash
curl -X POST "0.0.0.0:3000/api/jobs" \
  -H "apikey: <apikey>" \
  -F "endpoint_name=Geocode" \
  -F "input_data_content_type=text/tsv" \
  -F "output_file_format=tsv" \
  -F "output_data_content_type=text/tsv" \
  -F "input_data_file=@/path/to/input.tsv"
```

Create response:
```json
{ "id": 123 }
```

#### Check job status
`GET /batch/jobs/:id?apikey=<apikey>` on dev/test/prod, or `GET /api/jobs/:id?api_token=<api_token>` locally

Example:
```bash
curl "https://geocoderdlv.api.gov.bc.ca/batch/jobs/18?apikey=<apikey>"
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
  "options": [],
  "output_file_format": "tsv"
}
```

#### List jobs
`GET /batch/jobs?apikey=<apikey>&page=1&page_size=25` on dev/test/prod, or `GET /api/jobs?api_token=<api_token>&page=1&page_size=25` locally

#### Download output file
Use `output_file_url` from the job payload.
If the URL is relative, prepend the correct host and include `apikey` or `api_token` when requesting.

## Final I/O Format

### Input Files

Two input formats are supported: **unstructured** and **structured**.

#### Unstructured Format

The unstructured format contains a single column named `addressString`, which stores address values.

Example:

```csv
addressString
"2317 MOODY AVE Kamloops, BC"
"APT 1 1207 Douglas St, Victoria, BC"
"525 Superior St, Victoria,BC"
"4251A ROCKBANK PL, WEST VANCOUVER,BC"
```

Quotation marks are optional. If quotation marks are used, they must be applied consistently to every data row.

---

#### Structured Format

The structured format includes additional columns.

Required fields:
- `addressString`
- `yourId`

Example:

```csv
yourId,addressString
A23E4,"2317 MOODY AVE Kamloops, BC"
BXe33,"APT 1 1207 Douglas St, Victoria, BC"
```

Additional columns are allowed only if the column name matches one of the **System Default Arguments** listed below.
Columns not in that allowlist are rejected to prevent unexpected argument injection.

---

### Additional Geocoder API Arguments

API arguments are applied in the following order:

1. System default arguments
2. Request-specified API options (allowlist only)
3. Arguments defined in the input data file (column names, allowlist only)

If duplicate parameters exist, later values override earlier ones.
Any request or input-data argument not present in the System Default Arguments allowlist must be rejected.

#### System Default Arguments

```yaml
outputFormat: "json"
addressString: ""
locationDescriptor: "any"
maxResults: 1
interpolation: "adaptive"
echo: "true"
brief: "false"
autoComplete: "false"
exactSpelling: "false"
fuzzyMatch: "false"
setBack: 0
outputSRS: 4326
minScore: 1
matchPrecision: ""
matchPrecisionNot: ""
siteName: ""
unitDesignator: "--"
unitNumber: ""
unitNumberSuffix: ""
civicNumber: ""
civicNumberSuffix: ""
streetName: ""
streetType: ""
streetDirection: "--"
streetQualifier: ""
localityName: ""
provinceCode: "BC"
localities: ""
notLocalities: ""
bbox: ""
centre: ""
maxDistance: ""
extrapolate: "--"
parcelPoint: ""
```

---

### Output File

The output file includes the following fields when available:

- `yourId` (if specified)
- `sequenceNumber` (auto-generated row number)
- `executionTime`
- `faults` (if present)

The output may also contain other fields returned by the Geocoder API.

#### Possible Output Fields

```yaml
- sequenceNumber
- resultNumber
- yourId
- fullAddress
- intersectionName
- score
- matchPrecision
- precisionPoints
- faults
- siteName
- unitDesignator
- unitNumber
- unitNumberSuffix
- civicNumber
- civicNumberSuffix
- streetName
- streetType
- isStreetTypePrefix
- streetDirection
- isStreetDirectionPrefix
- streetQualifier
- localityName
- localityType
- electoralArea
- provinceCode
- location
- locationPositionalAccuracy
- locationDescriptor
- siteID
- blockID
- intersectionID
- fullSiteDescriptor
- accessNotes
- siteStatus
- siteRetireDate
- changeDate
- isOfficial
- degree
- executionTime
- sid
```

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

### 2.4 Common Hosted Email Service (CHES)

Results-ready email is sent through CHES API using:

- `CHES_CLIENT_ID` (required)
- `CHES_CLIENT_SECRET` (required)
- `CHES_API_URL` (optional, default: `https://ches.api.gov.bc.ca/api/v1/email`)

Sender is fixed to:

- `example@gov.bc.ca`

Method added:

- `ApplicationMailer.send_results_ready_email!(destination_address:, body:)`

Example (Rails console):

```ruby
ApplicationMailer.send_results_ready_email!(
  destination_address: "client@example.com",
  body: "Your LOC-CPF results are ready for download."
)
```

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
   - writes one combined final output file (`CSV` or `TSV` based on `output_file_format`),
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
- The row is still written to the worker output file to preserve input order.
- For failed rows:
  - `score` is set to `0`
  - geocoder-derived result fields are left empty
  - input-related fields (for example sequence/id/address columns) are kept
- The same row is also written to the worker job's `error_file` (CSV format) with columns:
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
export CHES_CLIENT_ID=client_id
export CHES_CLIENT_SECRET=client_secret

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
  --apikey <your-api-key> \
  --input-file example.tsv \
  --output-file results.tsv \
  --output-format tsv \
  --max-wait 120
```

The script will:
1. Submit the job to the local API (`http://0.0.0.0:3000/api/jobs`).
2. Poll job status until completion.
3. Download the result file and print average score.
4. If errors occur, download and save the error file.


### Initial deployment

1. If needed, create MySQL credentials in a secret named `mysql-credentials`. Example:

```yaml
kind: Secret
apiVersion: v1
metadata:
  name: mysql-credentials
  namespace: NAMESPACE
data:
  mysql-password: BASE64_ENCODED_PASSWORD
  mysql-root-password: ''
type: Opaque
```

2. Open a MySQL terminal in OpenShift:

```bash
mysql -uroot
```

3. Create `cpf-user`, grant privileges, and create the database:

```sql
CREATE USER 'cpf-user'@'%' IDENTIFIED BY 'THE PASSWORD';
GRANT ALL PRIVILEGES ON *.* TO 'cpf-user'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
CREATE DATABASE `cpf-database`;
```

4. Verify environment variables are correct.  
   For example, ensure the MySQL service name matches the ArgoCD/Helm chart project name.

### Failover Plan
The system is not expected to be HA 24/7 service. We allow some interruption such as cluster failure to happen. However, after the interruption the service should be self healing: 

1. All apps and components should self heal to the state before the failure automatically (system level)

2. All submitted jobs should retry and completes (application/data level). 

3. Partially submitted jobs will be ignored

4. We only do short database backup (~15 min). So if a job is submitted within the database backup period, it may be lost if the database disk fails and not recoverable (unlikely to happen)

5. A Reconciler CronJob runs periodically to scan MySQL for jobs in non-terminal states (for example: submitted, scheduled, in_progress, finalizing). It compares database state with Redis/Valkey queue state and detects interrupted or missing enqueued work.
If a job is recoverable, the reconciler re-enqueues missing master/worker jobs. If a job exceeds timeout or retry limits, it is marked failed with a clear error_message.

6. The reconciler also handles long-running stale jobs by stopping/re-enqueuing them when safe and idempotent.
If required artifacts are missing (for example input/output files in SeaweedFS, or required job metadata in MySQL), the job is treated as non-recoverable and marked failed gracefully.

7. New. Users should not submit any jobs to the Gold DR cluster. When the Gold DR is currently active, any request (API or web) will get a response saying the service is current down please come back later. (so we don’t need to sync the jobs)