# UAT Instructions

## Step 1 – Obtain a BC Geocoder API Key

The new Batch Geocoder uses the same API key as the BC Geocoder service.

1. Visit the BC Government API Portal:
   - https://api.gov.bc.ca/devportal/api-directory/273

2. Request access to BC Geocoder (Public)

3. Select the Test environment

4. Submit your access request

5. Once approved, create an API Key from the API Portal

This API key will be used to authenticate all requests to the new Batch Geocoder.

## Step 2 – Prepare Your Input File

Prepare one or more test files in **CSV or TSV format**.

At a minimum, your input file must contain an `addressString` column containing the addresses to be geocoded.

### Example:

```csv
addressString
2317 MOODY AVE Kamloops, BC
APT 1 1207 Douglas St, Victoria, BC
525 Superior St, Victoria, BC
```

You may also include additional BC Geocoder API parameters as columns if you wish to test advanced geocoding options.

## Step 3 – Submit a Batch Geocoding Job

Submit your test using either:

- **Option A:** The provided `sample_client_script.py`, or
- **Option B:** Make direct API calls to the Batch Geocoder API

### Test Endpoint

```
https://geocodertst.api.gov.bc.ca/batch/jobs
```

---

### Option A: Using sample_client_script.py

The sample client script automates job submission, polling, and result download.

#### Prerequisites

1. Ensure Python 3.6+ is installed
2. Install required dependencies:

```bash
pip install requests
```

#### Running the Script

```bash
python3 sample_client_script.py \
  --env test \
  --apikey <your-api-key-from-step-1> \
  --input-file /path/to/input.csv \
  --output-file results.csv \
  --output-format csv \
  --max-wait 600
```

#### Script Parameters

- `--env` (required): Environment (`local`, `dev`, `test`, `prod`). Use `test` for UAT.
- `--apikey` (required): Your API key from Step 1.
- `--input-file` (required): Local file path or URL to your input CSV/TSV file.
- `--output-file` (optional, default: `geocoder_results.tsv`): Local file path where results will be saved.
- `--output-format` (optional, default: `tsv`): Desired output format (`csv` or `tsv`).
- `--error-file` (optional): Local file path for error records. Defaults to `<output-file>.errors.csv`.
- `--max-wait` (optional, default: `600`): Maximum time in seconds to wait for job completion.
- `--poll-interval` (optional, default: `2.0`): Time in seconds between status checks.

#### Example with TSV Output

```bash
python3 sample_client_script.py \
  --env test \
  --apikey your-api-key-here \
  --input-file addresses.tsv \
  --output-file results.tsv \
  --output-format tsv \
  --max-wait 300
```

#### Script Output

The script will:

1. Submit the job to the Batch Geocoder API
2. Poll job status every 2 seconds (or as configured)
3. Download the result file upon completion
4. Download the error file (if errors occurred)
5. Calculate and display the average score from results
6. Log all actions with timestamps

---

### Option B: Making Direct API Calls

If you prefer to make API calls directly (via `curl`, Postman, or your own client), follow these steps:

#### Step 3.1: Create a Job

Submit a `POST` request to create a batch geocoding job.

**Endpoint:**
```
POST https://geocodertst.api.gov.bc.ca/batch/jobs
```

**Authentication:**
```
Header: apikey: <your-api-key-from-step-1>
```

**Request Body (multipart/form-data):**

Required fields:
- `endpoint_name`: Must be `Geocode`
- One of:
  - `input_data_file`: Upload a file
  - `input_data_url`: Provide a URL to input data
  - `input_data`: Provide raw CSV/TSV data as text

Optional fields:
- `input_data_content_type`: `text/csv` or `text/tsv` (default: `text/csv`)
- `output_file_format`: `csv` or `tsv` (default: `csv`) – controls the output format
- `output_data_content_type`: `text/csv` or `text/tsv` (inferred from `output_file_format` if not provided)
- `options`: API parameters as an array or object

**Example with cURL (file upload):**

```bash
curl -X POST "https://geocodertst.api.gov.bc.ca/batch/jobs" \
  -H "apikey: <your-api-key>" \
  -F "endpoint_name=Geocode" \
  -F "input_data_content_type=text/csv" \
  -F "output_file_format=csv" \
  -F "input_data_file=@/path/to/input.csv"
```

**Success Response (201 Created):**

```json
{
  "id": "123",
  "status": "pending",
  "created_at": "2023-01-01 12:00:00",
  "total_rows": null,
  "total_worker_jobs": null,
  "completed_worker_jobs": null,
  "input_file_url": "/rails/active_storage/blobs/...",
  "output_file_url": null,
  "error_file_url": null,
  "error_message": null,
  "options": [],
  "output_file_format": "csv"
}
```

**Save the job `id`** for the next steps.

---

#### Step 3.2: Check Job Status

Poll the job status until completion.

**Endpoint:**
```
GET https://geocodertst.api.gov.bc.ca/batch/jobs/{id}?apikey=<your-api-key>
```

**Example with cURL:**

```bash
curl -X GET "https://geocodertst.api.gov.bc.ca/batch/jobs/123?apikey=<your-api-key>"
```

**Response:**

```json
{
  "id": "123",
  "status": "in_progress",
  "created_at": "2023-01-01 12:00:00",
  "total_rows": 100,
  "total_worker_jobs": 1,
  "completed_worker_jobs": 0,
  "input_file_url": "/rails/active_storage/blobs/...",
  "output_file_url": null,
  "error_file_url": null,
  "error_message": null,
  "options": [],
  "output_file_format": "csv"
}
```

**Possible Status Values:**
- `submitted`: Job has been accepted
- `scheduled`: Job is queued for processing
- `in_progress`: Job is currently being processed
- `finalizing`: Job is preparing output files
- `completed`: Job finished successfully (may have partial failures – check `error_message`)
- `failed`: Job failed fatally
- `terminated`: Job was cancelled

**Repeat this request every 2-5 seconds until `status` is `completed`, `failed`, or `terminated`.**

---

#### Step 3.3: Download Results

Once the job status is `completed`, download the output file.

**Endpoint:**
```
GET {output_file_url}?apikey=<your-api-key>
```

Extract `output_file_url` from the job status response and include your API key as a query parameter.

**Example with cURL:**

```bash
curl -X GET "https://example.com/rails/active_storage/blobs/...?apikey=<your-api-key>" \
  -o results.csv
```

---

#### Step 3.4: Download Error File (if applicable)

If the job completed with errors, an `error_file_url` will be present in the response.

**Example with cURL:**

```bash
curl -X GET "https://example.com/rails/active_storage/blobs/...?apikey=<your-api-key>" \
  -o errors.csv
```

The error file contains records that failed geocoding with columns:
- `sequenceNumber`: Row identifier
- `yourId`: User-supplied ID
- `addressString`: The input address
- `errorMessage`: Reason for failure

---

## Step 4 – Review the Results

After the job completes:

1. Download the output file
2. Review the geocoding results
3. If an error file is generated, review any records that failed processing
4. Verify that the output meets your business expectations
5. If desired, compare the results with those produced by the current (existing) CPF to identify any differences

Please report any issues, unexpected behaviour, or discrepancies discovered during testing.

## UAT Feedback

When evaluating the new Batch Geocoder, please consider the following:

- Were you able to obtain an API key successfully?
- Was the documentation sufficient to complete testing?
- Did your input files process successfully?
- Were the geocoding results as expected?
- What differences did you notice compared with your current geocoding service or process??
- Were there any performance, usability, or compatibility issues?
- Do you have any suggestions for improvements before production release?

Your feedback is important and will help ensure a successful production deployment.