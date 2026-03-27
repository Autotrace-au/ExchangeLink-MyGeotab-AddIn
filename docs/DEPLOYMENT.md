# Deployment

## Deployment Target

FleetBridge is deployed as a single-tenant Azure Container Apps environment.

The active deployment target includes:

- Resource Group
- Storage Account
- Azure Container Registry
- Container Apps managed environment and container app
- managed identity for ACR pull

## Deployment Model

The active deployment model is fork-and-deploy:

1. fork the repo
2. configure GitHub repository variables and secrets
3. run the deploy workflow
4. enter the deployed backend URL into the MyGeotab Add-In

The runtime uses Container App secrets and environment variables directly. There is no runtime Key Vault dependency.

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

- [deploy-single-tenant.yml](/Users/sam/Git/FleetSync-MyGeotab-AddIn-1/.github/workflows/deploy-single-tenant.yml)

The workflow:

1. signs into Azure with GitHub OIDC
2. deploys the Azure resources from [main.bicep](/Users/sam/Git/FleetSync-MyGeotab-AddIn-1/infra/main.bicep)
3. builds and pushes the backend image
4. redeploys the Container App with the current image tag
5. smoke-tests `/api/health`
6. optionally smoke-tests one sync job

## Post-Deployment

After deployment:

1. confirm `GET /api/health` is healthy
2. confirm the Exchange equipment mailboxes already exist
3. open the MyGeotab Add-In
4. enter and save the backend URL
5. run a limited sync test

## Smoke Test Expectations

A healthy deployment should satisfy all of the following:

- `GET /api/health` returns `healthy`
- `pwshAvailable` is `true`
- MyGeotab configuration is detected
- Exchange tenant and client configuration are detected
- `POST /api/sync-to-exchange` returns `202 Accepted`
- `GET /api/sync-status` reaches `completed` for a small test batch
