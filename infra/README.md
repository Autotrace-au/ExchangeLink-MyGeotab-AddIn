# Infrastructure

This directory contains the active single-tenant Azure infrastructure definition.

Current files:

- `main.bicep` for the Azure Container Apps deployment

The active deployment model uses:

- Azure Container Apps Consumption
- Azure Container Registry for the custom backend image
- Azure Storage for the Azure Functions host, queue, and table state
- direct Container App secret injection from GitHub Actions

The runtime no longer depends on Key Vault for secret resolution.
