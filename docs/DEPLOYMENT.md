# Deployment Baseline

## Deployment Target

FleetBridge is being standardized on Azure Function App for the single-tenant product.

## Intended Azure Resources

- Resource Group
- Storage Account
- Function App
- Key Vault
- Managed Identity
- Azure Container Registry

## Deployment Model

The preferred deployment model is:

1. Provision Azure resources from `infra/`
2. Deploy Function App code from `function-app/`
3. Populate Key Vault secrets
4. Configure the MyGeotab Add-In with the Function App endpoint
5. Run first sync against pre-created hidden mailboxes

A thin deployment wrapper is available at `scripts/deploy-function-app.sh`.
A Key Vault seeding helper is available at `scripts/seed-key-vault-secrets.sh`.
The one-run CI entry point is `.github/workflows/deploy-single-tenant.yml`.
A bootstrap helper is available at `scripts/bootstrap-github-actions.sh`.

## Current Baseline

The repository now includes:

- a minimal Function App scaffold that exposes `health`, `update-device-properties`, and `sync-to-exchange`
- an initial `main.bicep` template for the Azure resources required by the single-tenant deployment
- a custom Function App container definition that installs PowerShell and `ExchangeOnlineManagement`

The scaffold is intentionally non-destructive. The sync and property update endpoints currently validate input and return placeholder success payloads until the Exchange and MyGeotab implementation is rebuilt.

Current implementation note:

- `sync-to-exchange` now contains the first real single-tenant flow
- it fetches MyGeotab devices, resolves mailboxes by serial, updates display name from vehicle name, and applies first-sync visibility changes
- the runtime dependency is now explicit: the Function App is deployed from a custom container image built from `function-app/Dockerfile`

## Required Secrets

The active backend expects these Key Vault secrets:

- `MyGeotabDatabase`
- `MyGeotabUsername`
- `MyGeotabPassword`
- `ExchangeCertificate`
- `ExchangeCertificatePassword`
- `EquipmentDomain`

`ExchangeCertificate` should contain the base64-encoded contents of the PFX used for app-only Exchange authentication.
`MYGEOTAB_SERVER` is non-secret config and is set from the Bicep parameter file.

## Minimal Deployment Sequence

1. Commit an environment parameter file under `infra/`.
2. Run `scripts/deploy-function-app.sh <resource-group> <parameters-file>`.
3. Run `scripts/seed-key-vault-secrets.sh <key-vault-name> <mygeotab-database> <mygeotab-username> <mygeotab-password> <exchange-pfx-path> <exchange-pfx-password> <equipment-domain>`.
4. Confirm the Function App health endpoint responds.
5. Configure the MyGeotab Add-In to use the Function App base URL.

## GitHub Actions Deployment

`.github/workflows/deploy-single-tenant.yml` can deploy an environment end-to-end in one run.

Checked-in config:

- `infra/parameters.goa-test.json`
- `infra/parameters.goa-prod.example.json`

Required GitHub secrets:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`
- `MYGEOTAB_DATABASE`
- `MYGEOTAB_USERNAME`
- `MYGEOTAB_PASSWORD`
- `EXCHANGE_PFX_BASE64`
- `EXCHANGE_PFX_PASSWORD`

Bootstrap option:

- `scripts/bootstrap-github-actions.sh` can create the Azure OIDC deployment identity, assign Azure roles, generate an Exchange PFX, append it to the Exchange app registration, and write the required GitHub repository secrets.

Workflow inputs:

- `resource_group`
- `parameters_file`
- optional `run_smoke_sync`

## Exchange Assumptions

- Exchange mailboxes already exist
- mailbox names and addresses are based on the MyGeotab serial
- mailboxes start hidden
- FleetBridge only reconciles and updates them

## Cleanup Result

Container-app deployment scripts, SaaS onboarding scripts, and historical docs are preserved in `legacy/` but are not part of the active deployment path.
