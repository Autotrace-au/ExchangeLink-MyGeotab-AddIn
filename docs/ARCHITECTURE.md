# FleetBridge Architecture

## Scope

FleetBridge is a single-tenant integration for one MyGeotab database and one Microsoft 365 tenant.

Each client deployment is intended to live in that client’s own fork, Azure subscription, and Microsoft 365 tenant.

## Active Components

### MyGeotab Add-In

The Add-In runs inside MyGeotab and is responsible for:

- editing FleetBridge booking properties on assets
- saving the customer backend URL
- starting Exchange sync jobs
- polling sync job status and rendering results

### Azure Container Apps Backend

The backend runs as an Azure Functions project packaged into a custom container and hosted on Azure Container Apps.

It is responsible for:

- health reporting
- updating MyGeotab device custom properties
- queueing async sync jobs
- processing sync jobs in the background
- reading MyGeotab devices
- reconciling Exchange Online mailbox settings

### Azure Storage

Azure Storage is used for:

- Functions host storage
- queue-backed async sync jobs
- job status persistence in Table Storage

### Exchange Online

Exchange Online contains the customer equipment mailboxes and is the target system for booking configuration updates.

## Secret Model

The active deployment path uses:

- GitHub repository secrets for deployment input
- Container App secrets for runtime input

The backend no longer resolves runtime secrets from Key Vault.

## Sync Model

Sync is asynchronous.

1. The Add-In calls `POST /api/sync-to-exchange`.
2. The backend creates a job record and enqueues work.
3. A queue-triggered worker processes the job in the background.
4. The Add-In polls `GET /api/sync-status?jobId=...`.
5. Final per-device results are read from persisted job state.

This avoids browser timeouts for larger environments.
