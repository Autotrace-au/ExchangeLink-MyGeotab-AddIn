# FleetBridge Architecture - 2-Component Design

## Overview

FleetBridge is a **streamlined 2-component SaaS platform** that synchronizes MyGeotab vehicle data with Microsoft Exchange equipment mailboxes for calendar-based bookings.

**Components:**
1. **MyGeotab Add-In** (JavaScript/HTML) - Browser-based UI
2. **Azure Function App** (Python) - All server-side processing

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         END USER                                 │
│                      (Fleet Manager)                             │
└──────────────┬──────────────────────────────────────────────────┘
               │
               │ Opens MyGeotab Web UI
               ▼
┌──────────────────────────────────────────────────────────────────┐
│                      MyGeotab Platform                           │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │        FleetBridge Add-In (index.html)                     │ │
│  │  - Property Setup                                          │ │
│  │  - Manage Assets (configure devices)                       │ │
│  │  - Sync to Exchange (trigger sync)                         │ │
│  └────────────┬───────────────────────────────────────────────┘ │
└───────────────┼──────────────────────────────────────────────────┘
                │
                │ HTTPS + Function Key Auth
                ▼
┌──────────────────────────────────────────────────────────────────┐
│         Azure Function App (fleetbridge-mygeotab)                │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │   Endpoint 1: /api/update-device-properties               │  │
│  │   - Updates custom properties on MyGeotab devices         │  │
│  │   - Uses MyGeotab Python SDK                              │  │
│  └───────────────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │   Endpoint 2: /api/sync-to-exchange                       │  │
│  │   - Fetches devices from MyGeotab                         │  │
│  │   - Updates Exchange mailboxes via Graph API              │  │
│  │   - Applies booking rules, calendar settings              │  │
│  └───────────────────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │   Endpoint 3: /api/health                                 │  │
│  │   - Health check (no auth required)                       │  │
│  └───────────────────────────────────────────────────────────┘  │
└──────────┬───────────────────────────────────┬──────────────────┘
           │                                    │
           │ MyGeotab SDK                       │ Microsoft Graph + Certificate Auth
           ▼                                    ▼
┌─────────────────────────┐    ┌──────────────────────────────────┐
│  MyGeotab REST API      │    │   Microsoft Graph API            │
│  - Get/Set Device data  │    │   - Update mailbox settings      │
│  - Custom properties    │    │   - Calendar configuration       │
└─────────────────────────┘    │   - Regional settings            │
                               └──────────────────────────────────┘
                                               │
                                               ▼
                               ┌──────────────────────────────────┐
                               │   Exchange Online                │
                               │   - Equipment mailboxes          │
                               │   - Calendar bookings            │
                               └──────────────────────────────────┘
```

---

## Authentication Flows

### 1. Add-In → Azure Function (Update Properties)

```
User Action: Configure device properties in "Manage Assets" tab
              ↓
Add-In JavaScript: Calls /api/update-device-properties
              ↓
              Headers: { "x-functions-key": "<function-key>" }
              Body: {
                  "apiKey": "<client-api-key>",  // Multi-tenant
                  "deviceId": "b123",
                  "properties": { "bookable": true, ... }
              }
              ↓
Azure Function: 
    1. Validates function key (Azure built-in auth)
    2. Retrieves MyGeotab credentials from Key Vault using apiKey
    3. Authenticates to MyGeotab API
    4. Updates device custom properties
    5. Returns success/failure
```

### 2. Add-In → Azure Function → Exchange (Sync)

```
User Action: Click "Trigger Sync Now" in "Sync to Exchange" tab
              ↓
Add-In JavaScript: Calls /api/sync-to-exchange
              ↓
              Headers: { "x-functions-key": "<function-key>" }
              Body: {
                  "apiKey": "<client-api-key>",
                  "maxDevices": 10  // Optional testing limit
              }
              ↓
Azure Function:
    1. Validates function key
    2. Retrieves MyGeotab credentials from Key Vault
    3. Authenticates to MyGeotab → Fetches all devices
    4. Retrieves certificate from Key Vault
    5. Authenticates to Microsoft Graph using certificate
    6. For each device with SerialNumber:
        a. Find mailbox by serial@equipmentdomain.com
        b. Update display name, timezone, language
        c. Apply booking rules (conflicts, approvers, etc.)
        d. Grant Fleet Manager calendar access
        e. Set default calendar visibility
    7. Returns summary: { processed, successful, failed, results[] }
```

### 3. Entra App → Microsoft Graph (Certificate Auth)

```
Azure Function: Needs to access Exchange mailboxes
              ↓
Step 1: Get certificate from Key Vault
    - Function's Managed Identity authenticates to Key Vault
    - Downloads PFX certificate
              ↓
Step 2: Authenticate to Microsoft Graph
    - CertificateCredential(tenant_id, client_id, cert_path)
    - Gets access token from Entra ID
    - Token scope: https://graph.microsoft.com/.default
              ↓
Step 3: Call Graph API
    - GET /users/{id}/mailboxSettings
    - PATCH /users/{id} (update properties)
    - GET/UPDATE /users/{id}/calendar/permissions
              ↓
Microsoft Graph → Exchange Online
    - Updates mailbox regional settings
    - Configures calendar processing rules
    - Grants delegate permissions
```

---

## Multi-Tenant Data Flow

### Client Onboarding

```bash
# Run onboarding script
./onboard-client.sh "Acme Corp" "acme_db" "user@acme.com" "password"

# Script actions:
1. Generates unique API key: acme-corp-a1b2c3d4
2. Stores in Azure Key Vault:
   - Secret: client-acme-corp-a1b2c3d4-database = "acme_db"
   - Secret: client-acme-corp-a1b2c3d4-username = "user@acme.com"
   - Secret: client-acme-corp-a1b2c3d4-password = "password"
3. Creates config file: client-configs/Acme-Corp-config.json
4. Returns API key to client
```

### Runtime - Property Update

```
1. Client enters API key in Add-In "Sync to Exchange" tab
2. Add-In stores in localStorage: fleetSyncClientApiKey
3. When updating properties:
   - Add-In sends: { "apiKey": "acme-corp-a1b2c3d4", ... }
   - Function looks up: Key Vault secrets with prefix "client-acme-corp-a1b2c3d4-*"
   - Function retrieves: database, username, password
   - Function connects to MyGeotab using those credentials
4. Usage logged for billing: { database, operation, success, execution_time_ms }
```

---

## Key Vault Structure

```
Azure Key Vault: fleetbridge-vault

├── Certificates
│   └── FleetBridge-Exchange-Cert (for Entra app auth)
│
├── Secrets
│   ├── client-acme-corp-a1b2c3d4-database
│   ├── client-acme-corp-a1b2c3d4-username
│   ├── client-acme-corp-a1b2c3d4-password
│   ├── client-widgetsllc-e5f6g7h8-database
│   ├── client-widgetsllc-e5f6g7h8-username
│   └── client-widgetsllc-e5f6g7h8-password
│
└── Access Policies
    └── fleetbridge-mygeotab (Managed Identity)
        - Certificate: Get
        - Secret: Get, List
```

---

## Function App Configuration

### App Settings (Environment Variables)

| Setting | Value | Purpose |
|---------|-------|---------|
| `KEY_VAULT_URL` | `https://fleetbridge-vault.vault.azure.net/` | Key Vault endpoint |
| `USE_KEY_VAULT` | `true` | Enable multi-tenant mode |
| `ENTRA_TENANT_ID` | `87654321-4321-...` | Microsoft 365 tenant |
| `ENTRA_CLIENT_ID` | `12345678-1234-...` | Entra app registration ID |
| `ENTRA_CERT_NAME` | `FleetBridge-Exchange-Cert` | Certificate name in Key Vault |
| `EQUIPMENT_DOMAIN` | `equipment.contoso.com` | Email domain for mailboxes |
| `DEFAULT_TIMEZONE` | `AUS Eastern Standard Time` | Fallback timezone |

### Managed Identity Permissions

- **Key Vault**: Get certificates, Get/List secrets
- **No additional Azure permissions needed** (Graph auth via Entra app)

---

## Entra App Permissions

### Microsoft Graph (Application Permissions)

| Permission | Purpose | Requires Admin Consent |
|------------|---------|------------------------|
| `Calendars.ReadWrite` | Update calendar settings, working hours, permissions | ✅ |
| `MailboxSettings.ReadWrite` | Configure timezone, language, regional settings | ✅ |
| `User.ReadWrite.All` | Update user properties (state/province, custom attributes) | ✅ |

### Exchange Online (Application Permissions)

| Permission | Purpose | Requires Admin Consent |
|------------|---------|------------------------|
| `Exchange.ManageAsApp` | Full Exchange management (create/update mailboxes) | ✅ |

### Azure AD Role Assignment

- **Exchange Administrator** role assigned to the Entra app service principal

---

## Deployment Process

### Initial Setup (One-Time)

```bash
# 1. Configure equipment domain
# Edit deploy-full-setup.sh:
EQUIPMENT_DOMAIN="equipment.yourcompany.com"

# 2. Run deployment
cd azure-function
./deploy-full-setup.sh

# This creates:
# - Resource Group
# - Storage Account
# - Key Vault
# - Function App (with managed identity)
# - Entra App Registration (with certificate)
# - Uploads certificate to Key Vault
# - Configures app settings
# - Deploys function code
```

### Manual Steps (Part of deploy-full-setup.sh prompts)

1. **Grant Admin Consent** for API permissions (portal link provided)
2. **Add Exchange.ManageAsApp** permission via portal (can't automate via CLI)
3. **Assign Exchange Administrator role** to app via portal

### Client Onboarding (Per Client)

```bash
./onboard-client.sh "Client Name" "mygeotab_db" "username" "password"
# Returns API key → Give to client
```

### Add-In Configuration (Per Client)

1. Client installs Add-In from GitHub Pages: `https://autotrace-au.github.io/FleetBridge-MyGeotab-AddIn/`
2. Client navigates to "Sync to Exchange" tab
3. Client enters:
   - **Function URL**: `https://fleetbridge-mygeotab.azurewebsites.net/api/update-device-properties`
   - **Function Key**: `<default-function-key>` (from deployment output)
   - **Client API Key**: `<their-unique-api-key>` (from onboarding)
4. Client clicks "Save Configuration" → Stored in browser localStorage
5. Client can now use "Manage Assets" and "Sync to Exchange" tabs

---

## Data Flow Examples

### Example 1: Enable Booking for a Vehicle

```
1. User Action:
   - Opens "Manage Assets" tab
   - Selects device "Truck 01" (serial: GT8912345)
   - Sets "Enable Equipment Booking" = ON
   - Sets "Booking Approvers" = "supervisor@acme.com"
   - Clicks "Save Changes"

2. Add-In JavaScript:
   - Builds request:
     {
       "apiKey": "acme-corp-a1b2c3d4",
       "deviceId": "b123",
       "properties": {
         "bookable": true,
         "approvers": "supervisor@acme.com"
       }
     }
   - POSTs to: /api/update-device-properties?code=<function-key>

3. Azure Function:
   - Validates function key
   - Looks up Key Vault: client-acme-corp-a1b2c3d4-*
   - Gets: database="acme_db", username="user@acme.com", password="***"
   - Connects to MyGeotab
   - Fetches device b123
   - Fetches property catalog
   - Finds "Enable Equipment Booking" property ID
   - Updates device.customProperties:
     [
       {
         "property": { "id": "prop_abc123" },
         "value": true
       },
       {
         "property": { "id": "prop_xyz789" },
         "value": "supervisor@acme.com"
       }
     ]
   - Calls api.set('Device', device)
   - Returns: { success: true, message: "Updated Truck 01" }

4. User sees: ✅ "Device updated successfully"
```

### Example 2: Sync to Exchange

```
1. User Action:
   - Clicks "Trigger Sync Now" in "Sync to Exchange" tab

2. Add-In JavaScript:
   - POSTs to: /api/sync-to-exchange?code=<function-key>
   - Body: { "apiKey": "acme-corp-a1b2c3d4" }

3. Azure Function:
   - Validates function key
   - Retrieves MyGeotab credentials from Key Vault
   - Connects to MyGeotab → Gets all devices
   - Normalizes custom properties:
     Device: Truck 01
       - Name: "Truck 01"
       - SerialNumber: "GT8912345"
       - Bookable: true
       - Approvers: ["supervisor@acme.com"]
       - BookingWindowInDays: 90
       - TimeZone: "Australia/Sydney"
   
   - Retrieves certificate from Key Vault
   - Authenticates to Microsoft Graph using cert
   
   - For each device:
     a. Find mailbox: gt8912345@equipment.contoso.com
     b. If found:
        - Update display name to "Truck 01"
        - Set timezone to "AUS Eastern Standard Time"
        - Set language to "en-AU"
        - Update state/province (if provided)
        - (Booking rules via Graph API are limited - this is a known gap)
     c. If not found: Log "Mailbox not found, skipping"
   
   - Returns: {
       success: true,
       processed: 15,
       successful: 12,
       failed: 3,
       results: [
         { device: "Truck 01", success: true, email: "gt8912345@..." },
         { device: "Trailer 05", success: false, reason: "mailbox_not_found" },
         ...
       ]
     }

4. User sees summary:
   ✅ Processed 15 devices
   ✅ 12 successful
   ❌ 3 failed
   [Expandable list showing each result]
```

---

## Known Limitations & Workarounds

### Limitation 1: Graph API Can't Set All Exchange Properties

**Problem**: Microsoft Graph API doesn't expose:
- `CalendarProcessing` settings (AllowConflicts, BookingWindowInDays, etc.)
- Resource delegates (approvers)
- Default calendar permissions (MyOrganization visibility)

**Workaround Options**:
1. **Use Exchange Online PowerShell** (current PowerShell script approach)
   - Requires EXO PowerShell module in Python (difficult)
   - Can use `subprocess` to call PowerShell from Python (hacky)
   
2. **Use Exchange Web Services (EWS) REST API** (better)
   - Direct HTTP calls to `https://outlook.office365.com/EWS/Exchange.asmx`
   - Requires app-only auth (same certificate)
   - More complex but avoids PowerShell dependency
   
3. **Hybrid Approach** (recommended for now)
   - Use Graph API for what it can do (name, timezone, regional settings)
   - Mark devices as "needs full sync" in custom properties
   - Admin runs PowerShell script manually/scheduled for full calendar config

### Limitation 2: No Auto-Creation of Mailboxes

**Problem**: Exchange Online requires `New-Mailbox` cmdlet which isn't available via Graph API.

**Solution**: 
- Mailboxes must be pre-created (manually or via PowerShell script)
- Function only updates existing mailboxes (update-only mode)
- Document mailbox creation process for admins

### Limitation 3: Certificate Expiry

**Problem**: Certificates expire after 2 years (730 days).

**Solution**:
- Set calendar reminder 1 month before expiry
- Generate new certificate and upload to app + Key Vault
- No downtime if done before expiry

---

## Security Considerations

### 1. Credential Storage

✅ **Good**: MyGeotab credentials in Azure Key Vault (encrypted at rest)  
✅ **Good**: Function Key required for API calls (prevents anonymous access)  
✅ **Good**: Certificate-based auth for Exchange (no passwords stored)  
⚠️ **Caution**: Client API keys in browser localStorage (XSS risk)  
   - Mitigation: MyGeotab already requires user auth to access Add-In  
   - localStorage is isolated per domain (*.geotab.com)

### 2. Network Security

✅ **Good**: HTTPS enforced on all endpoints  
✅ **Good**: CORS restricted to `*.geotab.com`  
✅ **Good**: Azure Function built-in DDoS protection  
✅ **Good**: Key Vault firewall (can restrict to Azure services only)

### 3. Least Privilege

✅ **Good**: Entra app has only required Graph permissions  
✅ **Good**: Function Managed Identity has only Key Vault Get access  
✅ **Good**: Each client's credentials are isolated in Key Vault  
⚠️ **Risk**: Exchange Administrator role is powerful  
   - Mitigation: App is service principal (can't sign in to portal)  
   - Audit logs track all actions

---

## Scaling & Performance

### Function App Consumption Plan

- **Concurrent Executions**: Up to 200 instances
- **Timeout**: 5 minutes (configurable to 10 min on Premium plan)
- **Cold Start**: ~2-3 seconds (Python runtime)
- **Typical Sync Time**: 
  - 100 devices = ~30-60 seconds
  - 1000 devices = ~5-8 minutes (consider batching)

### Cost Estimation (100 clients, 1000 devices each)

| Resource | Monthly Cost (AUD) |
|----------|---------------------|
| Function App (Consumption) | $3-10 (depends on executions) |
| Key Vault | $0.10 (certificate storage) |
| Storage Account | $0.50 (function logs) |
| Application Insights | $0-5 (basic telemetry) |
| **Total** | **$4-16/month** |

**Revenue Model**:
- Charge $50-100/client/month
- 100 clients × $50 = $5,000/month revenue
- Infrastructure cost: $16/month
- **Gross margin: ~99.7%** 🚀

---

## Monitoring & Troubleshooting

### Health Checks

```bash
# Test function health
curl https://fleetbridge-mygeotab.azurewebsites.net/api/health

# Expected response:
{
  "status": "healthy",
  "timestamp": "2025-11-03T12:34:56Z",
  "keyVaultEnabled": true
}
```

### View Logs

```bash
# Stream live logs
az functionapp log tail --resource-group FleetBridgeRG --name fleetbridge-mygeotab

# View in Application Insights
# Azure Portal → Application Insights → Logs
# Query: traces | where message contains "sync-to-exchange"
```

### Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| "Invalid credentials or API key" | Wrong/missing client API key | Check onboarding, verify Key Vault secrets |
| "Mailbox not found" | Serial number doesn't match existing mailbox | Pre-create mailbox as `serial@equipment.domain` |
| "Failed to get Graph credential" | Certificate missing or expired | Re-upload certificate to Key Vault |
| "Insufficient privileges" | Missing Graph permissions or role | Grant admin consent, assign Exchange Admin role |

---

## Future Enhancements

### Phase 1: Current State ✅
- [x] MyGeotab property updates via Azure Function
- [x] Basic Exchange sync (display name, timezone)
- [x] Multi-tenant support with Key Vault
- [x] Certificate-based authentication

### Phase 2: Full Exchange Integration 🔄
- [ ] EWS REST API integration for full calendar processing
- [ ] Auto-create mailboxes via EWS (no PowerShell needed)
- [ ] Set booking policies, delegates, permissions via EWS
- [ ] Scheduled sync (Azure Function timer trigger)

### Phase 3: Advanced Features 🚀
- [ ] Client portal (manage API keys, view usage)
- [ ] Billing integration (Stripe/usage-based)
- [ ] Webhook from MyGeotab (real-time sync on device changes)
- [ ] Teams integration (approve bookings via Teams)
- [ ] Analytics dashboard (booking utilization, popular assets)

---

## Summary

FleetBridge is now a clean **2-component architecture**:

1. **MyGeotab Add-In** (Frontend)
   - Runs in user's browser
   - No servers to maintain
   - Deployed via GitHub Pages (free)

2. **Azure Function App** (Backend)
   - Serverless Python
   - Handles all MyGeotab and Exchange operations
   - Fully automated deployment
   - Multi-tenant ready
   - ~$5-15/month for 100+ clients

**Key Benefits**:
- ✅ No PowerShell runbooks to maintain
- ✅ No Azure Automation (simplified billing)
- ✅ Single codebase for all processing
- ✅ Certificate-based security (no passwords)
- ✅ Infinite scaling potential
- ✅ 99.7% gross margins

**Next Steps**:
1. Deploy with `./deploy-full-setup.sh`
2. Complete manual Entra app setup (admin consent, role assignment)
3. Onboard first client with `./onboard-client.sh`
4. Test end-to-end workflow
5. Consider EWS integration for full Exchange feature parity
