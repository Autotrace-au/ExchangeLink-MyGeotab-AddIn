# FleetBridge Client Configuration

This document contains the configuration values you need to provide to clients who will use the FleetBridge MyGeotab Add-In.

## Configuration Values

Clients need to enter **one value** in the **Sync** tab of the FleetBridge Add-In:

### Client API Key (Unique per Client)
```
Generate using: ./azure-function/onboard-client.sh
```
- **Unique to each client** - never share between clients
- Generated when you onboard a new client
- Used to identify the client and retrieve their MyGeotab credentials from Key Vault
- **This is the ONLY secret clients need** - simpler and more secure!

**Note:** The backend now uses the Azure Container App base URL (`https://exchange-calendar-processor.mangosmoke-ee55f1a9.australiaeast.azurecontainerapps.io`). Endpoints no longer require a Function Key.

## Onboarding a New Client

Run this command to generate a unique API key for each client:

```bash
cd azure-function
chmod +x onboard-client.sh
./onboard-client.sh "Client Name" "mygeotab-database" "username" "password"
```

**Example:**
```bash
./onboard-client.sh "Garage of Awesome" "garageofawesome" "admin@garageofawesome.com.au" "their-password"
```

This will:
1. Generate a unique API key (e.g., `a1b2c3d4e5f6...`)
2. Store their MyGeotab credentials securely in Azure Key Vault
3. Output the API key to send to the client

## How to Regenerate Function Key (if needed)

**No longer needed!** The Azure Function endpoints are now public (Anonymous auth level). Security is handled by validating the unique Client API Key in the function code instead of using a shared Function Key.

Benefits:
- ✅ **No shared secrets** between clients
- ✅ **Simpler for clients** - only one key to manage
- ✅ **Better security** - compromise of one client doesn't affect others
- ✅ **Individual revocation** - can disable one client's API key without affecting others

## Setup Instructions for Clients

Send clients these instructions:

---

### FleetBridge Add-In Setup

1. **Install the Add-In** in MyGeotab (if not already installed)

2. **Open the Add-In** and click the **Sync** tab

3. **Enter Your Client API Key:**
   - **Client API Key:** `<unique-key-provided-by-administrator>`

4. **Click "Save Configuration"**

5. **Click "Test Connection"** to verify it works

6. **Connect to Exchange:**
   - Click "Connect to Exchange" button
   - Sign in with your Microsoft account
   - Grant the requested permissions
   - Close the popup when complete

7. **Test Sync:**
   - Click "Trigger Sync Now"
   - Monitor the results

---

## Security Notes

- **Client API Key** is unique per client and must be kept confidential
- No shared secrets between clients (each has their own API key)
- Client MyGeotab credentials are stored securely in Azure Key Vault (never in the Add-In)
- OAuth tokens (for Exchange) are stored securely in Azure Key Vault
- Each client's Exchange connection is isolated by their unique API key
- API keys can be revoked individually without affecting other clients

## Multi-Tenant Isolation

Client isolation works as follows:

- **Client Identification:** Unique API key generated during onboarding
- **Authentication:** Azure Function validates the API key exists in Key Vault before processing requests
- **MyGeotab Credentials:** Stored per client in Key Vault as `client-{api-key}-database`, `client-{api-key}-username`, `client-{api-key}-password`
- **OAuth Tokens:** Stored per client in Key Vault as `client-{api-key}-exchange-refresh-token`
- **Exchange Access:** Each client grants permissions to their own Microsoft 365 tenant

Data is completely isolated because:
1. Each has a unique Client API Key (no shared secrets)
2. Their MyGeotab credentials are stored with their API key in Key Vault
3. Each grants OAuth consent to their own Microsoft 365 tenant
4. All tokens and credentials are stored with unique client-specific keys
5. The Azure Function validates each API key before retrieving any credentials
