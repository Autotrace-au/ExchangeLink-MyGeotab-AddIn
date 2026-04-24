# ExchangeLink

ExchangeLink is a single-tenant integration between MyGeotab and Exchange Online. It gives MyGeotab users a shared add-in for equipment booking settings and pairs that with a tenant-specific Azure backend that syncs device metadata into pre-created Exchange equipment mailboxes.

The current product shape is:

- one MyGeotab database per deployment
- one Microsoft 365 tenant per deployment
- one Azure Container Apps backend per deployment
- one shared MyGeotab add-in build
- one backend URL saved inside the add-in for that tenant

ExchangeLink does not provision equipment mailboxes. Customer admins create those mailboxes in Exchange Online first, using the MyGeotab serial as the mailbox alias or SMTP local part. ExchangeLink then updates mailbox visibility, booking settings, and display metadata during sync.

## What the app does now

The add-in in [`mygeotab-addin/`](mygeotab-addin/README.md) lets MyGeotab users:

- inspect and manage the ExchangeLink custom properties used for booking automation
- edit booking-related settings on assets
- save the tenant backend URL in add-in/browser storage
- trigger Exchange sync jobs
- save and recall a tenant-wide automatic sync schedule
- poll live sync status and review per-device results
- manage assets in bulk from the add-in UI

The backend in [`function-app/`](function-app/README.md) exposes:

- `GET /api/health`
- `POST /api/update-device-properties`
- `POST /api/sync-to-exchange`
- `GET /api/sync-schedule`
- `PUT /api/sync-schedule`
- `GET /api/sync-status?jobId=...`

Sync is asynchronous. Jobs are queued in Azure Storage, processed in the background by the Azure Functions host, and tracked in Table Storage so the add-in can poll progress without browser timeouts. A separate Azure Container Apps scheduled job can also enqueue unattended sync runs from the saved backend schedule.

## Deployment model

This repo is built for a fork-and-deploy workflow:

1. Fork the repository for a customer or environment.
2. Configure GitHub repository variables and secrets.
3. Run the deployment workflow.
4. Copy the deployed backend URL into the add-in.

The active hosting stack is:

- Azure Container Apps for runtime hosting
- Azure Container Registry for the backend image
- Azure Storage for the Functions host, queue jobs, and job state
- GitHub Actions with Azure OIDC for deployment

There is no active runtime Key Vault dependency in this deployment path.

## Repository layout

- [`mygeotab-addin/`](mygeotab-addin/README.md): shared MyGeotab add-in source
- [`function-app/`](function-app/README.md): Azure Functions backend and Exchange sync runtime
- [`infra/`](infra/README.md): Bicep infrastructure for the active Azure deployment
- [`scripts/`](scripts/README.md): deployment/bootstrap helpers
- [`.github/workflows/`](.github/workflows): deployment and PR validation workflows
- [`docs/`](docs/README.md): architecture, deployment, and tenant runbooks

## Fast start

For a new tenant:

1. Read [`docs/NEW_TENANT_DEPLOYMENT.md`](docs/NEW_TENANT_DEPLOYMENT.md).
2. Set the required GitHub variables and secrets described in [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md).
3. Run [`.github/workflows/deploy-single-tenant.yml`](.github/workflows/deploy-single-tenant.yml).
4. Open the add-in and save the deployed backend URL.

For contributors:

1. Read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
2. Keep [`configuration.json`](configuration.json) and [`mygeotab-addin/configuration.json`](mygeotab-addin/configuration.json) identical.
3. If anything under `mygeotab-addin/` changes, bump the add-in version in both manifest files.
4. Run the local validation commands before opening a PR.

## Local validation

Python syntax check:

```bash
python -m py_compile function-app/function_app.py
```

MyGeotab add-in inline script parse check:

```bash
node - <<'NODE'
const fs = require('fs');
const html = fs.readFileSync('mygeotab-addin/index.html', 'utf8');
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);

if (!scripts.length) {
  throw new Error('No inline scripts found in mygeotab-addin/index.html');
}

scripts.forEach((script, index) => {
  try {
    new Function(script);
  } catch (error) {
    throw new Error(`Inline script ${index} failed to parse: ${error.message}`);
  }
});
NODE
```

Manifest sync and version query-string validation logic lives in [`.github/workflows/pr-code-review.yml`](.github/workflows/pr-code-review.yml).

## Current expectations

- Changes under `mygeotab-addin/` must include a version bump in `mygeotab-addin/configuration.json`.
- `configuration.json` and `mygeotab-addin/configuration.json` must stay in sync.
- PRs are scanned for secrets by [`.github/workflows/pr-secrets-review.yml`](.github/workflows/pr-secrets-review.yml).

## Primary docs

- [`docs/README.md`](docs/README.md)
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md)
- [`docs/NEW_TENANT_DEPLOYMENT.md`](docs/NEW_TENANT_DEPLOYMENT.md)
