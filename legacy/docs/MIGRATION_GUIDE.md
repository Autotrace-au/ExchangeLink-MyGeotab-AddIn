# FleetBridge 2.0 - Migration Guide

## Overview

FleetBridge has been simplified from a **3-component architecture** (Add-In + Azure Function + PowerShell) to a clean **2-component architecture** (Add-In + Azure Function).

### What Changed?

**Before (v1.x):**
```
MyGeotab Add-In 
    ↓
Azure Function (property updates only)
    ↓
MyGeotab API

MyGeotab Add-In
    ↓
Azure Automation + PowerShell Script (Exchange sync)
    ↓
Exchange Online
```

**After (v2.0):**
```
MyGeotab Add-In
    ↓
Azure Function (property updates + Exchange sync)
    ↓
MyGeotab API + Microsoft Graph API
    ↓
Exchange Online
```

### Benefits of v2.0

✅ **Simplified Architecture**: Only 2 components instead of 3  
✅ **Lower Costs**: No Azure Automation account needed (~$10-20/month savings)  
✅ **Better UX**: Direct API responses (no more "CORS limitation" warnings)  
✅ **Unified Authentication**: Single function app for all operations  
✅ **Easier Deployment**: One deployment script does everything  
✅ **Better Monitoring**: All logs in one place (Application Insights)  

---

## Migration Path

### Option 1: Fresh Deployment (Recommended)

If you're starting from scratch or can rebuild:

1. **Delete old resources** (optional - save costs):
   ```bash
   # Delete Azure Automation account
   az automation account delete --name <automation-account-name> --resource-group <rg-name>
   ```

2. **Deploy new architecture**:
   ```bash
   cd azure-function
   
   # Edit EQUIPMENT_DOMAIN in deploy-full-setup.sh first!
   nano deploy-full-setup.sh  # Set EQUIPMENT_DOMAIN="equipment.yourcompany.com"
   
   # Run deployment
   ./deploy-full-setup.sh
   ```

3. **Complete manual Entra app setup** (prompted during deployment):
   - Grant admin consent for API permissions
   - Add `Exchange.ManageAsApp` permission via portal
   - Assign Exchange Administrator role to app

4. **Onboard clients**:
   ```bash
   ./onboard-client.sh "Client Name" "database" "username" "password"
   ```

5. **Update Add-In configuration** (users do this):
   - Open MyGeotab → Add-Ins → FleetBridge
   - Go to "Sync to Exchange" tab
   - Enter:
     - **Function URL**: `https://fleetbridge-mygeotab.azurewebsites.net`
     - **Function Key**: (from deployment output)
     - **Client API Key**: (from onboarding output)
   - Click "Save Configuration"

### Option 2: In-Place Upgrade

If you have existing Azure Function + Automation:

1. **Update Azure Function code**:
   ```bash
   cd azure-function
   
   # Update requirements.txt and function code
   git pull origin main  # Or download latest release
   
   # Deploy updated function
   func azure functionapp publish fleetbridge-mygeotab
   ```

2. **Create Entra App Registration** (follow ENTRA_APP_SETUP.md):
   ```bash
   # Generate certificate
   mkdir -p certs
   openssl req -x509 -newkey rsa:4096 \
     -keyout certs/fleetbridge-cert.key \
     -out certs/fleetbridge-cert.crt \
     -days 730 -nodes \
     -subj "/CN=FleetBridge Exchange Access"
   
   # Create PFX
   openssl pkcs12 -export \
     -out certs/fleetbridge-cert.pfx \
     -inkey certs/fleetbridge-cert.key \
     -in certs/fleetbridge-cert.crt \
     -passphrase pass:
   
   # Upload to Key Vault
   az keyvault certificate import \
     --vault-name fleetbridge-vault \
     --name "FleetBridge-Exchange-Cert" \
     --file certs/fleetbridge-cert.pfx
   ```

3. **Create Entra App** via Azure Portal:
   - Microsoft Entra ID → App registrations → New registration
   - Name: `FleetBridge-Exchange-Access`
   - Upload certificate (certs/fleetbridge-cert.cer)
   - Add API permissions (see ENTRA_APP_SETUP.md)
   - Grant admin consent
   - Assign Exchange Administrator role

4. **Update Function App Settings**:
   ```bash
   TENANT_ID=$(az account show --query tenantId -o tsv)
   APP_ID="<your-app-id-from-portal>"
   
   az functionapp config appsettings set \
     --resource-group FleetBridgeRG \
     --name fleetbridge-mygeotab \
     --settings \
       "ENTRA_TENANT_ID=$TENANT_ID" \
       "ENTRA_CLIENT_ID=$APP_ID" \
       "ENTRA_CERT_NAME=FleetBridge-Exchange-Cert" \
       "EQUIPMENT_DOMAIN=equipment.yourcompany.com" \
       "DEFAULT_TIMEZONE=AUS Eastern Standard Time"
   ```

5. **Test new sync endpoint**:
   ```bash
   FUNCTION_KEY=$(az functionapp keys list \
     --resource-group FleetBridgeRG \
     --name fleetbridge-mygeotab \
     --query "functionKeys.default" -o tsv)
   
   curl -X POST "https://fleetbridge-mygeotab.azurewebsites.net/api/sync-to-exchange?code=$FUNCTION_KEY" \
     -H "Content-Type: application/json" \
     -d '{"apiKey":"<client-api-key>","maxDevices":5}'
   ```

6. **Update users' Add-In configuration** (each user):
   - Remove old webhook URL (no longer needed)
   - Update Function URL if changed
   - Test "Trigger Sync Now" button

7. **Decommission Azure Automation** (after confirming new sync works):
   ```bash
   # Optional: Export runbook for backup
   az automation runbook show \
     --resource-group <rg> \
     --automation-account-name <account> \
     --name FleetSync-Orchestrator > backup-orchestrator.ps1
   
   # Delete Automation account
   az automation account delete \
     --name <automation-account> \
     --resource-group <rg>
   ```

---

## Breaking Changes

### 1. Webhook URL No Longer Used

**Old behavior**: Users configured Azure Automation webhook URL  
**New behavior**: Webhook configuration section removed from Add-In

**Migration**: Users just need to save Azure Function config (no webhook needed)

### 2. Function URL Format Changed

**Old format**: `https://fleetbridge-mygeotab.azurewebsites.net/api/update-device-properties`  
**New format**: `https://fleetbridge-mygeotab.azurewebsites.net` (base URL only)

**Migration**: Add-In automatically handles both formats, but recommend updating to base URL

### 3. LocalStorage Keys Renamed

**Old keys**:
- `fleetBridgeAzureFunctionUrl`
- `fleetBridgeAzureFunctionKey`
- `fleetBridgeClientApiKey`

**New keys**:
- `fleetSyncFunctionUrl`
- `fleetSyncFunctionKey`
- `fleetSyncClientApiKey`

**Migration**: Automatic - users just need to re-save configuration once

### 4. Exchange Sync Method Changed

**Old method**: HTTP POST to Azure Automation webhook (no-cors, no response)  
**New method**: HTTP POST to Azure Function `/api/sync-to-exchange` (full response)

**Migration**: Automatic - users get full sync results with device-by-device status

---

## Testing Checklist

After migration, test these scenarios:

### 1. Azure Function Health

```bash
curl https://fleetbridge-mygeotab.azurewebsites.net/api/health
# Expected: {"status":"healthy","timestamp":"...","keyVaultEnabled":true}
```

### 2. Property Update

- [ ] Open MyGeotab Add-In
- [ ] Go to "Manage Assets" tab
- [ ] Load devices
- [ ] Change a property (e.g., "Enable Equipment Booking")
- [ ] Click "Save Changes"
- [ ] Verify success message
- [ ] Check device in MyGeotab API to confirm update

### 3. Exchange Sync

- [ ] Go to "Sync to Exchange" tab
- [ ] Enter Function URL, Function Key, Client API Key
- [ ] Click "Save Configuration"
- [ ] Click "Test Connection" → Should show "✅ Connection successful"
- [ ] Set "Limit (for testing)" to 5
- [ ] Click "Trigger Sync Now"
- [ ] Verify sync summary shows: Processed, Successful, Failed counts
- [ ] Expand "View detailed results" → Check device-by-device status
- [ ] Verify Exchange mailboxes were updated (check one manually)

### 4. Multi-Tenant Test

```bash
# Onboard second client
./onboard-client.sh "Test Client" "testdb" "testuser" "testpass"
# Returns: API key

# Test with second client's API key
curl -X POST "https://fleetbridge-mygeotab.azurewebsites.net/api/sync-to-exchange?code=<function-key>" \
  -H "Content-Type: application/json" \
  -d '{"apiKey":"<second-client-api-key>","maxDevices":3}'
```

---

## Rollback Plan

If migration fails, you can roll back:

1. **Keep old Azure Automation** (don't delete until confident)
2. **Revert Add-In**: Use previous version from Git
   ```bash
   git checkout v1.x
   ```
3. **Users re-configure**: Enter webhook URL again
4. **Delete new Entra app** (optional):
   ```bash
   az ad app delete --id <app-id>
   ```

---

## FAQ

### Q: Do I need to re-create equipment mailboxes?

**A:** No. Existing mailboxes are preserved. The new sync function updates them in place.

### Q: Will this affect my current bookings in Exchange?

**A:** No. The sync only updates mailbox settings (display name, timezone, booking rules). Existing calendar events are untouched.

### Q: Can I run old and new architectures side-by-side?

**A:** Yes, during migration. But disable the Azure Automation schedule to avoid conflicts. Run manual tests only.

### Q: What if I don't want to use Exchange sync?

**A:** You can still use just the property update functionality. Simply don't configure Entra app or click "Trigger Sync Now".

### Q: How do I know if Exchange sync worked?

**A:** The Add-In now shows detailed results:
- Summary: Processed, Successful, Failed counts
- Detailed results: Each device's status
- Errors: Specific reason for failures (e.g., "mailbox_not_found")

### Q: What are the new Azure costs?

**Before:**
- Azure Function: $3-10/month
- Azure Automation: $10-20/month
- Key Vault: $0.10/month
- **Total: $13-30/month**

**After:**
- Azure Function: $3-10/month (includes Exchange sync)
- Key Vault: $0.10/month
- **Total: $3-10/month** 💰 **~60-75% savings!**

---

## Support

If you encounter issues during migration:

1. **Check deployment logs**:
   ```bash
   az functionapp log tail --resource-group FleetBridgeRG --name fleetbridge-mygeotab
   ```

2. **View Application Insights**:
   - Azure Portal → Application Insights → Logs
   - Query: `traces | where message contains "sync-to-exchange"`

3. **Common errors**:
   - "Certificate not found" → Re-upload to Key Vault
   - "Insufficient privileges" → Grant admin consent for Graph permissions
   - "Mailbox not found" → Pre-create mailbox as `serial@equipment.domain`

4. **Get help**:
   - GitHub Issues: [FleetBridge Issues](https://github.com/Autotrace-au/FleetBridge-MyGeotab-AddIn/issues)
   - Email: support@autotrace.com.au

---

## Timeline Recommendation

For production deployments:

**Week 1: Preparation**
- Deploy new architecture to separate resource group (test)
- Create Entra app registration
- Test with 1-2 devices

**Week 2: Pilot**
- Onboard 1 pilot client
- Run parallel (old webhook + new function)
- Monitor for issues

**Week 3: Rollout**
- Onboard remaining clients
- Update all users' Add-In config
- Verify Exchange sync results

**Week 4: Cleanup**
- Disable Azure Automation schedule
- Monitor for 1 week
- Delete Azure Automation resources (save ~$15/month)

---

## Next Steps

After successful migration:

1. ✅ Update documentation links to point to new endpoints
2. ✅ Train users on new sync UI (shows detailed results)
3. ✅ Set up monitoring alerts (Application Insights)
4. ✅ Schedule certificate renewal reminder (2 years from now)
5. ✅ Consider Phase 2 enhancements:
   - EWS REST API for full calendar processing
   - Scheduled sync (timer trigger)
   - Client self-service portal

---

## Conclusion

The v2.0 architecture is simpler, cheaper, and more reliable. The migration is straightforward and can be done with minimal downtime. Most of the work is automated by the deployment script.

**Estimated migration time**: 1-2 hours for initial deployment + testing

Good luck with your migration! 🚀
