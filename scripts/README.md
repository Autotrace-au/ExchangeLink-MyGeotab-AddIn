# Scripts

This directory is reserved for operational scripts that support the single-tenant Function App deployment model.

Examples:

- deploy infrastructure wrappers
- seed Key Vault secrets
- validate Exchange prerequisites

Historical scripts for the prior container-app and SaaS model now live under `../legacy/scripts/`.

Current script:

- `deploy-function-app.sh` deploys `infra/main.bicep` and then publishes `function-app/`
- `seed-key-vault-secrets.sh` stores the required single-tenant MyGeotab and Exchange secrets in Key Vault

The repository-level one-run deployment entry point is `.github/workflows/deploy-single-tenant.yml`.
