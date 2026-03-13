# FleetBridge Deployment Complete

## Deployment Summary

Your FleetBridge multi-tenant Azure Function has been successfully deployed!

### Azure Resources Created

| Resource | Name | Location |
|----------|------|----------|
| **Resource Group** | FleetBridgeRG | Australia East |
| **Storage Account** | fleetbridgestore | Australia East |
| **Key Vault** | fleetbridge-vault | Australia East |
| **Function App** | fleetbridge-mygeotab | Australia East |
| **Application Insights** | fleetbridge-mygeotab | Australia East |

### Function Endpoints

#### Health Check (Public)
```
https://exchange-calendar-processor.mangosmoke-ee55f1a9.australiaeast.azurecontainerapps.io/health
```
Status: Healthy (Key Vault enabled)

#### Update Device Properties (Authenticated)
```
https://exchange-calendar-processor.mangosmoke-ee55f1a9.australiaeast.azurecontainerapps.io/api/update-device-properties
```
Requires: Function key authentication

### Function Key

**IMPORTANT**: Your function key has been saved to `.azure-function-key.txt` (git-ignored).

To retrieve it again:
```bash
az functionapp keys list \
  --resource-group FleetBridgeRG \
  --name fleetbridge-mygeotab \
  --query "functionKeys.default" \
  --output tsv
```

**Security Note**: This key should be kept private and never committed to a public repository.

---

## Next Steps

### 1. Configure the Add-In in MyGeotab (Easy!)

**No need for private versions!** The Add-In now has a built-in configuration UI:

1. **Install the Add-In** in MyGeotab:
   - Go to **Administration → System → System Settings → Add-Ins**
   - Click **New Add-In**
   - Paste this URL:
     ```
     https://cdn.jsdelivr.net/gh/Autotrace-au/FleetBridge-MyGeotab-AddIn@main/configuration.json
     ```
   - Click **Save** and refresh your browser

2. **Configure Azure Function Settings**:
   - In MyGeotab, go to **Administration → FleetBridge Properties**
   - Click the **Sync to Exchange** tab
   - In the **Azure Function Configuration** section, enter:
  - **API Base URL**: `https://exchange-calendar-processor.mangosmoke-ee55f1a9.australiaeast.azurecontainerapps.io`
     - **Function Key**: Your function key (from `.azure-function-key.txt`)
     - **Client API Key**: Leave blank for now (optional, for multi-tenant)
   - Click **Save Configuration**
   - Click **Test Connection** to verify it works

3. **Done!** The configuration is stored securely in your browser's localStorage

### 2. Verify Installation

Check that the Add-In is working:

1. In MyGeotab, go to **Administration → FleetBridge Properties**
2. You should see three tabs: **Property Setup**, **Manage Assets**, **Sync to Exchange**
3. The **Sync to Exchange** tab should show the Azure Function Configuration section
4. Enter your configuration and test the connection

### 3. Onboard Your First Client

Use the onboarding script to add your first client:

```bash
cd azure-function
./onboard-client.sh
```

This will:
- Generate a unique API key for the client
- Store their MyGeotab credentials in Key Vault
- Create a client configuration file
- Provide testing instructions

### 4. Test the Integration

**Test with Direct Credentials (No API Key)**:
```bash
# Get your function key first
FUNCTION_KEY=$(az functionapp keys list --resource-group FleetBridgeRG --name fleetbridge-mygeotab --query "functionKeys.default" --output tsv)

curl -X POST "https://exchange-calendar-processor.mangosmoke-ee55f1a9.australiaeast.azurecontainerapps.io/api/update-device-properties" \
  -H "Content-Type: application/json" \
  -d '{
    "database": "your_database",
    "username": "your_username",
    "password": "your_password",
    "deviceId": "b1",
    "properties": {
      "bookable": true,
      "recurring": true,
      "approvers": "test@example.com"
    }
  }'
```

**Test with API Key (After Onboarding)**:
```bash
# Get your function key first
FUNCTION_KEY=$(az functionapp keys list --resource-group FleetBridgeRG --name fleetbridge-mygeotab --query "functionKeys.default" --output tsv)

curl -X POST "https://exchange-calendar-processor.mangosmoke-ee55f1a9.australiaeast.azurecontainerapps.io/api/update-device-properties" \
  -H "Content-Type: application/json" \
  -d '{
    "apiKey": "client-api-key-here",
    "deviceId": "b1",
    "properties": {
      "bookable": true,
      "recurring": true,
      "approvers": "test@example.com"
    }
  }'
```

### 5. Monitor Usage

View logs in Application Insights:
```bash
# Open Application Insights in Azure Portal
az portal open --resource-id "/subscriptions/6bf8f63b-8021-4a51-9bfc-3c79363abeab/resourceGroups/FleetBridgeRG/providers/microsoft.insights/components/fleetbridge-mygeotab"
```

Or query logs with Azure CLI:
```bash
az monitor app-insights query \
  --app fleetbridge-mygeotab \
  --resource-group FleetBridgeRG \
  --analytics-query "traces | where message contains 'USAGE' | order by timestamp desc | take 100"
```

---

## Cost Estimate

Based on your deployment:

| Service | Plan | Estimated Cost |
|---------|------|----------------|
| **Function App** | Consumption | $0-5/month (first 1M executions free) |
| **Storage Account** | Standard LRS | $0.50/month |
| **Key Vault** | Standard | $0.03/month (per 10K operations) |
| **Application Insights** | Pay-as-you-go | $2-5/month (first 5GB free) |
| **Total** | | **~$3-10/month** |

For 50 clients with 100 requests/day each:
- 150,000 requests/month = Well within free tier
- **Total cost: ~$3-5/month**

---

## Important URLs

### Azure Portal
- **Resource Group**: https://portal.azure.com/#resource/subscriptions/6bf8f63b-8021-4a51-9bfc-3c79363abeab/resourceGroups/FleetBridgeRG
- **Function App**: https://portal.azure.com/#resource/subscriptions/6bf8f63b-8021-4a51-9bfc-3c79363abeab/resourceGroups/FleetBridgeRG/providers/Microsoft.Web/sites/fleetbridge-mygeotab
- **Key Vault**: https://portal.azure.com/#resource/subscriptions/6bf8f63b-8021-4a51-9bfc-3c79363abeab/resourceGroups/FleetBridgeRG/providers/Microsoft.KeyVault/vaults/fleetbridge-vault
- **Application Insights**: https://portal.azure.com/#resource/subscriptions/6bf8f63b-8021-4a51-9bfc-3c79363abeab/resourceGroups/FleetBridgeRG/providers/microsoft.insights/components/fleetbridge-mygeotab

### GitHub
- **Repository**: https://github.com/Autotrace-au/FleetSync-MyGeotab-AddIn (needs renaming to FleetBridge-MyGeotab-AddIn)
- **Latest Commit**: efa0f4e621120b412a5db08b826c1fa7bb78c66a

---

## Troubleshooting

### Function Not Working
1. Check health endpoint: `curl https://exchange-calendar-processor.mangosmoke-ee55f1a9.australiaeast.azurecontainerapps.io/health`
2. View logs in Application Insights
3. Verify Key Vault permissions: Function App should have "Key Vault Secrets User" role

### Key Vault Access Denied
```bash
# Re-grant access
az role assignment create \
  --role "Key Vault Secrets User" \
  --assignee "51119296-cac0-4f0a-a866-cd145c164547" \
  --scope "/subscriptions/6bf8f63b-8021-4a51-9bfc-3c79363abeab/resourceGroups/FleetBridgeRG/providers/Microsoft.KeyVault/vaults/fleetbridge-vault"
```

### CORS Issues
```bash
# Add additional origins if needed
az functionapp cors add \
  --resource-group FleetBridgeRG \
  --name fleetbridge-mygeotab \
  --allowed-origins "https://your-domain.com"
```

---

## What's Next?

1. **Rename GitHub Repository** to `FleetBridge-MyGeotab-AddIn`
2. **Create Private Version** of index.html with function key
3. **Onboard First Client** using `onboard-client.sh`
4. **Test Integration** with MyGeotab
5. **Set Up Monitoring** in Application Insights
6. **Document Billing Process** for clients

---

## Support

For issues or questions:
- **Email**: sam@garageofawesome.com.au
- **Documentation**: See QUICK_START.md, MULTI_TENANT_ARCHITECTURE.md, DEPLOYMENT.md
- **Azure Support**: https://portal.azure.com/#blade/Microsoft_Azure_Support/HelpAndSupportBlade

---

**Congratulations! Your FleetBridge multi-tenant SaaS platform is now live!**

