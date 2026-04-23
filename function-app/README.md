# Backend

This directory contains the Azure Functions backend that runs inside the Azure Container App.

## Files

- [`function_app.py`](function_app.py): HTTP endpoints, queue worker, job tracking, and MyGeotab/Exchange orchestration
- [`exchange_sync.ps1`](exchange_sync.ps1): PowerShell worker that talks to Exchange Online
- [`Dockerfile`](Dockerfile): custom runtime image with Python, PowerShell, and Exchange modules
- [`requirements.txt`](requirements.txt): Python dependencies
- [`host.json`](host.json): Azure Functions host config
- [`local.settings.example.json`](local.settings.example.json): local development environment template

## Current API surface

- `GET /api/health`: health and runtime configuration summary
- `POST /api/update-device-properties`: write normalized ExchangeLink custom properties back to a MyGeotab device
- `POST /api/sync-to-exchange`: queue an async sync job
- `GET /api/sync-status?jobId=...`: read async job state and results

All HTTP endpoints currently allow anonymous access and include permissive CORS headers.

## Runtime behavior

The backend currently:

- authenticates to MyGeotab using a service account
- reads devices and their custom properties
- normalizes ExchangeLink booking settings into a stable internal shape
- writes selected property updates back to MyGeotab
- batches device sync work and invokes PowerShell for Exchange updates
- stores job status in Azure Table Storage
- stores queued jobs in Azure Queue Storage

Async jobs use:

- queue: `fleetbridge-sync-jobs`
- table: `FleetBridgeSyncJobs`

## Required runtime configuration

Secret values:

- `AzureWebJobsStorage`
- `MYGEOTAB_DATABASE`
- `MYGEOTAB_USERNAME`
- `MYGEOTAB_PASSWORD`
- `EXCHANGE_CERTIFICATE`
- `EXCHANGE_CERTIFICATE_PASSWORD`

Non-secret values:

- `MYGEOTAB_SERVER`
- `EXCHANGE_TENANT_ID`
- `EXCHANGE_CLIENT_ID`
- `EXCHANGE_ORGANIZATION`
- `EQUIPMENT_DOMAIN`
- `DEFAULT_TIMEZONE`
- `MAKE_MAILBOX_VISIBLE_ON_FIRST_SYNC`
- `SYNC_MAX_WORKERS`
- `SYNC_BATCH_SIZE`

## Local development

The repo does not include a full local one-command emulator workflow, but you can still validate code paths locally.

Basic syntax check:

```bash
python -m py_compile function-app/function_app.py
```

To prepare a local settings file:

```bash
cp function-app/local.settings.example.json function-app/local.settings.json
```

You will need valid MyGeotab credentials, Exchange app settings, and local Azure Storage or an equivalent storage connection string to exercise the full runtime locally.

## Why the folder is still named `function-app`

The application is still an Azure Functions project even though the production host is Azure Container Apps rather than the traditional Functions hosting model.
