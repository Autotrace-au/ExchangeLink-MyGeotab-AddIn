# ExchangeLink

ExchangeLink is a single-tenant, self-hosted integration between MyGeotab and Exchange Online.

Each client deployment is intended to follow this path:

1. Fork the repo
2. Set GitHub repository variables and secrets
3. Run the deploy workflow
4. Enter the backend URL into the shared MyGeotab Add-In

## Active Model

- one customer MyGeotab database
- one customer Microsoft 365 tenant
- one Azure Container Apps backend
- one shared MyGeotab Add-In build
- customer-specific backend URL entered into the Add-In

ExchangeLink does not create equipment mailboxes. Customer administrators create them manually in Exchange Online using the MyGeotab serial, keep them hidden initially, and ExchangeLink reconciles them during sync.

## Runtime

- `mygeotab-addin/` shared Add-In source
- `function-app/` Azure Functions code and Docker runtime used inside the Container App
- `infra/` Bicep for the Azure Container Apps deployment
- `scripts/` deployment bootstrap helpers
- `.github/workflows/` GitHub Actions deployment workflows

The backend runs on Azure Container Apps Consumption with scale-to-zero and keeps the existing custom runtime for PowerShell and `ExchangeOnlineManagement`.

## Client Setup

The repo now uses:

- GitHub repository variables for non-secret tenant configuration
- GitHub repository secrets for credentials and certificate material
- direct runtime secret injection into the Container App

There is no runtime Key Vault dependency in the active deployment path.

## Required GitHub Variables

- `RESOURCE_GROUP`
- `AZURE_LOCATION`
- `ENVIRONMENT_NAME`
- `APP_NAME`
- `STORAGE_ACCOUNT_NAME`
- `CONTAINER_APP_NAME`
- `CONTAINER_APP_ENVIRONMENT_NAME`
- `CONTAINER_REGISTRY_NAME`
- `FUNCTION_IMAGE_REPOSITORY`
- `CONTAINER_APP_MAX_REPLICAS`
- `CONTAINER_CPU`
- `CONTAINER_MEMORY`
- `EQUIPMENT_DOMAIN`
- `EXCHANGE_TENANT_ID`
- `EXCHANGE_CLIENT_ID`
- `DEFAULT_TIMEZONE`
- `MYGEOTAB_SERVER`
- `MAKE_MAILBOX_VISIBLE_ON_FIRST_SYNC`

## Required GitHub Secrets

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`
- `MYGEOTAB_DATABASE`
- `MYGEOTAB_USERNAME`
- `MYGEOTAB_PASSWORD`
- `EXCHANGE_PFX_BASE64`
- `EXCHANGE_PFX_PASSWORD`

## Main Workflow

- [deploy-single-tenant.yml](.github/workflows/deploy-single-tenant.yml)

The workflow:

1. signs into Azure with GitHub OIDC
2. deploys the Azure resources
3. builds and pushes the backend image
4. redeploys the Container App with the new image tag
5. smoke-tests `/api/health`
6. optionally runs a one-device sync smoke test

## Current Status

The active system supports:

- async Exchange sync jobs with status polling
- MyGeotab device property updates from the Add-In through the backend
- serial-based mailbox lookup
- vehicle-name-to-display-name updates
- GitHub Actions based client deployment

The repository no longer includes the retired dedicated App Service deployment path or runtime Key Vault secret loading path.
