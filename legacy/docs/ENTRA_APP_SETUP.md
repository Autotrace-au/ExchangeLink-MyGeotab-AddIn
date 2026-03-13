# Entra App Registration Setup for FleetBridge

## Overview

FleetBridge requires an **Entra ID App Registration** with **certificate-based authentication** to access Exchange Online and Microsoft Graph APIs. This enables the Azure Function to create/update equipment mailboxes without requiring user credentials.

## Architecture

```
Azure Function (Python)
    ↓ [Certificate Auth]
Entra App Registration
    ↓ [API Permissions]
Microsoft Graph API + Exchange Online
    ↓
Equipment Mailboxes
```

## Prerequisites

- Azure subscription with **Global Administrator** or **Application Administrator** role
- Permission to grant admin consent for API permissions
- OpenSSL (pre-installed on macOS/Linux)

---

## Step 1: Create Self-Signed Certificate

The app uses certificate-based authentication (more secure than client secrets for server-to-server scenarios).

```bash
# Generate private key and certificate (valid for 2 years)
openssl req -x509 -newkey rsa:4096 -keyout fleetbridge-cert.key -out fleetbridge-cert.crt -days 730 -nodes -subj "/CN=FleetBridge Exchange Access"

# Create PFX file (needed for Azure Key Vault)
openssl pkcs12 -export -out fleetbridge-cert.pfx -inkey fleetbridge-cert.key -in fleetbridge-cert.crt -passphrase pass:

# Extract public key for Entra registration
openssl x509 -in fleetbridge-cert.crt -outform DER -out fleetbridge-cert.cer

# Get certificate thumbprint (needed for Azure Function configuration)
openssl x509 -in fleetbridge-cert.crt -noout -fingerprint -sha1 | sed 's/://g' | sed 's/SHA1 Fingerprint=//'
```

**Save these files securely:**
- `fleetbridge-cert.pfx` → Upload to Azure Key Vault
- `fleetbridge-cert.cer` → Upload to Entra app
- Certificate thumbprint → Needed for function configuration

---

## Step 2: Create Entra App Registration

### 2.1 Via Azure Portal (Recommended)

1. Navigate to **Azure Portal** → **Microsoft Entra ID** → **App registrations**
2. Click **New registration**
3. Configure:
   - **Name**: `FleetBridge-Exchange-Access`
   - **Supported account types**: *Accounts in this organizational directory only (Single tenant)*
   - **Redirect URI**: Leave blank (not needed for service principal)
4. Click **Register**
5. **Copy the following values** (needed later):
   - **Application (client) ID**: e.g., `12345678-1234-1234-1234-123456789abc`
   - **Directory (tenant) ID**: e.g., `87654321-4321-4321-4321-cba987654321`

### 2.2 Via Azure CLI (Alternative)

```bash
# Create app registration
az ad app create \
  --display-name "FleetBridge-Exchange-Access" \
  --sign-in-audience AzureADMyOrg

# Get the Application ID
APP_ID=$(az ad app list --display-name "FleetBridge-Exchange-Access" --query "[0].appId" -o tsv)
echo "Application ID: $APP_ID"

# Get Tenant ID
TENANT_ID=$(az account show --query tenantId -o tsv)
echo "Tenant ID: $TENANT_ID"
```

---

## Step 3: Upload Certificate to App Registration

### 3.1 Via Azure Portal

1. Go to your app → **Certificates & secrets**
2. Click **Certificates** tab → **Upload certificate**
3. Upload `fleetbridge-cert.cer`
4. Click **Add**

### 3.2 Via Azure CLI

```bash
az ad app credential reset \
  --id $APP_ID \
  --cert @fleetbridge-cert.cer \
  --append
```

---

## Step 4: Grant API Permissions

The app needs specific permissions to manage Exchange mailboxes and calendars.

### Required Microsoft Graph Permissions (Application-level)

| Permission | Purpose | Admin Consent Required |
|------------|---------|------------------------|
| **Calendars.ReadWrite** | Update calendar settings, working hours, permissions | ✅ Yes |
| **MailboxSettings.ReadWrite** | Configure time zones, regional settings | ✅ Yes |
| **User.ReadWrite.All** | Update user properties (State/Province on mailboxes) | ✅ Yes |

### Required Exchange Permissions (Application-level)

| Permission | Purpose | Admin Consent Required |
|------------|---------|------------------------|
| **Exchange.ManageAsApp** | Full Exchange Online management access | ✅ Yes |

### 4.1 Grant via Azure Portal

1. Go to your app → **API permissions**
2. Click **Add a permission**

**For Microsoft Graph:**
3. Select **Microsoft Graph** → **Application permissions**
4. Search and add:
   - `Calendars.ReadWrite`
   - `MailboxSettings.ReadWrite`
   - `User.ReadWrite.All`

**For Exchange:**
5. Click **Add a permission** again
6. Select **APIs my organization uses** → Search for **Office 365 Exchange Online**
7. Select **Application permissions** → Add `Exchange.ManageAsApp`

**Grant Admin Consent:**
8. Click **Grant admin consent for [Your Organization]**
9. Confirm the consent

### 4.2 Grant via Azure CLI

```bash
# Microsoft Graph permissions
az ad app permission add \
  --id $APP_ID \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions \
    ef54d2bf-783f-4e0f-bca1-3210c0444d99=Role \
    6931bccd-447a-43d1-b442-00a195474933=Role \
    741f803b-c850-494e-b5df-cde7c675a1ca=Role

# Note: Exchange.ManageAsApp must be added via portal or using specific API ID
# Find it with: az ad sp list --display-name "Office 365 Exchange Online"

# Grant admin consent (requires Global Admin)
az ad app permission admin-consent --id $APP_ID
```

---

## Step 5: Assign Exchange Administrator Role

The app needs **Exchange Administrator** role to manage mailboxes.

### Via Azure Portal

1. **Azure Portal** → **Microsoft Entra ID** → **Roles and administrators**
2. Search for **Exchange Administrator**
3. Click **Add assignments**
4. Search for `FleetBridge-Exchange-Access`
5. Select and click **Add**

### Via PowerShell

```powershell
# Connect to Microsoft Graph
Connect-MgGraph -Scopes "RoleManagement.ReadWrite.Directory"

# Get the app's service principal
$sp = Get-MgServicePrincipal -Filter "displayName eq 'FleetBridge-Exchange-Access'"

# Get Exchange Administrator role
$role = Get-MgDirectoryRole -Filter "displayName eq 'Exchange Administrator'"

# If role not activated, activate it first
if (-not $role) {
    $roleTemplate = Get-MgDirectoryRoleTemplate -Filter "displayName eq 'Exchange Administrator'"
    $role = New-MgDirectoryRole -RoleTemplateId $roleTemplate.Id
}

# Assign role to service principal
New-MgDirectoryRoleMemberByRef -DirectoryRoleId $role.Id -BodyParameter @{
    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($sp.Id)"
}
```

---

## Step 6: Upload Certificate to Azure Key Vault

The Azure Function retrieves the certificate from Key Vault at runtime.

```bash
# Variables (replace with your values)
VAULT_NAME="fleetbridge-vault"
CERT_NAME="FleetBridge-Exchange-Cert"

# Upload PFX to Key Vault (empty password)
az keyvault certificate import \
  --vault-name $VAULT_NAME \
  --name $CERT_NAME \
  --file fleetbridge-cert.pfx

# Verify upload
az keyvault certificate show \
  --vault-name $VAULT_NAME \
  --name $CERT_NAME \
  --query "id"
```

---

## Step 7: Configure Azure Function Settings

Add these application settings to your Function App:

```bash
FUNCTION_APP="fleetbridge-mygeotab"
RESOURCE_GROUP="FleetBridgeRG"

# Set app settings
az functionapp config appsettings set \
  --name $FUNCTION_APP \
  --resource-group $RESOURCE_GROUP \
  --settings \
    "ENTRA_TENANT_ID=$TENANT_ID" \
    "ENTRA_CLIENT_ID=$APP_ID" \
    "ENTRA_CERT_NAME=$CERT_NAME" \
    "EQUIPMENT_DOMAIN=equipment.yourdomain.com"
```

**Settings Explained:**
- `ENTRA_TENANT_ID`: Your Microsoft 365 tenant ID
- `ENTRA_CLIENT_ID`: Application (client) ID from app registration
- `ENTRA_CERT_NAME`: Name of certificate in Key Vault
- `EQUIPMENT_DOMAIN`: Email domain for equipment mailboxes (e.g., `equipment.contoso.com`)

---

## Step 8: Grant Function App Access to Key Vault

The Function App's **Managed Identity** needs permission to read certificates from Key Vault.

```bash
# Enable system-assigned managed identity
az functionapp identity assign \
  --name $FUNCTION_APP \
  --resource-group $RESOURCE_GROUP

# Get the managed identity's principal ID
PRINCIPAL_ID=$(az functionapp identity show \
  --name $FUNCTION_APP \
  --resource-group $RESOURCE_GROUP \
  --query principalId -o tsv)

# Grant "Key Vault Secrets User" role (read certificates)
az keyvault set-policy \
  --name $VAULT_NAME \
  --object-id $PRINCIPAL_ID \
  --certificate-permissions get \
  --secret-permissions get
```

---

## Verification & Testing

### Test Certificate Authentication

```python
# test_entra_auth.py
from azure.identity import CertificateCredential
from azure.keyvault.secrets import SecretClient
import os

tenant_id = os.environ['ENTRA_TENANT_ID']
client_id = os.environ['ENTRA_CLIENT_ID']
cert_path = 'fleetbridge-cert.pem'  # Local test only

# Test authentication
credential = CertificateCredential(
    tenant_id=tenant_id,
    client_id=client_id,
    certificate_path=cert_path
)

# Try to get a token
token = credential.get_token("https://graph.microsoft.com/.default")
print(f"✅ Authentication successful! Token expires: {token.expires_on}")
```

### Test Exchange Access

```python
# test_exchange_access.py
from msgraph import GraphServiceClient
from azure.identity import CertificateCredential

credential = CertificateCredential(
    tenant_id=os.environ['ENTRA_TENANT_ID'],
    client_id=os.environ['ENTRA_CLIENT_ID'],
    certificate_path='fleetbridge-cert.pem'
)

client = GraphServiceClient(credentials=credential)

# Test: List first mailbox
mailboxes = await client.users.get(top=1)
if mailboxes and mailboxes.value:
    print(f"✅ Exchange access working! Found mailbox: {mailboxes.value[0].user_principal_name}")
```

---

## Security Best Practices

### Certificate Management

1. **Rotation**: Certificates expire after 2 years. Set calendar reminder 1 month before expiry
2. **Storage**: Never commit `.key` or `.pfx` files to git. Store in password manager
3. **Backup**: Keep encrypted backup of certificate files in secure location

### Access Control

1. **Least Privilege**: App has only permissions needed for mailbox management
2. **Monitoring**: Enable Application Insights to track API calls
3. **Conditional Access**: Consider restricting app to specific IP ranges

### Audit Logging

```bash
# Enable diagnostic logging for the app registration
az monitor diagnostic-settings create \
  --resource $APP_ID \
  --name "FleetBridge-Audit-Logs" \
  --logs '[{"category": "AuditLogs", "enabled": true}]' \
  --workspace <log-analytics-workspace-id>
```

---

## Troubleshooting

### "Insufficient privileges to complete the operation"

**Cause**: Missing API permissions or admin consent not granted

**Solution**:
1. Verify all permissions in Step 4 are added
2. Ensure "Grant admin consent" was clicked
3. Wait 5-10 minutes for permissions to propagate

### "Certificate not found in Key Vault"

**Cause**: Managed Identity lacks Key Vault access

**Solution**:
1. Verify Step 8 was completed
2. Check access policy: `az keyvault show --name $VAULT_NAME --query properties.accessPolicies`
3. Ensure Function App's managed identity is listed

### "AADSTS700016: Application not found in the directory"

**Cause**: Wrong tenant ID or app not created in correct tenant

**Solution**:
1. Verify `ENTRA_TENANT_ID` matches your M365 tenant
2. Check app exists: `az ad app show --id $APP_ID`

---

## Cost Estimation

| Resource | Monthly Cost (AU) |
|----------|-------------------|
| Entra App Registration | Free |
| Certificate in Key Vault | ~$0.10 |
| API Calls (Graph/Exchange) | Free (within limits) |
| **Total** | **~$0.10/month** |

---

## Next Steps

Once Entra app is configured:

1. ✅ Test authentication with test scripts above
2. ✅ Deploy updated Azure Function with Exchange sync endpoint
3. ✅ Update Add-In UI to call new `/api/sync-to-exchange` endpoint
4. ✅ Test end-to-end: MyGeotab → Azure Function → Exchange mailbox creation

---

## References

- [Microsoft Graph Permissions Reference](https://learn.microsoft.com/en-us/graph/permissions-reference)
- [Exchange Online App-only Authentication](https://learn.microsoft.com/en-us/powershell/exchange/app-only-auth-powershell-v2)
- [Azure Key Vault Certificate Management](https://learn.microsoft.com/en-us/azure/key-vault/certificates/about-certificates)
