# New Tenant Deployment Runbook

This runbook is the current source of truth for onboarding a new customer or environment onto the single-tenant ExchangeLink deployment model.

## Outcome

At the end of this runbook you should have:

- a tenant-specific Azure backend deployed
- GitHub Actions configured for repeatable deployments
- Exchange equipment mailboxes prepared for sync
- a MyGeotab service account with the required permissions
- a backend URL ready to paste into the add-in

## Step 1: Fork or create the repository target

Create the GitHub repository that will own this tenant deployment. The expected model is one repo or fork per customer or environment.

Record:

- GitHub repo name in `owner/name` form
- Azure subscription ID
- Azure tenant ID

## Step 2: Create the Exchange runtime app registration

Create an Entra app registration for Exchange app-only access:

```bash
EXCHANGE_APP_NAME="ExchangeLink Exchange Runtime"
TENANT_ID="$(az account show --query tenantId -o tsv)"
EXCHANGE_APP_ID="$(az ad app create \
  --display-name "${EXCHANGE_APP_NAME}" \
  --sign-in-audience AzureADMyOrg \
  --query appId -o tsv)"

echo "Tenant ID: ${TENANT_ID}"
echo "Exchange App ID: ${EXCHANGE_APP_ID}"
```

Create its service principal:

```bash
az ad sp create --id "${EXCHANGE_APP_ID}"
```

Then grant the Exchange permissions required for app-only management and complete admin consent. The enterprise app also needs an Exchange admin role assignment appropriate for managing equipment mailboxes in the tenant.

Record:

- Exchange tenant ID
- Exchange app registration client ID

## Step 3: Prepare Exchange equipment mailboxes

ExchangeLink expects mailboxes to exist before sync runs.

For each equipment mailbox:

- use the MyGeotab serial as the alias or SMTP local part
- use the equipment domain that will be configured for this tenant
- keep the mailbox hidden from address lists until the first successful sync if that matches your rollout plan

The backend currently derives mailbox identity from the device serial and can make mailboxes visible on first sync when `MAKE_MAILBOX_VISIBLE_ON_FIRST_SYNC=true`.

## Step 4: Prepare the MyGeotab service account

Create or confirm a MyGeotab account that can:

- read devices
- read custom properties
- update custom properties

Record:

- MyGeotab database
- MyGeotab username
- MyGeotab password
- MyGeotab server hostname

## Step 5: Bootstrap GitHub Actions secrets

Run the bootstrap helper:

```bash
bash ./scripts/bootstrap-github-actions.sh \
  "<github-org>/<github-repo>" \
  "<subscription-id>" \
  "<exchange-runtime-app-client-id>" \
  "<mygeotab-database>" \
  "<mygeotab-username>" \
  "<mygeotab-password>" \
  "<equipment-domain>" \
  "ExchangeLink Exchange Runtime"
```

What this script does:

- ensures an Azure app registration exists for GitHub Actions deployment
- creates or refreshes a GitHub OIDC federated credential for the repo's `main` branch
- assigns Azure roles to the deployment principal
- generates a PFX certificate for the Exchange runtime app
- appends the public certificate to the Exchange app registration
- writes the required GitHub repository secrets

Prerequisites for the script:

- Azure CLI authenticated to the correct tenant/subscription
- GitHub CLI authenticated with permission to manage repo secrets
- `openssl` available locally

## Step 6: Configure GitHub repository variables

Set these repository variables:

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

Recommended initial values:

- `FUNCTION_IMAGE_REPOSITORY`: `exchangelink-function`
- `CONTAINER_APP_MAX_REPLICAS`: `3`
- `CONTAINER_CPU`: `0.5`
- `CONTAINER_MEMORY`: `1.0Gi`
- `DEFAULT_TIMEZONE`: `AUS Eastern Standard Time`
- `MYGEOTAB_SERVER`: `my.geotab.com`
- `MAKE_MAILBOX_VISIBLE_ON_FIRST_SYNC`: `true`

Use unique Azure-safe values for:

- `STORAGE_ACCOUNT_NAME`
- `CONTAINER_REGISTRY_NAME`
- `CONTAINER_APP_NAME`
- `CONTAINER_APP_ENVIRONMENT_NAME`

## Step 7: Run the deployment workflow

In GitHub:

1. Open `Actions`.
2. Open `Deploy Client Backend`.
3. Run [`.github/workflows/deploy-single-tenant.yml`](../.github/workflows/deploy-single-tenant.yml).
4. Decide whether to run the one-device smoke sync.
5. Start the workflow.

## Step 8: Verify the backend

After deployment, resolve the Container App URL and call:

```bash
curl -fsS "https://<container-app-url>/api/health"
```

Confirm the response shows:

- `status` = `healthy`
- `config.backend` = `azure-container-apps`
- `config.syncMode` = `async-job`
- `config.pwshAvailable` = `true`
- MyGeotab configuration flags enabled
- Exchange tenant and client configuration flags enabled

## Step 9: Run a small sync test

Queue a small job:

```bash
curl -fsS -X POST \
  "https://<container-app-url>/api/sync-to-exchange" \
  -H 'Content-Type: application/json' \
  -d '{"maxDevices":1}'
```

Poll job status:

```bash
curl -fsS "https://<container-app-url>/api/sync-status?jobId=<job-id>"
```

Expected path:

- initial status `queued`
- intermediate status `running`
- final status `completed`

If the job completes with failures, inspect the returned `results` payload before wider rollout.

## Step 10: Configure the add-in

Open the MyGeotab add-in and save the deployed backend URL. That is the tenant-specific handoff step that binds the shared add-in UI to the deployed backend.
