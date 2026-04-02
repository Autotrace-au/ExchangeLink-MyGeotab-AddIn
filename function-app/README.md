# Backend Workspace

This directory contains the Azure Functions project that runs inside the Azure Container App.

Current files:

- `function_app.py`
- `exchange_sync.ps1`
- `requirements.txt`
- `Dockerfile`
- `host.json`
- `local.settings.example.json`

Runtime notes:

- the backend is packaged as a custom container
- the container installs `pwsh` and `ExchangeOnlineManagement`
- runtime credentials are provided through environment variables and Container App secrets

Expected secret environment variables:

- `MYGEOTAB_DATABASE`
- `MYGEOTAB_USERNAME`
- `MYGEOTAB_PASSWORD`
- `EXCHANGE_CERTIFICATE`
- `EXCHANGE_CERTIFICATE_PASSWORD`

Expected non-secret environment variables:

- `MYGEOTAB_SERVER`
- `EXCHANGE_TENANT_ID`
- `EXCHANGE_CLIENT_ID`
- `EXCHANGE_ORGANIZATION`
- `EQUIPMENT_DOMAIN`
- `DEFAULT_TIMEZONE`
- `MAKE_MAILBOX_VISIBLE_ON_FIRST_SYNC`

This directory remains named `function-app/` because it is still an Azure Functions project, even though the host platform is now Azure Container Apps.
