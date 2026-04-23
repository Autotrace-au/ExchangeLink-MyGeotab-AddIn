# Documentation

This directory describes the current ExchangeLink product and deployment model.

- [`ARCHITECTURE.md`](ARCHITECTURE.md): system shape, runtime responsibilities, and data flow
- [`DEPLOYMENT.md`](DEPLOYMENT.md): Azure/GitHub deployment model, required configuration, and smoke testing
- [`NEW_TENANT_DEPLOYMENT.md`](NEW_TENANT_DEPLOYMENT.md): end-to-end onboarding runbook for a new customer or environment

The repository now assumes a single-tenant backend deployment with a shared add-in and a customer-specific backend URL. Historical deployment paths and retired architecture notes should be treated as obsolete unless they still exist in git history for reference.
