# FleetBridge MyGeotab Add-In - Deployment Guide

## Overview

The FleetBridge MyGeotab Add-In now uses a **Python Azure Function** to update device properties. This was necessary because the MyGeotab JavaScript SDK has persistent issues with updating custom properties (JsonSerializerException errors).

## Architecture

```
MyGeotab Add-In (JavaScript)
    ↓
Azure Function (Python)
    ↓
MyGeotab API (Python SDK)
```

## Prerequisites

1. **Azure Subscription** - You'll need an active Azure subscription
2. **Azure CLI** - Install: `brew install azure-cli`
3. **Azure Functions Core Tools** - Install: `brew install azure-functions-core-tools@4`
4. **Python 3.9+** - Check: `python3 --version`

## Step 1: Deploy the Azure Function

### 1.1 Login to Azure

```bash
az login
```

### 1.2 Create Resource Group

```bash
az group create \
  --name FleetBridgeRG \
  --location australiaeast
```

### 1.3 Create Storage Account

```bash
az storage account create \
  --name fleetbridgestore \
  --resource-group FleetBridgeRG \
  --location australiaeast \
  --sku Standard_LRS
```

### 1.4 Create Function App

```bash
az functionapp create \
  --resource-group FleetBridgeRG \
  --consumption-plan-location australiaeast \
  --runtime python \
  --runtime-version 3.11 \
  --functions-version 4 \
  --name fleetbridge-mygeotab \
  --storage-account fleetbridgestore \
  --os-type Linux
```

### 1.5 Deploy the Function

```bash
cd azure-function
func azure functionapp publish fleetbridge-mygeotab
```

### 1.6 Get the Function URL and Key

```bash
# Get the function key
az functionapp keys list \
  --resource-group FleetBridgeRG \
  --name fleetbridge-mygeotab \
  --query "functionKeys.default" \
  --output tsv
```

The function URL will be:
```
https://exchange-calendar-processor.mangosmoke-ee55f1a9.australiaeast.azurecontainerapps.io/api/update-device-properties
```

## Step 2: Configure CORS (Important!)

The Add-In runs in MyGeotab's domain, so we need to allow CORS:

```bash
az functionapp cors add \
  --resource-group FleetBridgeRG \
  --name fleetbridge-mygeotab \
  --allowed-origins "https://*.geotab.com" "https://*.geotab.com.au"
```

## Step 3: Update the Add-In Configuration

Edit `index.html` and update these lines (around line 1671):

```javascript
const FLEETBRIDGE_API_BASE = 'https://exchange-calendar-processor.mangosmoke-ee55f1a9.australiaeast.azurecontainerapps.io';
const AZURE_FUNCTION_KEY = 'YOUR_FUNCTION_KEY_FROM_STEP_1.6';
```

## Step 4: Commit and Push

```bash
git add index.html
git commit -m "Configure Azure Function endpoint"
git push origin main
```

## Step 5: Update configuration.json

Update the commit hash in `configuration.json` to point to the latest commit:

```json
{
    "name": "FleetBridge Property Manager",
    "supportEmail": "your-email@example.com",
    "version": "6.0.0",
    "items": [
        {
            "url": "https://raw.githubusercontent.com/Autotrace-au/FleetBridge-MyGeotab-AddIn/LATEST_COMMIT_HASH/index.html?v=6.0",
            "path": "ActivityLink",
            "menuName": {
                "en": "FleetBridge Property Manager"
            }
        }
    ]
}
```

## Step 6: Test the Add-In

1. **Remove the old Add-In** from MyGeotab (if installed)
2. **Add the Add-In** using the updated configuration.json URL
3. **Go to the Manage Assets tab**
4. **Load assets**
5. **Create a test group** with some properties
6. **Assign an asset to the group**
7. **Check the console** - you should see "Azure Function response: {success: true, ...}"
8. **Verify in MyGeotab** - check the device's custom properties

## Troubleshooting

### CORS Errors

If you see CORS errors in the console:

```bash
# Add more specific origins
az functionapp cors add \
  --resource-group FleetBridgeRG \
  --name fleetbridge-mygeotab \
  --allowed-origins "https://goac.geotab.com.au"
```

### Function Not Found

Check the function is deployed:

```bash
az functionapp function list \
  --resource-group FleetBridgeRG \
  --name fleetbridge-mygeotab
```

### Authentication Errors

The function uses the MyGeotab session ID for authentication. If you see authentication errors, it might be because:
- The session has expired (user needs to refresh MyGeotab)
- The session ID isn't being passed correctly

Check the console logs to see what's being sent to the function.

### View Function Logs

```bash
az functionapp log tail \
  --resource-group FleetBridgeRG \
  --name fleetbridge-mygeotab
```

Or view logs in the Azure Portal:
1. Go to https://portal.azure.com
2. Navigate to your Function App
3. Click "Log stream" in the left menu

## Local Testing

You can test the Azure Function locally before deploying:

```bash
cd azure-function
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
func start
```

Then test with curl:

```bash
curl -X POST http://localhost:7071/api/update-device-properties \
  -H "Content-Type: application/json" \
  -d '{
    "database": "your_database",
    "username": "your_username",
    "password": "your_password",
    "deviceId": "b1",
    "properties": {
      "bookable": true,
      "recurring": true,
      "approvers": "email@example.com",
      "fleetManagers": "",
      "conflicts": false,
      "windowDays": 3,
      "maxDurationHours": 48,
      "language": "en-AU"
    }
  }'
```

## Cost Estimate

Azure Functions Consumption Plan pricing:
- **First 1 million executions per month**: FREE
- **After that**: $0.20 USD per million executions
- **Memory**: $0.000016 USD per GB-second

For typical usage (updating properties a few times per day):
- **Estimated cost**: $0-5 USD per month

## Security Considerations

1. **Function Key**: Keep the function key secret. Don't commit it to public repositories.
2. **CORS**: Only allow specific MyGeotab domains
3. **Credentials**: Consider using Azure Key Vault for storing MyGeotab credentials in production
4. **HTTPS Only**: The function only accepts HTTPS requests

## Alternative: Use Existing Azure Resources

If you already have Azure resources, you can:
- Use an existing Resource Group
- Use an existing Storage Account
- Use an existing Function App (just deploy the function to it)

Just adjust the commands above to use your existing resource names.

## Need Help?

- Check the Azure Function logs for detailed error messages
- Check the browser console for client-side errors
- Review the `azure-function/README.md` for more details on the function itself

