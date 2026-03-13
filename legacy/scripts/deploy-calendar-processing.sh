#!/bin/bash

# Deploy Calendar Processing Solution
# This script deploys the Function App with PowerShell calendar processing capabilities

set -e

echo "🚀 Deploying Calendar Processing Solution for FleetSync"
echo "=================================================="

# Check if we're in the right directory
if [ ! -f "function_app.py" ]; then
    echo "❌ Error: Must run from azure-functions directory"
    exit 1
fi

# Check required tools
command -v az >/dev/null 2>&1 || { echo "❌ Azure CLI is required but not installed."; exit 1; }
command -v pwsh >/dev/null 2>&1 || { echo "❌ PowerShell Core is required but not installed."; exit 1; }

# Configuration
RESOURCE_GROUP="FleetBridgeRG"
FUNCTION_APP_NAME="fleetbridge-mygeotab"
KEY_VAULT_NAME="fleetbridge-vault"
STORAGE_ACCOUNT="fleetbridgestorage"
MULTI_TENANT_APP_ID="7eeb2358-00de-4da9-a6b7-8522b5353ade"

echo "📋 Configuration:"
echo "   Resource Group: $RESOURCE_GROUP"
echo "   Function App: $FUNCTION_APP_NAME"
echo "   Key Vault: $KEY_VAULT_NAME"
echo ""

# Check if logged into Azure
echo "🔐 Checking Azure CLI authentication..."
if ! az account show >/dev/null 2>&1; then
    echo "❌ Not logged into Azure CLI. Please run: az login"
    exit 1
fi

# Get subscription info
SUBSCRIPTION_ID=$(az account show --query "id" -o tsv)
TENANT_ID=$(az account show --query "tenantId" -o tsv)
echo "✅ Logged in to subscription: $SUBSCRIPTION_ID"
echo "   Tenant ID: $TENANT_ID"

# Check if Function App exists
echo ""
echo "📱 Checking Function App..."
if ! az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$RESOURCE_GROUP" >/dev/null 2>&1; then
    echo "❌ Function App '$FUNCTION_APP_NAME' not found in resource group '$RESOURCE_GROUP'"
    echo "   Please ensure the Function App is deployed first"
    exit 1
fi
echo "✅ Function App found"

# Get Function App system identity
echo ""
echo "🔑 Getting Function App managed identity..."
FUNCTION_APP_PRINCIPAL_ID=$(az functionapp identity show \
    --name "$FUNCTION_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query "principalId" -o tsv)

if [ -z "$FUNCTION_APP_PRINCIPAL_ID" ]; then
    echo "⚠️  Enabling system-assigned managed identity..."
    az functionapp identity assign \
        --name "$FUNCTION_APP_NAME" \
        --resource-group "$RESOURCE_GROUP"
    
    FUNCTION_APP_PRINCIPAL_ID=$(az functionapp identity show \
        --name "$FUNCTION_APP_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query "principalId" -o tsv)
fi

echo "✅ Function App Principal ID: $FUNCTION_APP_PRINCIPAL_ID"

# Grant Key Vault access (using RBAC)
echo ""
echo "🔐 Granting Key Vault access..."

# Check if Key Vault uses RBAC
KEY_VAULT_ID=$(az keyvault show --name "$KEY_VAULT_NAME" --query "id" -o tsv)

# Grant Key Vault Secrets User role for reading secrets
az role assignment create \
    --assignee "$FUNCTION_APP_PRINCIPAL_ID" \
    --role "Key Vault Secrets User" \
    --scope "$KEY_VAULT_ID"

# Grant Key Vault Certificate User role for reading certificates  
az role assignment create \
    --assignee "$FUNCTION_APP_PRINCIPAL_ID" \
    --role "Key Vault Certificates Officer" \
    --scope "$KEY_VAULT_ID"

echo "✅ Key Vault RBAC access granted"

# Create certificates for PowerShell authentication
echo ""
echo "📜 Setting up PowerShell authentication certificates..."

# Check if certificate already exists
CERT_NAME="FleetSync-PowerShell"
if az keyvault certificate show --vault-name "$KEY_VAULT_NAME" --name "$CERT_NAME" >/dev/null 2>&1; then
    echo "✅ Certificate '$CERT_NAME' already exists"
else
    echo "🔨 Creating certificate for PowerShell authentication..."
    
    # Create self-signed certificate policy
    cat > cert-policy.json << EOF
{
  "issuerParameters": {
    "name": "Self"
  },
  "keyProperties": {
    "exportable": true,
    "keySize": 2048,
    "keyType": "RSA",
    "reuseKey": false
  },
  "x509CertificateProperties": {
    "subject": "CN=FleetSync-PowerShell",
    "validityInMonths": 24
  }
}
EOF
    
    # Create certificate
    az keyvault certificate create \
        --vault-name "$KEY_VAULT_NAME" \
        --name "$CERT_NAME" \
        --policy @cert-policy.json
    
    rm cert-policy.json
    echo "✅ Certificate created"
fi

# Get certificate thumbprint
CERT_THUMBPRINT=$(az keyvault certificate show \
    --vault-name "$KEY_VAULT_NAME" \
    --name "$CERT_NAME" \
    --query "x509Thumbprint" -o tsv)

echo "✅ Certificate thumbprint: $CERT_THUMBPRINT"

# Store certificate data in Key Vault for PowerShell use
echo ""
echo "💾 Storing PowerShell configuration..."

# Download certificate as base64 encoded PFX for Linux compatibility
echo "Downloading certificate for Linux PowerShell authentication..."
TEMP_CERT_PATH="/tmp/fleetsync-cert.pfx"
az keyvault certificate download \
    --vault-name "$KEY_VAULT_NAME" \
    --name "$CERT_NAME" \
    --file "$TEMP_CERT_PATH" \
    --encoding PEM

# Convert to base64 for storage
CERT_BASE64=$(base64 -i "$TEMP_CERT_PATH")

# Store the base64 certificate data in Key Vault
az keyvault secret set \
    --vault-name "$KEY_VAULT_NAME" \
    --name "powershell-cert-data" \
    --value "$CERT_BASE64"

# Clean up temporary file
rm -f "$TEMP_CERT_PATH"

echo "✅ Certificate data stored for Linux PowerShell authentication"

# Install Python dependencies if requirements.txt has changed
echo ""
echo "📦 Checking Python dependencies..."
pip install -r requirements.txt --quiet
echo "✅ Dependencies up to date"

# Deploy Function App code
echo ""
echo "🚀 Deploying Function App code..."

# Ensure we have func tools
if ! command -v func >/dev/null 2>&1; then
    echo "⚠️  Azure Functions Core Tools not found. Installing via npm..."
    npm install -g azure-functions-core-tools@4 --unsafe-perm true
fi

# Deploy the function
func azure functionapp publish "$FUNCTION_APP_NAME" --python

echo "✅ Function App deployed"

# Set environment variables
echo ""
echo "⚙️  Setting environment variables..."

az functionapp config appsettings set \
    --name "$FUNCTION_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --settings \
    "USE_KEY_VAULT=true" \
    "KEY_VAULT_URL=https://$KEY_VAULT_NAME.vault.azure.net/" \
    "ENTRA_CLIENT_ID=$MULTI_TENANT_APP_ID"

echo "✅ Environment variables set"

# Test PowerShell availability
echo ""
echo "🧪 Testing PowerShell Core availability in Function App..."

# Create a simple test function to verify pwsh is available
cat > test-powershell.py << 'EOF'
import subprocess
import sys

def test_powershell():
    try:
        result = subprocess.run(['pwsh', '--version'], capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            print(f"✅ PowerShell Core available: {result.stdout.strip()}")
            return True
        else:
            print(f"❌ PowerShell Core failed: {result.stderr}")
            return False
    except FileNotFoundError:
        print("❌ PowerShell Core (pwsh) not found")
        return False
    except Exception as e:
        print(f"❌ Error testing PowerShell: {e}")
        return False

if __name__ == "__main__":
    success = test_powershell()
    sys.exit(0 if success else 1)
EOF

python test-powershell.py
PWSH_TEST_RESULT=$?
rm test-powershell.py

if [ $PWSH_TEST_RESULT -eq 0 ]; then
    echo "✅ PowerShell Core is available"
else
    echo "⚠️  PowerShell Core may not be available in Azure Functions"
    echo "   This might require a custom container or different runtime"
fi

# Display next steps
echo ""
echo "🎉 Deployment Complete!"
echo "======================"
echo ""
echo "Next steps:"
echo "1. Test the calendar processing by calling the sync-to-exchange endpoint"
echo "2. Verify PowerShell execution in Function App logs"
echo "3. Check that Set-CalendarProcessing commands work for equipment mailboxes"
echo ""
echo "Function App URL: https://$FUNCTION_APP_NAME.azurewebsites.net"
echo "Certificate Thumbprint: $CERT_THUMBPRINT"
echo "Certificate stored as base64 data in Key Vault for Linux compatibility"
echo ""
echo "To test PowerShell functionality:"
echo "curl -X POST https://$FUNCTION_APP_NAME.azurewebsites.net/api/sync-to-exchange \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -d '{\"apiKey\": \"your-api-key\", \"maxDevices\": 1}'"
echo ""
echo "Monitor logs with:"
echo "az functionapp logs tail --name $FUNCTION_APP_NAME --resource-group $RESOURCE_GROUP"