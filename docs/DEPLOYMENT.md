# Deployment

## Deployment Target

FleetBridge is deployed as a single-tenant Azure Function App environment.

The active deployment target includes:

- Resource Group
- Storage Account
- Key Vault
- Azure Container Registry
- Linux Function App on a Dedicated App Service plan
- managed identity
- required Azure role assignments

Current baseline:

- Linux Dedicated B2 App Service plan
- custom container Function App runtime

## Deployment Method

The preferred deployment method is GitHub Actions with configuration in source control and secrets in GitHub and Key Vault.

Primary workflow:

- [deploy-single-tenant.yml](/Users/sam/Git/FleetSync-MyGeotab-AddIn-1/.github/workflows/deploy-single-tenant.yml)

Supporting scripts:

- [bootstrap-github-actions.sh](/Users/sam/Git/FleetSync-MyGeotab-AddIn-1/scripts/bootstrap-github-actions.sh)
- [deploy-function-app.sh](/Users/sam/Git/FleetSync-MyGeotab-AddIn-1/scripts/deploy-function-app.sh)
- [seed-key-vault-secrets.sh](/Users/sam/Git/FleetSync-MyGeotab-AddIn-1/scripts/seed-key-vault-secrets.sh)

## Configuration As Code Split

### In source control

- Bicep templates
- environment parameter files
- GitHub Actions workflow definitions
- Function App code
- Add-In code

### In GitHub secrets / Key Vault

- Azure federated deployment identity values
- MyGeotab credentials
- Exchange PFX contents
- Exchange PFX password

## Required Azure Inputs

Before deployment, define or confirm:

- target subscription
- target resource group name
- Azure region
- naming values required by the parameter file
- Exchange tenant ID
- Exchange client ID
- equipment domain
- default timezone
- whether to make mailboxes visible on first successful sync

Environment parameters live under `infra/`, for example:

- [parameters.goa-test.json](/Users/sam/Git/FleetSync-MyGeotab-AddIn-1/infra/parameters.goa-test.json)
- [parameters.goa-prod.example.json](/Users/sam/Git/FleetSync-MyGeotab-AddIn-1/infra/parameters.goa-prod.example.json)

## Required Secrets

GitHub repository secrets required by the workflow:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`
- `MYGEOTAB_DATABASE`
- `MYGEOTAB_USERNAME`
- `MYGEOTAB_PASSWORD`
- `EXCHANGE_PFX_BASE64`
- `EXCHANGE_PFX_PASSWORD`

The deployment workflow seeds Key Vault with the runtime secrets expected by the Function App.

## End-To-End Deployment Flow

1. Bootstrap GitHub Actions Azure trust and repository secrets.
2. Commit or select the target `infra` parameter file.
3. Run the GitHub Actions deployment workflow.
4. Provision Azure resources from Bicep.
5. Build and push the Function App image.
6. Configure the Function App to use that image.
7. Seed Key Vault secrets.
8. Run health and sync smoke tests.
9. Enter the Function App base URL into the MyGeotab Add-In.

## Post-Deployment Steps In The Client Tenant

After Azure deployment is complete:

1. Ensure the Exchange equipment mailboxes already exist.
2. Ensure each mailbox is based on the MyGeotab serial.
3. Ensure each mailbox starts hidden.
4. Open the MyGeotab Add-In.
5. Enter and save the customer Function App URL.
6. Run a limited sync test.
7. Confirm:
   - property updates apply from Manage Assets
   - sync jobs complete successfully
   - display names match vehicle names
   - hidden mailboxes are made visible when expected

## Runtime Behaviour

### Property updates

`POST /api/update-device-properties` writes FleetBridge custom property values back to MyGeotab devices.

### Sync

`POST /api/sync-to-exchange` creates an async job and returns a `jobId`.

`GET /api/sync-status` reports:

- queued
- running
- completed
- failed

with processed counts and per-device results.

## Smoke Test Expectations

A healthy deployment should satisfy all of the following:

- `GET /api/health` returns `healthy`
- `pwshAvailable` is `true`
- MyGeotab configuration is detected
- Exchange tenant and client configuration are detected
- `POST /api/sync-to-exchange` returns `202 Accepted`
- `GET /api/sync-status` reaches `completed` for a small test batch

## Known Operational Constraint

The deployment pipeline rebuilds the custom Function App image on each deploy. That makes deployments slower than a plain zip-based Functions deployment, but it is required because the runtime must include PowerShell and `ExchangeOnlineManagement`.

## Scope

This repository now contains only the active single-tenant Function App deployment path.
