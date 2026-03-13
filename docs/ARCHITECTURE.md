# FleetBridge Architecture

## Scope

FleetBridge is designed as a single-tenant integration for one MyGeotab database and one Microsoft 365 tenant.

This is not currently a SaaS multi-tenant platform. Each deployment is customer-specific, but the MyGeotab Add-In codebase is shared. The customer connects the shared Add-In to their own backend by entering their Function App URL.

## Active Components

### MyGeotab Add-In

The Add-In runs inside MyGeotab and is responsible for:

- creating and checking FleetBridge custom property definitions
- editing FleetBridge booking properties on assets
- saving the customer Function App URL
- starting Exchange sync jobs
- polling sync job status and rendering results

### Azure Function App

The Function App is the backend control plane. It is responsible for:

- health reporting
- updating MyGeotab device custom properties
- queueing async sync jobs
- processing sync jobs in the background
- reading MyGeotab devices
- reconciling Exchange Online mailbox settings

The Function App is deployed as a custom Linux container so the runtime includes:

- Python
- PowerShell
- `ExchangeOnlineManagement`

### Azure Storage

Azure Storage is used for:

- Function runtime storage
- queue-backed async sync jobs
- job status persistence in Table Storage

### Azure Key Vault

Key Vault stores deployment secrets such as:

- MyGeotab credentials
- Exchange certificate material
- Exchange certificate password

### Exchange Online

Exchange Online contains the customer’s equipment mailboxes and is the target system for booking configuration updates.

## Mailbox Lifecycle

1. A customer administrator manually creates an equipment mailbox in Exchange Online.
2. The mailbox identity is based on the MyGeotab serial.
3. The mailbox starts hidden from address lists.
4. FleetBridge reads the corresponding MyGeotab device during sync.
5. FleetBridge finds the mailbox by serial.
6. FleetBridge updates mailbox settings from MyGeotab custom properties.
7. FleetBridge updates the Exchange display name from the MyGeotab vehicle name.
8. On first successful sync, FleetBridge can make the mailbox visible.

FleetBridge does not create the mailbox.

## Sync Model

### Identity and matching

- mailbox lookup key: MyGeotab serial
- human-readable name source: MyGeotab vehicle name

The serial is the stable system identifier. The vehicle name is a mutable label and is updated over time.

### Execution model

Sync is asynchronous.

1. The Add-In calls `POST /api/sync-to-exchange`.
2. The Function App creates a job record and enqueues work.
3. A queue-triggered worker processes the job in the background.
4. The Add-In polls `GET /api/sync-status?jobId=...`.
5. Final per-device results are read from persisted job state.

This avoids browser timeouts for larger environments.

## MyGeotab Property Model

FleetBridge stores booking-related configuration as MyGeotab device custom properties. These include:

- Enable Equipment Booking
- Allow Recurring Bookings
- Booking Approvers
- Fleet Managers
- Allow Double Booking
- Booking Window (Days)
- Maximum Booking Duration (Hours)
- Mailbox Language

The Add-In edits these values and the Function App persists them back to MyGeotab.

## Configuration Boundaries

### Non-secret configuration

Non-secret configuration belongs in Bicep parameters and Function App settings, for example:

- Azure region
- equipment domain
- Exchange tenant and client identifiers
- default timezone
- make-visible-on-first-sync flag
- CORS origins
- image name and ACR settings

### Secret configuration

Secret configuration belongs in Key Vault or GitHub repository secrets, for example:

- MyGeotab database
- MyGeotab username
- MyGeotab password
- Exchange PFX contents
- Exchange PFX password

## Operational Boundaries

FleetBridge is responsible for:

- property definition management
- property updates on devices
- mailbox reconciliation
- job tracking and health checks
