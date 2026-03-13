#!/bin/bash

set -euo pipefail

if [ "$#" -ne 7 ]; then
  echo "Usage: $0 <key-vault-name> <mygeotab-database> <mygeotab-username> <mygeotab-password> <exchange-pfx-path> <exchange-pfx-password> <equipment-domain>"
  echo ""
  echo "Example:"
  echo "  $0 fleetbridge-prod-kv mydb admin@example.com 'secret' ./exchange-cert.pfx 'pfx-password' example.com"
  exit 1
fi

KEY_VAULT_NAME="$1"
MYGEOTAB_DATABASE="$2"
MYGEOTAB_USERNAME="$3"
MYGEOTAB_PASSWORD="$4"
EXCHANGE_PFX_PATH="$5"
EXCHANGE_PFX_PASSWORD="$6"
EQUIPMENT_DOMAIN="$7"

if [ ! -f "${EXCHANGE_PFX_PATH}" ]; then
  echo "Exchange certificate file not found: ${EXCHANGE_PFX_PATH}"
  exit 1
fi

EXCHANGE_CERT_B64="$(base64 < "${EXCHANGE_PFX_PATH}" | tr -d '\n')"

echo "Seeding Key Vault secrets into: ${KEY_VAULT_NAME}"

az keyvault secret set \
  --vault-name "${KEY_VAULT_NAME}" \
  --name "MyGeotabDatabase" \
  --value "${MYGEOTAB_DATABASE}" \
  >/dev/null

az keyvault secret set \
  --vault-name "${KEY_VAULT_NAME}" \
  --name "MyGeotabUsername" \
  --value "${MYGEOTAB_USERNAME}" \
  >/dev/null

az keyvault secret set \
  --vault-name "${KEY_VAULT_NAME}" \
  --name "MyGeotabPassword" \
  --value "${MYGEOTAB_PASSWORD}" \
  >/dev/null

az keyvault secret set \
  --vault-name "${KEY_VAULT_NAME}" \
  --name "ExchangeCertificate" \
  --value "${EXCHANGE_CERT_B64}" \
  >/dev/null

az keyvault secret set \
  --vault-name "${KEY_VAULT_NAME}" \
  --name "ExchangeCertificatePassword" \
  --value "${EXCHANGE_PFX_PASSWORD}" \
  >/dev/null

az keyvault secret set \
  --vault-name "${KEY_VAULT_NAME}" \
  --name "EquipmentDomain" \
  --value "${EQUIPMENT_DOMAIN}" \
  >/dev/null

echo "Secrets created:"
echo "  MyGeotabDatabase"
echo "  MyGeotabUsername"
echo "  MyGeotabPassword"
echo "  ExchangeCertificate"
echo "  ExchangeCertificatePassword"
echo "  EquipmentDomain"
