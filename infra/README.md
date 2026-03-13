# Infrastructure

This directory is reserved for the single-tenant Azure infrastructure definition.

Current scaffold:

- `main.bicep` for the single-tenant Function App deployment
- `parameters.example.json` for environment-specific values
- `parameters.goa-test.json` as the active Garage of Awesome test config
- `parameters.goa-prod.example.json` as the production template

The current deployment model uses:

- Azure Function App on Linux Elastic Premium
- Azure Container Registry for the custom Function App image
- a custom Function App container so PowerShell and ExchangeOnlineManagement are part of the runtime

The active intent is infrastructure-as-code for the Azure side. Historical imperative scripts remain under `legacy/`.
