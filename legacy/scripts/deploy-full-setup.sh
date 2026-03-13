#!/bin/bash

# FleetBridge Azure Function - Full Multi-Tenant SaaS Deployment Script
# This script deploys the complete multi-tenant architecture with OAuth delegated access

set -e  # Exit on error

# Configuration - UPDATE THESE VALUES
RESOURCE_GROUP="FleetBridgeRG"
LOCATION="australiaeast"
STORAGE_ACCOUNT="fleetbridgestore"
FUNCTION_APP="fleetbridge-mygeotab"
KEY_VAULT="fleetbridge-vault"
ENTRA_APP_NAME="FleetBridge SaaS"
EQUIPMENT_DOMAIN="equipment.yourdomain.com"  # UPDATE THIS!

echo "=========================================="
echo "FleetBridge Multi-Tenant SaaS Deployment"
echo "=========================================="
echo ""
echo "Configuration:"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Location: $LOCATION"
echo "  Storage Account: $STORAGE_ACCOUNT"
echo "  Function App: $FUNCTION_APP"
echo "  Key Vault: $KEY_VAULT"
echo "  Entra App: $ENTRA_APP_NAME (Multi-Tenant)"
echo "  Equipment Domain: $EQUIPMENT_DOMAIN"
echo ""
read -p "Press Enter to continue or Ctrl+C to cancel..."

# Step 1: Login to Azure
echo ""
echo "Step 1: Logging in to Azure..."
az login

# Step 2: Create Resource Group
echo ""
echo "Step 2: Creating resource group..."
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION

# Step 3: Create Storage Account
echo ""
echo "Step 3: Creating storage account..."
az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard_LRS

# Step 4: Create Key Vault
echo ""
echo "Step 4: Creating Key Vault..."
az keyvault create \
  --name $KEY_VAULT \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION

# Step 5: Create Function App
echo ""
echo "Step 5: Creating Function App..."
az functionapp create \
  --resource-group $RESOURCE_GROUP \
  --consumption-plan-location $LOCATION \
  --runtime python \
  --runtime-version 3.11 \
  --functions-version 4 \
  --name $FUNCTION_APP \
  --storage-account $STORAGE_ACCOUNT \
  --os-type Linux

# Step 6: Enable Managed Identity
echo ""
echo "Step 6: Enabling managed identity for Function App..."
az functionapp identity assign \
  --resource-group $RESOURCE_GROUP \
  --name $FUNCTION_APP

# Get the principal ID
PRINCIPAL_ID=$(az functionapp identity show \
  --resource-group $RESOURCE_GROUP \
  --name $FUNCTION_APP \
  --query principalId \
  --output tsv)

echo "  Principal ID: $PRINCIPAL_ID"

# Step 7: Grant Function App access to Key Vault
echo ""
echo "Step 7: Granting Function App access to Key Vault..."
az keyvault set-policy \
  --name $KEY_VAULT \
  --object-id $PRINCIPAL_ID \
  --secret-permissions get list set \
  --certificate-permissions get

# Step 8: Create Multi-Tenant Entra App Registration (OAuth SaaS)
echo ""
echo "Step 8: Creating Multi-Tenant Entra App Registration..."

# Check if app already exists
EXISTING_APP_ID=$(az ad app list --display-name "$ENTRA_APP_NAME" --query "[0].appId" -o tsv)

if [ -z "$EXISTING_APP_ID" ]; then
  # Create new multi-tenant app with web redirect
  FUNCTION_URL="https://${FUNCTION_APP}.azurewebsites.net"
  
  az ad app create \
    --display-name "$ENTRA_APP_NAME" \
    --sign-in-audience AzureADMultipleOrgs \
    --web-redirect-uris "${FUNCTION_URL}/api/auth/callback"
  
  APP_ID=$(az ad app list --display-name "$ENTRA_APP_NAME" --query "[0].appId" -o tsv)
  echo "  ✅ Created new multi-tenant app: $APP_ID"
else
  APP_ID=$EXISTING_APP_ID
  echo "  ℹ️  Using existing app: $APP_ID"
fi

TENANT_ID=$(az account show --query tenantId -o tsv)
echo "  Tenant ID: $TENANT_ID"

# Step 9: Create client secret for OAuth token exchange
echo ""
echo "Step 9: Creating client secret for OAuth..."
CLIENT_SECRET_JSON=$(az ad app credential reset \
  --id $APP_ID \
  --append \
  --display-name "FleetBridge Token Exchange")

CLIENT_SECRET=$(echo $CLIENT_SECRET_JSON | jq -r '.password')
echo "  ✅ Client secret created (will be stored in Key Vault)"

# Store client secret in Key Vault
az keyvault secret set \
  --vault-name $KEY_VAULT \
  --name "EntraAppClientSecret" \
  --value "$CLIENT_SECRET"
echo "  ✅ Client secret stored in Key Vault"

# Step 10: Grant DELEGATED API permissions (user consent - no admin required!)
echo ""
echo "Step 10: Granting delegated API permissions..."
echo "  Adding Microsoft Graph delegated permissions..."

# Microsoft Graph API ID: 00000003-0000-0000-c000-000000000000
# DELEGATED (Scope) permissions:
# Calendars.ReadWrite: 1ec239c2-d7c9-4623-a91a-a9775856bb36
# MailboxSettings.ReadWrite: 6931bccd-447a-43d1-b442-00a195474933
# User.ReadWrite.All: 741f803b-c850-494e-b5df-cde7c675a1ca
# offline_access: 7427e0e9-2fba-42fe-b0c0-848c9e6a8182

az ad app permission add \
  --id $APP_ID \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions \
    1ec239c2-d7c9-4623-a91a-a9775856bb36=Scope \
    6931bccd-447a-43d1-b442-00a195474933=Scope \
    741f803b-c850-494e-b5df-cde7c675a1ca=Scope \
    7427e0e9-2fba-42fe-b0c0-848c9e6a8182=Scope

echo "  ✅ Delegated permissions added"
echo ""
echo "  ℹ️  NOTE: Delegated permissions do NOT require admin consent!"
echo "  Users will consent individually when they click 'Connect to Exchange' in the Add-In."
echo ""

# REMOVED: Steps 8-13 for certificate-based auth (no longer needed for SaaS multi-tenant)
# The SaaS model uses OAuth with delegated permissions instead of application permissions + certificates

# Step 11: Configure Function App settings
echo ""
echo "Step 11: Configuring Function App settings..."
az functionapp config appsettings set \
  --resource-group $RESOURCE_GROUP \
  --name $FUNCTION_APP \
  --settings \
    "KEY_VAULT_URL=https://${KEY_VAULT}.vault.azure.net/" \
    "USE_KEY_VAULT=true" \
    "ENTRA_CLIENT_ID=$APP_ID" \
    "ENTRA_CLIENT_SECRET_NAME=EntraAppClientSecret" \
    "EQUIPMENT_DOMAIN=$EQUIPMENT_DOMAIN" \
    "DEFAULT_TIMEZONE=AUS Eastern Standard Time" \
    "WEBSITE_HOSTNAME=${FUNCTION_APP}.azurewebsites.net"

echo "  ✅ Function app settings configured"

# Step 12: Configure CORS
echo ""
echo "Step 12: Configuring CORS..."
az functionapp cors add \
  --resource-group $RESOURCE_GROUP \
  --name $FUNCTION_APP \
  --allowed-origins "https://*.geotab.com" "https://*.geotab.com.au"

echo "  ✅ CORS configured"

# Step 13: Deploy Function
echo ""
echo "Step 13: Deploying function code..."
func azure functionapp publish $FUNCTION_APP

# Step 14: Get Function Key
echo ""
echo "Step 14: Getting function key..."
FUNCTION_KEY=$(az functionapp keys list \
  --resource-group $RESOURCE_GROUP \
  --name $FUNCTION_APP \
  --query "functionKeys.default" \
  --output tsv)

# Step 18: Display summary
echo ""
echo "=========================================="
echo "Deployment Complete!"
echo "=========================================="
echo ""
echo "Function URLs:"
echo "  Update Properties: https://${FUNCTION_APP}.azurewebsites.net/api/update-device-properties"
echo "  Sync to Exchange:  https://${FUNCTION_APP}.azurewebsites.net/api/sync-to-exchange"
echo "  Health Check:      https://${FUNCTION_APP}.azurewebsites.net/api/health"
echo ""
echo "Function Key:"
echo "  $FUNCTION_KEY"
echo ""
echo "Key Vault:"
echo "  URL: https://${KEY_VAULT}.vault.azure.net/"
echo ""
echo "Entra App:"
echo "  App ID: $APP_ID"
echo "  Tenant ID: $TENANT_ID"
echo "  Certificate Thumbprint: $CERT_THUMBPRINT"
echo ""
echo "Equipment Domain:"
echo "  $EQUIPMENT_DOMAIN"
echo ""
echo "Certificates stored in:"
echo "  $CERT_DIR/"
echo ""
echo "=========================================="
echo "Next Steps:"
echo "=========================================="
echo ""
echo "1. Test the health endpoint:"
echo "   curl https://${FUNCTION_APP}.azurewebsites.net/api/health"
echo ""
echo "2. Update index.html with these values:"
echo "   AZURE_FUNCTION_URL = 'https://${FUNCTION_APP}.azurewebsites.net/api/update-device-properties'"
echo "   AZURE_FUNCTION_KEY = '$FUNCTION_KEY'"
echo ""
echo "3. To onboard a new client, run:"
echo "   ./onboard-client.sh <client-name> <database> <username> <password>"
echo ""
echo "4. Test Exchange sync (after onboarding a client):"
echo "   curl -X POST https://${FUNCTION_APP}.azurewebsites.net/api/sync-to-exchange?code=$FUNCTION_KEY \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"apiKey\":\"<client-api-key>\",\"maxDevices\":5}'"
echo ""
echo "5. View logs:"
echo "   az functionapp log tail --resource-group $RESOURCE_GROUP --name $FUNCTION_APP"
echo ""
echo "6. IMPORTANT - Secure your certificates:"
echo "   Store $CERT_DIR/fleetbridge-cert.pfx in a secure password manager"
echo "   Certificate expires: $(date -v+730d +'%Y-%m-%d')"
echo ""
echo "=========================================="
echo "Manual Steps Required (if not completed):"
echo "=========================================="
echo ""
echo "1. Grant Admin Consent for API Permissions:"
echo "   https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$APP_ID"
echo ""
echo "2. Add Exchange.ManageAsApp permission (must be done via portal)"
echo ""
echo "3. Assign Exchange Administrator role to app:"
echo "   https://portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/RolesAndAdministrators"
echo ""
echo "4. Update EQUIPMENT_DOMAIN in this script before redeploying"
echo ""
