# Deployment

## Hosting target

ExchangeLink is deployed as a single-tenant Azure Container Apps workload.

The active infrastructure in [`infra/main.bicep`](../infra/main.bicep) provisions:

- Azure Resource Group target scope
- Azure Storage account
- Azure Container Registry
- Container Apps managed environment
- Azure Container App running the backend container
- Azure Container Apps scheduled job running the auto-sync evaluator
- user-assigned managed identity for ACR pull

The Container App runs with:

- `minReplicas: 0`
- configurable `maxReplicas`
- Functions host storage via `AzureWebJobsStorage`
- direct secret injection for MyGeotab credentials and Exchange certificate material

The scheduler job runs with:

- a fixed UTC cron heartbeat
- the same image, runtime secrets, and non-secret configuration as the backend
- no ingress

## Deployment path

The supported deployment path is GitHub Actions plus Azure OIDC.

Primary entrypoints:

- [`.github/workflows/deploy-single-tenant.yml`](../.github/workflows/deploy-single-tenant.yml)
- [`scripts/deploy-container-app.sh`](../scripts/deploy-container-app.sh)
- [`scripts/bootstrap-github-actions.sh`](../scripts/bootstrap-github-actions.sh)

Deployment sequence:

1. GitHub Actions logs into Azure using OIDC.
2. Bicep deploys the foundation resources.
3. The backend image is built in ACR from `function-app/`.
4. Bicep deploys or updates the Container App with that image tag.
5. Bicep deploys or updates the scheduled Container Apps job with the same image tag.
6. The workflow resolves the ingress FQDN.
7. The workflow smoke-tests `GET /api/health`.
8. Optionally, the workflow queues and polls a one-device sync test.

## Required GitHub repository variables

These are consumed by the deployment workflow and shell script:

- `RESOURCE_GROUP`
- `AZURE_LOCATION`
- `ENVIRONMENT_NAME`
- `APP_NAME`
- `STORAGE_ACCOUNT_NAME`
- `CONTAINER_APP_NAME`
- `SCHEDULER_JOB_NAME`
- `CONTAINER_APP_ENVIRONMENT_NAME`
- `CONTAINER_REGISTRY_NAME`
- `FUNCTION_IMAGE_REPOSITORY`
- `CONTAINER_APP_MAX_REPLICAS`
- `CONTAINER_CPU`
- `CONTAINER_MEMORY`
- `SCHEDULER_CPU`
- `SCHEDULER_MEMORY`
- `SCHEDULER_HEARTBEAT_CRON`
- `SCHEDULER_REPLICA_TIMEOUT`
- `SCHEDULER_REPLICA_RETRY_LIMIT`
- `EQUIPMENT_DOMAIN`
- `EXCHANGE_TENANT_ID`
- `EXCHANGE_CLIENT_ID`
- `DEFAULT_TIMEZONE`
- `MYGEOTAB_SERVER`
- `MAKE_MAILBOX_VISIBLE_ON_FIRST_SYNC`

Recommended starter values:

- `FUNCTION_IMAGE_REPOSITORY`: `exchangelink-function`
- `CONTAINER_APP_MAX_REPLICAS`: `3`
- `CONTAINER_CPU`: `0.5`
- `CONTAINER_MEMORY`: `1.0Gi`
- `SCHEDULER_CPU`: `0.25`
- `SCHEDULER_MEMORY`: `0.5Gi`
- `SCHEDULER_HEARTBEAT_CRON`: `*/5 * * * *`
- `DEFAULT_TIMEZONE`: `AUS Eastern Standard Time`
- `MYGEOTAB_SERVER`: `my.geotab.com`
- `MAKE_MAILBOX_VISIBLE_ON_FIRST_SYNC`: `true`

These names must be globally unique in Azure:

- `STORAGE_ACCOUNT_NAME`
- `CONTAINER_REGISTRY_NAME`

## Required GitHub repository secrets

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`
- `MYGEOTAB_DATABASE`
- `MYGEOTAB_USERNAME`
- `MYGEOTAB_PASSWORD`
- `EXCHANGE_PFX_BASE64`
- `EXCHANGE_PFX_PASSWORD`

## Runtime environment injected into the Container App

Secret-backed runtime values:

- `AzureWebJobsStorage`
- `MYGEOTAB_DATABASE`
- `MYGEOTAB_USERNAME`
- `MYGEOTAB_PASSWORD`
- `EXCHANGE_CERTIFICATE`
- `EXCHANGE_CERTIFICATE_PASSWORD`

Non-secret runtime values:

- `FUNCTIONS_EXTENSION_VERSION`
- `FUNCTIONS_WORKER_RUNTIME`
- `EXCHANGE_TENANT_ID`
- `EXCHANGE_CLIENT_ID`
- `EQUIPMENT_DOMAIN`
- `DEFAULT_TIMEZONE`
- `MAKE_MAILBOX_VISIBLE_ON_FIRST_SYNC`
- `MYGEOTAB_SERVER`
- `EXCHANGE_ORGANIZATION`
- `SCHEDULER_HEARTBEAT_CRON`

`EXCHANGE_ORGANIZATION` is currently set to the same value as `EQUIPMENT_DOMAIN`.
The same runtime configuration is also injected into the scheduler job.

## Post-deployment checklist

After the workflow succeeds:

1. Resolve the backend URL from the Container App ingress FQDN.
2. Call `GET /api/health`.
3. Confirm the health payload reports the expected configuration.
4. Confirm the target Exchange equipment mailboxes already exist.
5. Open the MyGeotab add-in and save the backend URL.
6. Configure and save an automatic sync schedule if unattended operation is required.
7. Run a small sync test before wider use.

## Smoke-test expectations

A healthy deployment should satisfy all of the following:

- `GET /api/health` returns `status: healthy`
- `config.backend` is `azure-container-apps`
- `config.syncMode` is `async-job`
- `config.schedulerMode` is `container-app-job`
- `config.schedulerHeartbeatCron` matches the deployed heartbeat
- `config.pwshAvailable` is `true`
- MyGeotab configuration flags are `true`
- Exchange tenant and client configuration flags are `true`
- `POST /api/sync-to-exchange` returns HTTP `202`
- `PUT /api/sync-schedule` returns HTTP `200`
- `GET /api/sync-status` reaches `completed` for a test job

Container Apps scheduled-job cron runs in UTC. The saved tenant schedule is still evaluated in the IANA timezone selected in the add-in, and the backend converts that schedule into UTC run times.

## Local deployment helper

For manual deployment from a shell, export the same environment variables used by the workflow and run:

```bash
bash ./scripts/deploy-container-app.sh
```

This script validates required environment variables, deploys the Bicep template, builds the backend image in ACR, updates the Container App, and waits for the health and automatic sync schedule endpoints.
