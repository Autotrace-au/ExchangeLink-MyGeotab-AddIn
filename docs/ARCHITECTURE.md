# ExchangeLink Architecture

## Scope

ExchangeLink is designed for a single MyGeotab database and a single Microsoft 365 tenant per deployment. Each deployment is expected to live in its own GitHub repo or fork, Azure subscription, and Microsoft 365 tenant boundary.

The add-in is shared source. The backend is tenant-specific.

## System components

### MyGeotab add-in

The add-in runs inside MyGeotab and is the operator-facing UI. Its current responsibilities are:

- presenting the ExchangeLink property and asset management UI
- persisting the backend URL through MyGeotab add-in storage with browser fallback
- loading and saving the tenant-wide automatic sync schedule from the backend
- reading and editing ExchangeLink booking-related custom properties
- calling backend APIs for property updates and Exchange sync
- polling async sync jobs and rendering progress and results

### Azure backend

The backend is an Azure Functions app packaged into a custom container and hosted on Azure Container Apps. The implementation lives in [`function-app/function_app.py`](../function-app/function_app.py).

Current HTTP surface:

- `GET /api/health`
- `POST /api/update-device-properties`
- `POST /api/sync-to-exchange`
- `GET /api/sync-schedule`
- `PUT /api/sync-schedule`
- `GET /api/sync-status?jobId=...`

Current worker surface:

- Azure Storage queue trigger for background sync processing
- Azure Container Apps scheduled job for unattended sync evaluation

### Azure Storage

Azure Storage is part of the runtime, not just deployment plumbing.

- Blob/host storage backs the Azure Functions host
- Queue storage holds async sync jobs
- Table storage persists job status and result summaries
- Table storage persists the tenant-wide auto-sync schedule

The queue name is `fleetbridge-sync-jobs`. The table name is `FleetBridgeSyncJobs`.
The schedule table name is `FleetBridgeSyncConfig`.

### Exchange Online

Exchange Online is the target system for booking policy updates. ExchangeLink assumes the equipment mailboxes already exist and uses the device serial to derive mailbox identity.

Current mailbox assumptions:

- mailbox alias and SMTP local part match the MyGeotab serial
- display name is updated from the MyGeotab vehicle name
- mailbox creation is manual
- first successful sync may make hidden mailboxes visible

## Sync flow

The current sync path is asynchronous by design.

1. The add-in calls `POST /api/sync-to-exchange`.
2. The backend creates a job record in Table Storage.
3. The backend writes a message to the Azure Storage queue.
4. A queue-triggered function loads devices from MyGeotab.
5. Devices are batched and processed through `exchange_sync.ps1`.
6. Progress is merged back into Table Storage as items complete.
7. The add-in polls `GET /api/sync-status`.
8. Final results are returned from stored job state.

This avoids long-running browser requests and allows progress reporting for larger fleets.

## Automatic sync flow

Auto-sync is backend-owned so it keeps working after the operator closes the add-in.

1. The add-in loads and saves the schedule through `GET/PUT /api/sync-schedule`.
2. The backend stores the authoritative schedule in Azure Table Storage.
3. An Azure Container Apps scheduled job wakes up on a fixed UTC heartbeat.
4. The scheduled job evaluates the saved tenant-local schedule and checks for due work.
5. If no other sync is active, it enqueues the same async sync path used by manual runs.
6. Scheduled run metadata is written back to the schedule record for cross-device recall in the add-in.

## MyGeotab property model

The backend currently maps these ExchangeLink properties:

- `Enable Equipment Booking` -> `bookable`
- `Allow Recurring Bookings` -> `recurring`
- `Booking Approvers` -> `approvers`
- `Fleet Managers` -> `fleetManagers`
- `Allow Double Booking` -> `conflicts`
- `Booking Window (Days)` -> `windowDays`
- `Maximum Booking Duration (Hours)` -> `maxDurationHours`
- `Mailbox Language` -> `language`

These properties are read from MyGeotab custom properties, normalized in the backend, and translated into Exchange sync payloads.

## Runtime configuration model

The active configuration split is:

- GitHub repository variables for non-secret deployment settings
- GitHub repository secrets for deployment credentials and certificate material
- Container App secrets for runtime secrets
- Container App environment variables for runtime non-secrets

There is no active runtime Key Vault lookup path in the deployed application.

## Backend processing model

The backend currently:

- authenticates to MyGeotab with the configured service account
- reads all devices, then optionally truncates to `maxDevices`
- batches devices according to `SYNC_BATCH_SIZE`
- parallelizes batches according to `SYNC_MAX_WORKERS`
- invokes PowerShell with `ExchangeOnlineManagement`
- records progress, success counts, failure counts, and summarized results

Large result payloads are truncated before persistence so job records stay within storage limits.
