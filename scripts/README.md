# Scripts

This directory contains the active operational scripts for deployment and tenant bootstrap.

## `deploy-container-app.sh`

Deploys the Azure infrastructure and backend runtime using environment variables already present in the shell or GitHub Actions job.

Current behavior:

- validates required environment variables
- ensures the target resource group exists
- deploys foundation resources from [`../infra/main.bicep`](../infra/main.bicep)
- builds and pushes the backend image in ACR
- deploys or updates the Container App
- waits for the ingress FQDN
- smoke-tests `GET /api/health`

This is the main manual deployment entrypoint:

```bash
bash ./scripts/deploy-container-app.sh
```

## `bootstrap-github-actions.sh`

Bootstraps GitHub Actions deployment prerequisites for a tenant repo.

Current behavior:

- creates or reuses the Azure app registration for GitHub Actions deployment
- creates the service principal if needed
- configures the repo-specific GitHub OIDC federated credential
- grants Azure roles on the subscription
- generates the Exchange runtime certificate
- appends that certificate to the Exchange runtime app registration
- writes the required GitHub repository secrets with `gh secret set`

Usage:

```bash
bash ./scripts/bootstrap-github-actions.sh \
  "<github-org>/<github-repo>" \
  "<subscription-id>" \
  "<exchange-app-id>" \
  "<mygeotab-database>" \
  "<mygeotab-username>" \
  "<mygeotab-password>" \
  "<equipment-domain>" \
  "<exchange-cert-display-name>"
```

## Notes

- These scripts assume Azure CLI authentication is already in place.
- `bootstrap-github-actions.sh` also requires GitHub CLI authentication and `openssl`.
- Retired scripts for older deployment models are intentionally not part of the current documented path.
