# Infrastructure

This directory is reserved for the single-tenant Azure infrastructure definition.

Current scaffold:

- `main.bicep` for the single-tenant Container Apps deployment
- `parameters.example.json` for environment-specific values
- `parameters.goa-test.json` as the active Garage of Awesome test config
- `parameters.goa-prod.example.json` as the production template

The current deployment model uses:

- Azure Container Apps Consumption environment
- Azure Container Registry for the custom backend image
- a custom backend container so PowerShell and ExchangeOnlineManagement are part of the runtime

The active intent is infrastructure-as-code for the Azure side. Retired imperative deployment assets are no longer included here.
