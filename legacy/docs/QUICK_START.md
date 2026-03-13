# FleetBridge Quick Start Guide

Get your multi-tenant FleetBridge system up and running in 30 minutes!

## What You're Building

A production-ready SaaS system where:
- Multiple clients can use the same Azure Function
- Each client gets their own API key
- Client credentials stored securely in Azure Key Vault
- Usage tracked automatically for billing
- Scales from 1 to 1000+ clients

## Prerequisites

1. **Azure Subscription** - You'll need an active Azure subscription
2. **Azure CLI** - Install: `brew install azure-cli`
3. **Azure Functions Core Tools** - Install:
   ```bash
   brew tap azure/functions
   brew install azure-functions-core-tools@4
   ```
4. **Python 3.11** - Install: `brew install python@3.11`

## Step 1: Deploy the Azure Function (10 minutes)

```bash
# Clone the repo (if you haven't already)
cd /Users/sam/Git/FleetBridge-MyGeotab-AddIn-1

# Navigate to the function directory
cd azure-function

# Make scripts executable
chmod +x deploy-full-setup.sh onboard-client.sh

# Run the deployment script
./deploy-full-setup.sh
```

**What this does:**
- Creates Azure Resource Group
- Creates Storage Account
- Creates Key Vault
- Creates Function App
- Configures everything automatically
- Deploys the function code

**At the end, you'll get:**
- API Base URL: `https://exchange-calendar-processor.mangosmoke-ee55f1a9.australiaeast.azurecontainerapps.io`
- Function Key: `abc123...` (save this!)
- Key Vault URL: `https://fleetbridge-vault.vault.azure.net/`

## Step 2: Onboard Your First Client (5 minutes)

```bash
# Still in the azure-function directory
./onboard-client.sh "Your Company Name" "mygeotab-database" "admin@company.com" "password"
```

**Example:**
```bash
./onboard-client.sh "Acme Corp" "acme" "admin@acme.com" "SecurePass123"
```

**At the end, you'll get:**
- Client API Key: `a1b2c3d4...` (save this!)
- Configuration file: `client-configs/Acme-Corp-config.json`

## Step 3: Update the Add-In (5 minutes)

Edit `index.html` (lines 1671-1686):

```javascript
// Replace these values:
const FLEETBRIDGE_API_BASE = 'https://exchange-calendar-processor.mangosmoke-ee55f1a9.australiaeast.azurecontainerapps.io';
const AZURE_FUNCTION_KEY = 'YOUR_FUNCTION_KEY_FROM_STEP_1';
const CLIENT_API_KEY = 'YOUR_CLIENT_API_KEY_FROM_STEP_2';
```

**Commit and push:**
```bash
git add index.html
git commit -m "Configure Add-In for client: Acme Corp"
git push origin main
```

## Step 4: Update configuration.json (2 minutes)

Get the latest commit hash:
```bash
git rev-parse HEAD
```

Edit `configuration.json` and update the URL to use the new commit hash:

```json
{
    "name": "FleetBridge Property Manager",
    "supportEmail": "support@yourcompany.com",
    "version": "6.1.0",
    "items": [
        {
            "url": "https://raw.githubusercontent.com/Autotrace-au/FleetBridge-MyGeotab-AddIn/YOUR_COMMIT_HASH/index.html?v=6.1",
            "path": "ActivityLink",
            "menuName": {
                "en": "FleetBridge Property Manager"
            }
        }
    ]
}
```

**Commit and push:**
```bash
git add configuration.json
git commit -m "Update configuration to v6.1"
git push origin main
```

## Step 5: Test It! (5 minutes)

### Test 1: Health Check

```bash
curl https://exchange-calendar-processor.mangosmoke-ee55f1a9.australiaeast.azurecontainerapps.io/health
```

**Expected response:**
```json
{
  "status": "healthy",
  "timestamp": "2025-10-31T12:34:56.789Z",
  "keyVaultEnabled": true
}
```

### Test 2: Update Device Properties

```bash
curl -X POST "https://exchange-calendar-processor.mangosmoke-ee55f1a9.australiaeast.azurecontainerapps.io/api/update-device-properties" \
  -H "Content-Type: application/json" \
  -d '{
    "apiKey": "YOUR_CLIENT_API_KEY",
    "deviceId": "b1",
    "properties": {
      "bookable": true,
      "recurring": true
    }
  }'
```

**Expected response:**
```json
{
  "success": true,
  "message": "Device 2018 Mazda 3 updated successfully",
  "database": "acme",
  "deviceId": "b1"
}
```

### Test 3: In MyGeotab

1. **Remove old Add-In** (if you had one installed):
   - Go to System > System Settings > Add-Ins
   - Remove "FleetBridge Property Manager"

2. **Add new Add-In**:
   - Click "New Add-In"
   - Paste your configuration.json URL
   - Click "Add"

3. **Test the Add-In**:
   - Click "FleetBridge Property Manager" in the menu
   - Go to "Manage Assets" tab
   - Click "Load Assets"
   - Create a test group
   - Assign an asset to the group
   - Check browser console for success messages

## Step 6: Onboard More Clients (3 minutes each)

For each new client:

```bash
cd azure-function
./onboard-client.sh "Client Name" "database" "username" "password"
```

**Two options for multiple clients:**

### Option A: Single Add-In, Multiple API Keys (Easier)
- Create one Add-In per client
- Each has their own API key hardcoded
- Distribute different configuration.json URLs to each client

### Option B: Dynamic API Key (More Complex)
- Single Add-In for all clients
- Add-In prompts for API key on first use
- Store API key in localStorage
- Better for self-service onboarding

## Monitoring & Billing

### View Usage Logs

```bash
az functionapp log tail --resource-group FleetBridgeRG --name fleetbridge-mygeotab
```

### Query Usage for Billing

Go to Azure Portal > Application Insights > Logs:

```kusto
traces
| where message contains "USAGE:"
| extend usageData = parse_json(substring(message, indexof(message, "{")))
| project 
    timestamp,
    apiKey = tostring(usageData.apiKey),
    database = tostring(usageData.database),
    success = tobool(usageData.success)
| where success == true
| summarize total_requests = count() by apiKey, bin(timestamp, 1d)
```

## Cost Breakdown

**For 50 clients** (20 vehicles each, 5 updates/day):

| Service | Cost |
|---------|------|
| Azure Functions | $0-5/month (under free tier) |
| Storage Account | $1/month |
| Key Vault | $1/month |
| Application Insights | $5/month |
| **Total** | **~$10/month** |

**Your revenue** (at $99/client/month):
- 50 clients × $99 = **$4,950/month**
- **Profit: $4,940/month (99% margin!)** 💰

## Troubleshooting

### Function returns 401 Unauthorized
- Check that API key is correct
- Verify API key exists in Key Vault: `az keyvault secret list --vault-name fleetbridge-vault`

### Function returns 500 Internal Server Error
- Check logs: `az functionapp log tail --resource-group FleetBridgeRG --name fleetbridge-mygeotab`
- Verify MyGeotab credentials are correct

### Add-In not loading
- Hard refresh browser (Cmd+Shift+R)
- Check configuration.json URL is correct
- Verify commit hash in URL matches latest commit

### Properties not saving
- Check browser console for errors
- Verify AZURE_FUNCTION_URL and AZURE_FUNCTION_KEY are set correctly
- Test function directly with curl

## Next Steps

1. ✅ Deploy function
2. ✅ Onboard first client
3. ✅ Test in MyGeotab
4. 📋 Set up monitoring alerts
5. 📋 Create client onboarding documentation
6. 📋 Set up automated billing
7. 📋 Create client portal for self-service

## Support

- **Architecture Guide**: [MULTI_TENANT_ARCHITECTURE.md](MULTI_TENANT_ARCHITECTURE.md)
- **Detailed Deployment**: [DEPLOYMENT.md](DEPLOYMENT.md)
- **Function Documentation**: [azure-function/README.md](azure-function/README.md)

## Success! 🎉

You now have a production-ready multi-tenant SaaS system that:
- ✅ Scales automatically
- ✅ Costs almost nothing to run
- ✅ Tracks usage for billing
- ✅ Keeps client credentials secure
- ✅ Easy to onboard new clients
- ✅ 99% profit margin

Go get those clients! 🚀

