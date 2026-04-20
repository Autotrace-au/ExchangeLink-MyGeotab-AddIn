# New Tenant Deployment Runbook

This runbook is optimized for the client fork flow.

## Goal

The client should be able to:

1. fork the repo
2. configure GitHub variables and secrets
3. run one deploy workflow
4. paste the backend URL into the Add-In

## Step 1: Create the Exchange runtime app registration

Run:

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

Then:

```bash
az ad sp create --id "${EXCHANGE_APP_ID}"
```

Grant `Exchange.ManageAsAppV2` with admin consent and assign the `Exchange Administrator` role to the enterprise application.

## Step 2: Prepare Exchange mailboxes

For each equipment mailbox:

- use the MyGeotab serial as the alias or SMTP local part
- use the chosen equipment domain
- hide it from address lists before first sync

## Step 3: Prepare the MyGeotab service account

Confirm the ExchangeLink MyGeotab account can:

- read devices
- read custom properties
- update custom properties

Record:

- MyGeotab database
- MyGeotab username
- MyGeotab password
- MyGeotab server

## Step 4: Configure GitHub secrets

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

This script:

- configures GitHub OIDC trust
- grants Azure deployment permissions to the GitHub Actions app registration
- generates the Exchange certificate
- attaches the certificate to the Exchange app registration
- writes the required GitHub secrets

## Step 5: Configure GitHub variables

Set these GitHub repository variables in the fork:

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

Recommended starter values:

- `FUNCTION_IMAGE_REPOSITORY`: `exchangelink-function`
- `CONTAINER_APP_MAX_REPLICAS`: `3`
- `CONTAINER_CPU`: `0.5`
- `CONTAINER_MEMORY`: `1.0Gi`
- `DEFAULT_TIMEZONE`: `AUS Eastern Standard Time`
- `MYGEOTAB_SERVER`: `my.geotab.com`
- `MAKE_MAILBOX_VISIBLE_ON_FIRST_SYNC`: `true`

Use globally unique names for:

- `STORAGE_ACCOUNT_NAME`
- `CONTAINER_REGISTRY_NAME`
- `CONTAINER_APP_NAME`
- `CONTAINER_APP_ENVIRONMENT_NAME`

## Step 6: Run the deploy workflow

In GitHub:

1. open `Actions`
2. open `Deploy Client Backend`
3. select `Run workflow`
4. choose whether to run the one-device smoke sync
5. start the workflow

## Step 7: Verify the deployment

After the workflow completes:

1. open the workflow output
2. get the deployed Container App URL
3. run:

```bash
curl -fsS "https://<container-app-url>/api/health"
```

Confirm:

- `status` is `healthy`
- `pwshAvailable` is `true`
- MyGeotab configuration is detected
- Exchange client config is detected

## Step 8: Run a one-device sync test

Queue the job:

```bash
curl -fsS -X POST \
  "https://<container-app-url>/api/sync-to-exchange" \
  -H 'Content-Type: application/json' \
  -d '{"maxDevices":1}'
```

Then poll:

```bash
curl -fsS "https://<container-app-url>/api/sync-status?jobId=<job-id>"
```

## Step 9: Configure the MyGeotab Add-In

Open the Add-In and paste the deployed backend URL.

That is the final client-facing step.
