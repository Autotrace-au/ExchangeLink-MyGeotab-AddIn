#!/bin/bash

# FleetBridge Client Onboarding Script
# This script creates an API key for a new client and stores their credentials in Key Vault

set -e  # Exit on error

# Configuration - UPDATE THESE VALUES
KEY_VAULT="fleetbridge-vault"

# Check arguments
if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <client-name> <mygeotab-database> <mygeotab-username> <mygeotab-password> <equipment-domain>"
    echo ""
    echo "Example:"
    echo "  $0 \"Acme Corp\" \"acme\" \"admin@acme.com\" \"password123\" \"acme.com\""
    echo ""
    echo "Note: equipment-domain is the email domain for equipment mailboxes"
    echo "      (e.g., if mailboxes are serial@acme.com, use 'acme.com')"
    exit 1
fi

CLIENT_NAME=$1
DATABASE=$2
USERNAME=$3
PASSWORD=$4
EQUIPMENT_DOMAIN=$5

echo "=========================================="
echo "FleetBridge Client Onboarding"
echo "=========================================="
echo ""
echo "Client Name: $CLIENT_NAME"
echo "Database: $DATABASE"
echo "Username: $USERNAME"
echo "Equipment Domain: $EQUIPMENT_DOMAIN"
echo ""
read -p "Press Enter to continue or Ctrl+C to cancel..."

# Generate unique API key (UUID without dashes, lowercase)
API_KEY=$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-')

echo ""
echo "Generated API Key: $API_KEY"

# Store credentials in Key Vault
echo ""
echo "Storing credentials in Key Vault..."

az keyvault secret set \
  --vault-name $KEY_VAULT \
  --name "client-${API_KEY}-database" \
  --value "$DATABASE" \
  > /dev/null

az keyvault secret set \
  --vault-name $KEY_VAULT \
  --name "client-${API_KEY}-username" \
  --value "$USERNAME" \
  > /dev/null

az keyvault secret set \
  --vault-name $KEY_VAULT \
  --name "client-${API_KEY}-password" \
  --value "$PASSWORD" \
  > /dev/null

az keyvault secret set \
  --vault-name $KEY_VAULT \
  --name "client-${API_KEY}-equipment-domain" \
  --value "$EQUIPMENT_DOMAIN" \
  > /dev/null

# Store client metadata (for reference)
CLIENT_METADATA=$(cat <<EOF
{
  "clientName": "$CLIENT_NAME",
  "database": "$DATABASE",
  "username": "$USERNAME",
  "equipmentDomain": "$EQUIPMENT_DOMAIN",
  "onboardedDate": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
)

az keyvault secret set \
  --vault-name $KEY_VAULT \
  --name "client-${API_KEY}-metadata" \
  --value "$CLIENT_METADATA" \
  > /dev/null

echo "✓ Credentials stored successfully"

# Create client configuration file
CONFIG_FILE="client-configs/${CLIENT_NAME// /-}-config.json"
mkdir -p client-configs

cat > "$CONFIG_FILE" <<EOF
{
  "clientName": "$CLIENT_NAME",
  "apiKey": "$API_KEY",
  "database": "$DATABASE",
  "onboardedDate": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "status": "active",
  "setupInstructions": [
    "1. Send the Client API Key to the client",
    "2. Instruct them to enter it in the FleetBridge Add-In (Sync tab)",
    "3. Have them click 'Save Configuration' and 'Test Connection'",
    "4. Guide them through 'Connect to Exchange' OAuth flow"
  ],
  "apiKeyForClient": "$API_KEY",
  "notes": "Store credentials in Key Vault as: client-${API_KEY}-database, client-${API_KEY}-username, client-${API_KEY}-password"
}
EOF

echo ""
echo "=========================================="
echo "Client Onboarded Successfully!"
echo "=========================================="
echo ""
echo "Client Name: $CLIENT_NAME"
echo "API Key: $API_KEY"
echo "Database: $DATABASE"
echo ""
echo "Configuration file saved to:"
echo "  $CONFIG_FILE"
echo ""
echo "=========================================="
echo "Send to Client:"
echo "=========================================="
echo ""
echo "Your FleetBridge Client API Key:"
echo "  $API_KEY"
echo ""
echo "Keep this key secure - it uniquely identifies your account."
echo ""
echo "Setup Instructions:"
echo "1. Open the FleetBridge Add-In in MyGeotab"
echo "2. Click the 'Sync' tab"
echo "3. Enter your Client API Key: $API_KEY"
echo "4. Click 'Save Configuration'"
echo "5. Click 'Test Connection' to verify"
echo "6. Click 'Connect to Exchange' and grant permissions"
echo ""
echo "=========================================="
echo "Administrator Actions:"
echo "=========================================="
echo ""
echo "To revoke this client's access:"
echo "  az keyvault secret delete --vault-name $KEY_VAULT --name client-${API_KEY}-database"
echo "  az keyvault secret delete --vault-name $KEY_VAULT --name client-${API_KEY}-username"
echo "  az keyvault secret delete --vault-name $KEY_VAULT --name client-${API_KEY}-password"
echo "  az keyvault secret delete --vault-name $KEY_VAULT --name client-${API_KEY}-metadata"
echo ""
echo "To test API key (for debugging):"
echo "  curl https://fleetbridge-mygeotab.azurewebsites.net/api/health"
echo ""
