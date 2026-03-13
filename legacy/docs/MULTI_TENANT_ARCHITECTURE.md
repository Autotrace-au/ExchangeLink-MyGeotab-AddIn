# FleetBridge Multi-Tenant SaaS Architecture

## Overview

This document outlines the architecture for running FleetBridge as a paid subscription service for multiple clients.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         Client 1                                 │
│  ┌──────────────┐         ┌──────────────┐                      │
│  │  MyGeotab    │────────▶│   Add-In     │                      │
│  │  (Browser)   │         │ (JavaScript) │                      │
│  └──────────────┘         └──────┬───────┘                      │
└─────────────────────────────────┼─────────────────────────────┘
                                   │ HTTPS + API Key
                                   │
┌─────────────────────────────────▼─────────────────────────────┐
│                      Your Azure Subscription                    │
│                                                                  │
│  ┌────────────────────────────────────────────────────────┐   │
│  │           Azure Function (Python)                       │   │
│  │  - Validates API key                                    │   │
│  │  - Gets credentials from Key Vault                      │   │
│  │  - Updates MyGeotab via Python SDK                      │   │
│  │  - Logs usage for billing                               │   │
│  └────────────┬───────────────────────┬────────────────────┘   │
│               │                       │                          │
│  ┌────────────▼──────────┐  ┌────────▼──────────┐             │
│  │   Azure Key Vault     │  │  Application      │             │
│  │  - Client credentials │  │  Insights         │             │
│  │  - API keys           │  │  - Usage logs     │             │
│  └───────────────────────┘  │  - Monitoring     │             │
│                              └───────────────────┘             │
│                                                                  │
│  ┌────────────────────────────────────────────────────────┐   │
│  │        Azure Automation (Nightly Sync)                  │   │
│  │  - Syncs devices to Exchange                            │   │
│  │  - Runs once per night per client                       │   │
│  └────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────┘
                                   │
                                   │ MyGeotab Python SDK
                                   │
┌─────────────────────────────────▼─────────────────────────────┐
│                    Client MyGeotab Accounts                     │
│  - Client 1: database1.geotab.com                              │
│  - Client 2: database2.geotab.com                              │
│  - Client 3: database3.geotab.com.au                           │
└──────────────────────────────────────────────────────────────┘
```

## Phased Rollout Plan

### Phase 1: MVP (First 10 Clients) - Start Here

**Goal**: Get clients onboarded quickly with minimal complexity

**Architecture**:
- ✅ Azure Function with direct credentials (no Key Vault yet)
- ✅ Simple usage logging to Application Insights
- ✅ Manual client onboarding
- ✅ Azure Automation for nightly sync

**Setup**:
1. Deploy `function_app.py` (the simple version)
2. Each client gets the Add-In configuration with your function URL
3. Add-In sends MyGeotab credentials with each request
4. Track usage via Application Insights logs

**Cost**: ~$0-10/month for 10 clients

**Pros**:
- Quick to deploy
- No credential management needed
- Easy to debug

**Cons**:
- Credentials sent with every request
- No easy way to revoke access
- Manual billing based on logs

### Phase 2: Growth (10-50 Clients)

**Goal**: Add proper multi-tenancy and automated billing

**Architecture**:
- ✅ Azure Function with Key Vault integration
- ✅ API key per client
- ✅ Automated usage tracking
- ✅ Client portal for self-service

**Setup**:
1. Deploy `function_app_multitenant.py`
2. Set up Azure Key Vault
3. Create API key for each client
4. Store client credentials in Key Vault
5. Update Add-In to use API keys

**Cost**: ~$10-50/month for 50 clients

**New Features**:
- API key authentication
- Credential storage in Key Vault
- Usage tracking per client
- Ability to revoke access
- Audit trail

### Phase 3: Scale (50+ Clients)

**Goal**: Enterprise-grade reliability and performance

**Architecture**:
- ✅ Azure Functions Premium Plan (no cold starts)
- ✅ Azure SQL Database for usage tracking
- ✅ Automated billing integration
- ✅ Rate limiting per client
- ✅ Multi-region deployment

**Cost**: ~$100-500/month for 100+ clients

## Detailed Setup Guide

### Phase 1 Setup (Start Here)

#### 1. Deploy Azure Function

```bash
# Use the simple function_app.py
cd azure-function
func azure functionapp publish fleetbridge-mygeotab
```

#### 2. Configure CORS

```bash
az functionapp cors add \
  --resource-group FleetBridgeRG \
  --name fleetbridge-mygeotab \
  --allowed-origins "https://*.geotab.com" "https://*.geotab.com.au"
```

#### 3. Get Function URL and Key

```bash
az functionapp keys list \
  --resource-group FleetBridgeRG \
  --name fleetbridge-mygeotab \
  --query "functionKeys.default" \
  --output tsv
```

#### 4. Client Onboarding

For each new client:

1. **Create Add-In configuration** (`client-config.json`):
```json
{
    "name": "FleetBridge Property Manager",
    "supportEmail": "support@yourcompany.com",
    "version": "6.0.0",
    "items": [
        {
            "url": "https://raw.githubusercontent.com/Autotrace-au/FleetBridge-MyGeotab-AddIn/COMMIT_HASH/index.html?v=6.0",
            "path": "ActivityLink",
            "menuName": {
                "en": "FleetBridge Property Manager"
            }
        }
    ]
}
```

2. **Update Add-In with your function URL**:
   - Edit `index.html` lines 1671-1672
   - Set `AZURE_FUNCTION_URL` and `AZURE_FUNCTION_KEY`

3. **Send to client**:
   - Configuration JSON URL
   - Installation instructions
   - Support contact

4. **Track in spreadsheet**:
   - Client name
   - MyGeotab database name
   - Start date
   - Subscription tier

#### 5. Monitor Usage

View usage logs in Application Insights:

```bash
az monitor app-insights query \
  --app fleetbridge-insights \
  --analytics-query "traces | where message contains 'USAGE:' | project timestamp, message"
```

Or in Azure Portal:
1. Go to Application Insights
2. Click "Logs"
3. Query: `traces | where message contains "USAGE:"`

### Phase 2 Setup (When You Have 10+ Clients)

#### 1. Create Azure Key Vault

```bash
az keyvault create \
  --name fleetbridge-vault \
  --resource-group FleetBridgeRG \
  --location australiaeast
```

#### 2. Grant Function App Access to Key Vault

```bash
# Enable managed identity for Function App
az functionapp identity assign \
  --resource-group FleetBridgeRG \
  --name fleetbridge-mygeotab

# Get the principal ID
PRINCIPAL_ID=$(az functionapp identity show \
  --resource-group FleetBridgeRG \
  --name fleetbridge-mygeotab \
  --query principalId \
  --output tsv)

# Grant access to Key Vault
az keyvault set-policy \
  --name fleetbridge-vault \
  --object-id $PRINCIPAL_ID \
  --secret-permissions get list
```

#### 3. Deploy Multi-Tenant Function

```bash
# Replace function_app.py with function_app_multitenant.py
cp function_app_multitenant.py function_app.py

# Set environment variables
az functionapp config appsettings set \
  --resource-group FleetBridgeRG \
  --name fleetbridge-mygeotab \
  --settings \
    "KEY_VAULT_URL=https://fleetbridge-vault.vault.azure.net/" \
    "USE_KEY_VAULT=true"

# Deploy
func azure functionapp publish fleetbridge-mygeotab
```

#### 4. Onboard Client with API Key

For each new client:

```bash
# Generate unique API key
API_KEY=$(uuidgen | tr '[:upper:]' '[:lower:]')

# Store client credentials in Key Vault
az keyvault secret set \
  --vault-name fleetbridge-vault \
  --name "client-${API_KEY}-database" \
  --value "client-database-name"

az keyvault secret set \
  --vault-name fleetbridge-vault \
  --name "client-${API_KEY}-username" \
  --value "client@example.com"

az keyvault secret set \
  --vault-name fleetbridge-vault \
  --name "client-${API_KEY}-password" \
  --value "client-password"

# Give API key to client
echo "Client API Key: $API_KEY"
```

#### 5. Update Add-In for API Key Mode

Update `index.html` to send API key instead of credentials:

```javascript
const payload = {
    apiKey: 'CLIENT_API_KEY_HERE',  // Instead of database/username/password
    deviceId: deviceId,
    properties: properties
};
```

## Billing & Usage Tracking

### Extracting Usage Data

Query Application Insights for billing:

```kusto
traces
| where message contains "USAGE:"
| extend usageData = parse_json(substring(message, indexof(message, "{")))
| project 
    timestamp,
    database = tostring(usageData.database),
    operation = tostring(usageData.operation),
    success = tobool(usageData.success),
    execution_time_ms = todouble(usageData.execution_time_ms)
| where success == true
| summarize 
    total_requests = count(),
    avg_response_time = avg(execution_time_ms)
    by database, bin(timestamp, 1d)
```

### Pricing Tiers

**Suggested pricing**:
- **Starter**: $49/month - Up to 10 vehicles, 100 property updates/month
- **Professional**: $99/month - Up to 50 vehicles, 500 property updates/month
- **Enterprise**: $299/month - Unlimited vehicles, unlimited updates

**Your costs**:
- Azure Functions: ~$0-5/month (under free tier for most usage)
- Azure Automation: ~$10/month per client (for nightly sync)
- Key Vault: ~$1/month
- Application Insights: ~$5/month

**Profit margin**: 80-90% 🎉

## Security Best Practices

1. **Always use HTTPS** - Function enforces this by default
2. **Rotate API keys** - Every 90 days for security
3. **Monitor for abuse** - Set up alerts for unusual usage patterns
4. **Rate limiting** - Implement per-client rate limits in Phase 3
5. **Audit logs** - Keep all usage logs for 12 months

## Scaling Considerations

### When to Upgrade to Premium Plan

Consider Azure Functions Premium Plan when:
- You have 100+ clients
- Cold starts are causing issues (first request slow)
- You need VNet integration
- You need longer execution times

**Cost**: ~$150/month minimum

### When to Add Multiple Regions

Consider multi-region deployment when:
- You have clients in multiple continents
- You need 99.99% uptime SLA
- Latency is critical

## Support & Monitoring

### Set Up Alerts

```bash
# Alert on function failures
az monitor metrics alert create \
  --name "FleetBridge Function Failures" \
  --resource-group FleetBridgeRG \
  --scopes "/subscriptions/YOUR_SUB/resourceGroups/FleetBridgeRG/providers/Microsoft.Web/sites/fleetbridge-mygeotab" \
  --condition "count FunctionExecutionCount < 1" \
  --window-size 5m \
  --evaluation-frequency 1m
```

### Dashboard

Create an Azure Dashboard showing:
- Total requests per day
- Requests per client
- Average response time
- Error rate
- Cost per client

## Next Steps

1. **Start with Phase 1** - Deploy simple function, onboard first clients
2. **Gather feedback** - Learn what features clients need
3. **Plan Phase 2** - When you hit 10 clients, implement API keys
4. **Scale gradually** - Don't over-engineer too early

## Questions?

- **How do I handle client cancellations?** - Delete their API key from Key Vault
- **Can clients use their own Azure?** - Yes, they can deploy the function themselves
- **What about data residency?** - Deploy functions in client's region (AU, US, EU)
- **How do I update the Add-In?** - Update GitHub, clients refresh (or use versioning)

