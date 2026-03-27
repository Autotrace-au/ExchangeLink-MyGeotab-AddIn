# Scripts

This directory contains operational scripts for the single-tenant Container Apps deployment model.

Current scripts:

- `deploy-container-app.sh` deploys Azure resources from environment variables and publishes `function-app/`
- `bootstrap-github-actions.sh` configures GitHub OIDC and writes required GitHub secrets

The old Key Vault seeding script and dedicated Function App deployment script are no longer part of the active path.
