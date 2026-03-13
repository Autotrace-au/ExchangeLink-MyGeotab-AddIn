# FleetBridge

FleetBridge is being standardized as a single-tenant, self-hosted MyGeotab to Exchange Online integration.

Current target architecture:

- `mygeotab-addin/` for the browser UI hosted by MyGeotab
- `function-app/` for the Azure Function backend
- `infra/` for deployment and infrastructure-as-code
- `docs/` for current single-tenant documentation
- `legacy/` for superseded container-app, SaaS, and historical deployment assets

## Product Direction

This repository is now aligned to a single Microsoft 365 tenant owned by the customer.

Operational model:

- Equipment mailboxes are created manually by an administrator using the MyGeotab serial
- Mailboxes begin hidden
- The first sync updates mailbox settings and makes the mailbox visible
- The backend does not create mailboxes

## Repository Layout

- `mygeotab-addin/` active Add-In source
- `function-app/` new Azure Function App workspace
- `infra/` new IaC workspace for Azure resources
- `docs/` active architecture and deployment guidance
- `scripts/` new operational scripts for the single-tenant Function App model
- `.github/workflows/` one-run GitHub Actions deployment path
- `legacy/` archived implementation and documentation not used by the new baseline

## Status

The active runtime target is Azure Function App, and the checked-in deployment path is now:

- Bicep parameter file for environment-specific non-secret config
- GitHub Actions workflow for deploy/build/seed/health-check
- GitHub secrets for MyGeotab credentials, Azure auth, and Exchange certificate material

The previous container-app implementation remains under `legacy/` for reference only.
