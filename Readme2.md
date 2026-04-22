# LOC-CPF API Usage Guide

This document explains how to use the LOC-CPF app APIs.

## 1) Login with SSO

1. Open the app in your browser:
   - `https://cpf-dev.apps.gov.bc.ca` (dev)
2. Complete SSO login.
3. After login, your user session is active.

## 2) Create API token

With an active SSO session, create a token from:
- UI/API route: `POST /users/tokens`
- Token list route: `GET /users/tokens`
- Revoke route: `DELETE /users/tokens/:id`

### Example (create token)
```bash
curl -X POST "https://cpf-dev.apps.gov.bc.ca/users/tokens.json" \
  -H "Accept: application/json" \
  -H "Cookie: <your_sso_session_cookie>"
```

Response example:
```json
{
  "id": 1,
  "value": "<api_token>",
  "expired_at": null,
  "created_at": "2026-04-22T18:00:00.000Z"
}
```

> Note: token management endpoints require an authenticated SSO session.

## 3) Submit jobs and fetch results using API token

Jobs API base path:
- `/api/jobs`

Authentication for jobs endpoints:
- Provide `api_token` as a request parameter.

### Create a job

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

### Check job status

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

### List jobs

`GET /api/jobs?api_token=<api_token>&page=1&page_size=25`

### Download output file

Use `output_file_url` from the job payload.
If the URL is relative, prepend app host and include `api_token` when requesting.

## OpenAPI YAML

See `api_params.yaml` for a full parameter and schema definition.
