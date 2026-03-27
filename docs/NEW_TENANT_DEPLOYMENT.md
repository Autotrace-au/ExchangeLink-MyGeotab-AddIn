# New Tenant Deployment Runbook

Follow these steps in order.

This runbook assumes you are deploying with GitHub Actions. That is the main deployment path for this repo.

## Before You Start

You need:

- an Azure subscription in the target tenant
- Global Admin or equivalent in the target tenant
- Exchange Admin access
- a GitHub repo containing this project
- a MyGeotab database and service account

You also need these tools locally:

```bash
az login
gh auth login
```

And:

- `bash`
- `python3`
- `openssl`

## Step 1: Create the Exchange runtime app registration

Run this from the repo root:

```bash
EXCHANGE_APP_NAME="FleetBridge Exchange Runtime"
TENANT_ID="$(az account show --query tenantId -o tsv)"
EXCHANGE_APP_ID="$(az ad app create \
  --display-name "${EXCHANGE_APP_NAME}" \
  --sign-in-audience AzureADMyOrg \
  --query appId -o tsv)"

echo "Tenant ID: ${TENANT_ID}"
echo "Exchange App ID: ${EXCHANGE_APP_ID}"
```

Write both values down:

- `TENANT_ID`
- `EXCHANGE_APP_ID`

Then create the service principal for that app:

```bash
az ad sp create --id "${EXCHANGE_APP_ID}"
```

You will use:

- `TENANT_ID` as `exchangeTenantId`
- `EXCHANGE_APP_ID` as `exchangeClientId`

## Step 2: Grant Exchange permissions to that app

Do this in the Microsoft Entra admin center at `https://entra.microsoft.com`.

1. Open `App registrations`.
2. Open `FleetBridge Exchange Runtime`.
3. Open `API permissions`.
4. Select `Add a permission`.
5. Select `APIs my organization uses`.
6. Search for `Office 365 Exchange Online`.
7. Select `Application permissions`.
8. Expand `Exchange`.
9. Add `Exchange.ManageAsAppV2`.
10. Select `Grant admin consent`.

Then assign a role to the enterprise application:

1. In Entra, open `Roles & admins`.
2. Open `Exchange Administrator`.
3. Select `Add assignments`.
4. Search for `FleetBridge Exchange Runtime`.
5. Add the assignment.

This is the simplest supported path for the current app-only Exchange setup.

Do not continue until the app has:

- `Exchange.ManageAsAppV2` with admin consent
- the `Exchange Administrator` role assignment

## Step 3: Create the equipment mailboxes

Create the equipment mailboxes in Exchange Online.

For each mailbox:

- use the MyGeotab serial as the alias or SMTP local part
- use the equipment mailbox domain you plan to deploy with
- start the mailbox hidden from address lists

Example:

- serial `ABC1234`
- mailbox `abc1234@equipment.example.com`

How to do it:

1. Open the Exchange admin center.
2. Create the equipment or resource mailbox using the serial as the alias.
3. Set the primary SMTP address under your chosen equipment domain.
4. Hide the mailbox from address lists before first sync.

Do this for every asset you want FleetBridge to manage.

## Step 4: Prepare the MyGeotab service account

Create or confirm the MyGeotab service account.

It must be able to:

- read devices
- read custom properties
- update device custom properties

Record:

- MyGeotab database
- MyGeotab username
- MyGeotab password
- MyGeotab server, usually `my.geotab.com`

How to do it:

1. Create or identify a dedicated MyGeotab user for FleetBridge.
2. Confirm it can read devices.
3. Confirm it can read custom properties.
4. Confirm it can update device custom properties.
5. Test the credentials by signing in to the correct MyGeotab database.

## Step 5: Create the Azure parameter file

Copy the example parameter file:

```bash
cp infra/parameters.example.json infra/parameters.customer-prod.json
```

Edit `infra/parameters.customer-prod.json` and set:

- `location`
- `environmentName`
- `storageAccountName`
- `containerAppName`
- `keyVaultName`
- `containerAppEnvironmentName`
- `containerRegistryName`
- `exchangeTenantId`
- `exchangeClientId`
- `equipmentDomain`
- `defaultTimezone`
- `myGeotabServer`
- `makeMailboxVisibleOnFirstSync`

Use globally unique names for:

- storage account
- key vault
- container registry
- container app

Use this template and replace the values:

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "location": { "value": "australiaeast" },
    "environmentName": { "value": "customer-prod" },
    "appName": { "value": "fleetbridge" },
    "storageAccountName": { "value": "replaceuniquestorage" },
    "containerAppName": { "value": "replace-unique-container-app" },
    "keyVaultName": { "value": "replace-unique-keyvault" },
    "containerAppEnvironmentName": { "value": "replace-prod-container-env" },
    "containerRegistryName": { "value": "replaceuniqueacr" },
    "functionImageRepository": { "value": "fleetbridge-function" },
    "functionImageTag": { "value": "latest" },
    "exchangeTenantId": { "value": "TENANT_ID_FROM_STEP_1" },
    "exchangeClientId": { "value": "EXCHANGE_APP_ID_FROM_STEP_1" },
    "equipmentDomain": { "value": "equipment.example.com" },
    "defaultTimezone": { "value": "AUS Eastern Standard Time" },
    "myGeotabServer": { "value": "my.geotab.com" },
    "makeMailboxVisibleOnFirstSync": { "value": true }
  }
}
```

## Step 6: Run the bootstrap script

Run this command from the repo root:

```bash
bash ./scripts/bootstrap-github-actions.sh \
  "<github-org>/<github-repo>" \
  "<subscription-id>" \
  "<exchange-runtime-app-client-id>" \
  "<mygeotab-database>" \
  "<mygeotab-username>" \
  "<mygeotab-password>" \
  "<equipment-domain>" \
  "FleetBridge Exchange Runtime"
```

This script does all of the following:

- creates or reuses the GitHub Actions Azure deployment app registration
- creates or reuses its service principal
- configures GitHub OIDC trust
- assigns Azure deployment roles
- generates an Exchange certificate
- attaches that certificate to the Exchange runtime app registration from Step 1
- writes the required GitHub secrets

After this step, verify these GitHub secrets exist:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`
- `MYGEOTAB_DATABASE`
- `MYGEOTAB_USERNAME`
- `MYGEOTAB_PASSWORD`
- `EXCHANGE_PFX_BASE64`
- `EXCHANGE_PFX_PASSWORD`

How to verify:

1. Open your GitHub repository.
2. Open `Settings`.
3. Open `Secrets and variables` > `Actions`.
4. Confirm all eight secrets are present.

## Step 7: Commit and push the parameter file

Commit your new parameter file and push it to the repository branch you want to deploy from.

Example:

```bash
git add infra/parameters.customer-prod.json
git commit -m "Add customer production parameters"
git push
```

How to verify:

```bash
git ls-files infra/parameters.customer-prod.json
```

You should see the file path printed.

## Step 8: Run the deployment workflow

In GitHub, run:

- [deploy-single-tenant.yml](/Users/sam/Git/FleetSync-MyGeotab-AddIn-1/.github/workflows/deploy-single-tenant.yml)

Use these inputs:

- `resource_group`: your target resource group name
- `parameters_file`: `infra/parameters.customer-prod.json`
- `run_smoke_sync`: `false`

This workflow will:

1. deploy the Azure infrastructure
2. build and push the backend container
3. configure the Container App
4. seed Key Vault with runtime secrets
5. run the health check

How to do it:

1. Open your GitHub repository.
2. Open `Actions`.
3. Open `Deploy Single-Tenant Container App`.
4. Select `Run workflow`.
5. Enter:
   - `resource_group`: your Azure resource group name
   - `parameters_file`: `infra/parameters.customer-prod.json`
   - `run_smoke_sync`: `false`
6. Start the workflow and wait for it to complete successfully.

## Step 9: Check the health endpoint

Run:

```bash
curl -fsS "https://<container-app-url>/api/health"
```

Confirm:

- `status` is `healthy`
- `pwshAvailable` is `true`
- MyGeotab config is detected
- Exchange client config is detected

If you do not know the container app name, print it from the parameter file:

```bash
python3 -c 'import json; print(json.load(open("infra/parameters.customer-prod.json", encoding="utf-8"))["parameters"]["containerAppName"]["value"])'
```

## Step 10: Run a one-device sync test

Queue the job:

```bash
curl -fsS -X POST \
  "https://<container-app-url>/api/sync-to-exchange" \
  -H 'Content-Type: application/json' \
  -d '{"maxDevices":1}'
```

Copy the returned `jobId`.

Poll the job:

```bash
curl -fsS "https://<container-app-url>/api/sync-status?jobId=<job-id>"
```

Do not continue until:

- the job reaches `completed`
- the mailbox is found
- the mailbox update succeeds

How to read the result:

- `status` should become `completed`
- `failed` should be `0`
- the first result item should show `success: true`

## Step 11: Re-run the workflow with smoke sync enabled

Run the same GitHub Actions workflow again with:

- `run_smoke_sync`: `true`

This confirms the built-in workflow smoke test also passes.

## Step 12: Configure the MyGeotab Add-In

In the FleetBridge Add-In:

1. enter the deployed backend base URL
2. save settings
3. test a property update
4. test a limited sync

The base URL format is:

```text
https://<container-app-fqdn>.azurecontainerapps.io
```

## If Something Fails

Check these first:

- the Exchange runtime app registration exists
- the certificate was attached to the correct app registration
- the equipment mailbox exists
- the mailbox alias matches the MyGeotab serial
- `equipmentDomain` matches the mailbox domain
- the MyGeotab credentials are correct
- the GitHub secrets were written to the correct repository

## One-Line Summary

The exact order is:

1. create Exchange app registration
2. grant Exchange permissions
3. create equipment mailboxes
4. prepare MyGeotab credentials
5. create `infra/parameters.customer-prod.json`
6. run `scripts/bootstrap-github-actions.sh`
7. push the parameter file
8. run `deploy-single-tenant.yml`
9. check `/api/health`
10. run a one-device sync
11. enable workflow smoke sync
12. configure the Add-In
