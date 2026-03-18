# FleetBridge

FleetBridge is a single-tenant, self-hosted integration between MyGeotab and Exchange Online.

The active product model is:

- one customer MyGeotab database
- one customer Microsoft 365 tenant
- one Azure Function App backend
- one shared MyGeotab Add-In build
- customer-specific Function App URL entered into the Add-In

FleetBridge does not create equipment mailboxes. Customer administrators create them manually in Exchange Online using the MyGeotab serial, keep them hidden initially, and FleetBridge reconciles them during sync.

## Active Behaviour

- The Add-In manages FleetBridge custom properties on MyGeotab assets.
- The Add-In starts Exchange sync jobs and polls status asynchronously.
- The Function App updates MyGeotab device custom properties.
- The Function App reads MyGeotab devices, finds equipment mailboxes by serial, updates mailbox settings, and updates display name from the MyGeotab vehicle name.
- On first successful sync, the Function App can make previously hidden mailboxes visible.

## Repository Layout

- `mygeotab-addin/` active Add-In source
- `function-app/` Azure Function App code and Docker runtime
- `infra/` Bicep infrastructure and environment parameter files
- `docs/` active architecture and deployment documentation
- `scripts/` helper scripts for deployment bootstrap and operations
- `.github/workflows/` GitHub Actions deployment workflows

## Deployment Model

The intended deployment path is GitHub Actions driven and configuration based:

1. Azure resources are provisioned from `infra/`.
2. The Function App container image is built and deployed.
3. Key Vault secrets are seeded from GitHub secrets.
4. Health and sync smoke tests run.
5. The customer enters their Function App base URL into the shared Add-In.

The current baseline uses a Dedicated Linux App Service plan for Azure Functions to reduce monthly hosting cost while keeping support for the custom container runtime.

Primary workflow:

- [deploy-single-tenant.yml](/Users/sam/Git/FleetSync-MyGeotab-AddIn-1/.github/workflows/deploy-single-tenant.yml)

Push-based GOA test deployment:

- [deploy-goa-test-on-push.yml](/Users/sam/Git/FleetSync-MyGeotab-AddIn-1/.github/workflows/deploy-goa-test-on-push.yml)

## What We Need From A Client

If FleetBridge is being deployed into a client tenant, collect all of the following before deployment.

### Azure deployment

- Azure subscription ID
- preferred Azure region
- resource naming convention, if the client requires one
- approval to create:
  - Resource Group
  - Storage Account
  - Key Vault
  - Azure Container Registry
  - Linux Function App on a Dedicated App Service plan
  - managed identity and required role assignments

### Microsoft 365 / Entra / Exchange

- Entra tenant ID
- Exchange Online organization domain
- equipment mailbox domain to use, for example `equipment.clientdomain.com`
- app registration client ID for Exchange app-only auth, or approval for FleetBridge to create and manage one
- approval to attach a certificate to that app registration
- Exchange Online permissions required for app-only mailbox management
- confirmation that equipment mailboxes will be created manually by the client
- confirmation that each mailbox will:
  - use the MyGeotab serial as alias or primary SMTP local part
  - start hidden from address lists
  - exist before first sync

### MyGeotab

- MyGeotab server, for example `my.geotab.com`
- MyGeotab database name
- MyGeotab service username
- MyGeotab service password
- confirmation that the service account can:
  - read devices
  - read properties
  - update device custom properties
  - use Add-In storage if shared settings persistence is required

### Functional settings

- default timezone for mailbox regional configuration
- whether hidden mailboxes should be made visible on first successful sync
- any required CORS origins if the deployment must be restricted
- expected sync size, for example tens vs hundreds of devices

### GitHub Actions deployment

- approval to use GitHub Actions as the deployment runner
- Azure federated credential / OIDC trust for the GitHub repository
- GitHub repository secrets for:
  - `AZURE_CLIENT_ID`
  - `AZURE_TENANT_ID`
  - `AZURE_SUBSCRIPTION_ID`
  - `MYGEOTAB_DATABASE`
  - `MYGEOTAB_USERNAME`
  - `MYGEOTAB_PASSWORD`
  - `EXCHANGE_PFX_BASE64`
  - `EXCHANGE_PFX_PASSWORD`

## Current Status

The active system now supports:

- async Exchange sync jobs with status polling
- MyGeotab device property updates from the Add-In through the Function App
- serial-based mailbox lookup
- vehicle-name-to-display-name updates
- GitHub Actions based Azure deployment

The repository no longer includes the retired SaaS and container-app implementation. The active deployment path is the single-tenant Function App model described above.
