# Infrastructure

This directory contains the Bicep template for the current ExchangeLink Azure deployment.

## File

- [`main.bicep`](main.bicep): single-tenant Azure Container Apps infrastructure and runtime configuration

## What it provisions

The template currently creates:

- Storage account
- Azure Container Registry
- Container Apps managed environment
- user-assigned managed identity for ACR pull
- Container App for the backend workload

## What it configures on the Container App

- external HTTPS ingress
- Functions host storage via secret-backed `AzureWebJobsStorage`
- secret-backed MyGeotab credentials
- secret-backed Exchange certificate material
- non-secret runtime configuration for Exchange/MyGeotab behavior
- scale-to-zero with configurable max replicas

## Important deployment assumptions

- The backend image is built separately and referenced by repository name plus tag.
- `EXCHANGE_ORGANIZATION` is set from `EQUIPMENT_DOMAIN`.
- The runtime is hosted as a Container App even though the codebase remains an Azure Functions project.
- Runtime secrets are injected directly into the Container App. There is no current Key Vault dependency in the active path.
