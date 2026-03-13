# FleetBridge Architecture

## Scope

FleetBridge is now scoped as a single-tenant, self-hosted integration for one customer environment.

## Active Components

1. `mygeotab-addin/`
   The browser-based UI used inside MyGeotab.
2. `function-app/`
   The Azure Function backend that receives sync requests and reconciles Exchange mailbox state.
3. Exchange Online
   The customer's own Microsoft 365 tenant containing the equipment mailboxes.
4. Azure Key Vault
   Stores secrets required by the Function App.

## Mailbox Lifecycle

1. An administrator manually creates the equipment mailbox using the MyGeotab serial.
2. The mailbox is created hidden from address lists.
3. FleetBridge sync finds the mailbox by serial-based identity.
4. FleetBridge updates mailbox settings and booking configuration from MyGeotab data.
5. On first successful sync, FleetBridge makes the mailbox visible.

## Backend Responsibilities

The Function App is responsible for:

- updating MyGeotab device properties when requested by the Add-In
- running sync from MyGeotab to Exchange Online
- applying mailbox configuration to existing mailboxes
- making eligible hidden mailboxes visible on first sync
- exposing health endpoints for operations

The Function App is not responsible for:

- creating Exchange mailboxes
- multi-tenant onboarding
- SaaS consent flows
- per-client API key management

## Current Implementation State

The active backend code is currently a scaffold:

- endpoint names match the existing Add-In contract
- `health` is operational
- `update-device-properties` validates requests and returns a placeholder response
- `sync-to-exchange` now performs the single-tenant reconciliation flow using MyGeotab device data and an Exchange PowerShell bridge

This keeps the migration incremental while the real MyGeotab and Exchange logic is rebuilt for the new single-tenant baseline.

## Runtime Model

The Function App runtime is explicitly containerized so that:

- Python hosts the HTTP functions
- PowerShell is available for Exchange Online operations
- `ExchangeOnlineManagement` is installed as part of the image build

## Configuration Boundaries

Non-secret configuration should live in infrastructure parameters and app settings, for example:

- Exchange tenant identifiers
- equipment mailbox domain
- default timezone
- visibility-on-first-sync flag
- allowed CORS origins

Secrets should live in Key Vault, for example:

- MyGeotab credentials
- Exchange certificate or app secret

## Legacy Boundary

The prior container-app and SaaS-oriented implementation has been moved to `legacy/` and is not part of the active target architecture.
