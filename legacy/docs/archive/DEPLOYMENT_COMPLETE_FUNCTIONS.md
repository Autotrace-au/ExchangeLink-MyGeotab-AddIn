# (Archive) Azure Functions Calendar Processing Deployment Complete

Legacy Azure Functions deployment summary retained for reference now that Container App supersedes this approach.

## Key Points
- Hybrid Python + PowerShell approach on Linux
- Certificate (PFX base64) stored in Key Vault
- Managed identity used for secret retrieval
- Function endpoints provided sync & test operations

## Replacement
Container App implementation replaced this architecture due to better scaling, native PowerShell, and cost advantages.
