# Backend Workspace

This directory is the active backend workspace for the single-tenant Azure Functions implementation running in Azure Container Apps.

Current scaffold:

- `update-device-properties` HTTP endpoint
- `sync-to-exchange` HTTP endpoint
- `health` HTTP endpoint

Current files:

- `host.json`
- `local.settings.example.json`
- `function_app.py`
- `exchange_sync.ps1`
- `requirements.txt`
- `Dockerfile`

The current implementation is a minimal scaffold that preserves the expected endpoint contract while the MyGeotab and Exchange logic is rebuilt for the single-tenant model.

Current sync behavior:

- pulls devices from MyGeotab using configured backend credentials
- locates Exchange mailboxes by device serial
- updates the Exchange display name from the MyGeotab vehicle name
- applies booking defaults and mailbox visibility changes through `exchange_sync.ps1`

Runtime note:

- the backend runtime is explicitly defined as a custom container
- that container installs `pwsh` and `ExchangeOnlineManagement`
- Exchange certificate material is expected from Key Vault secrets

Expected Key Vault secrets:

- `MyGeotabDatabase`
- `MyGeotabUsername`
- `MyGeotabPassword`
- `ExchangeCertificate`
- `ExchangeCertificatePassword`
- `EquipmentDomain`

Expected non-secret app settings:

- `MYGEOTAB_SERVER`
- `EXCHANGE_CLIENT_ID`
- `EXCHANGE_TENANT_ID`
- `DEFAULT_TIMEZONE`
- `MAKE_MAILBOX_VISIBLE_ON_FIRST_SYNC`

This directory remains named `function-app/` because it contains the Azure Functions project that runs inside the Container App.
