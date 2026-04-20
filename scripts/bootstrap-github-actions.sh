#!/bin/bash

set -euo pipefail

if [ "$#" -ne 8 ]; then
  echo "Usage: $0 <github-repo> <subscription-id> <exchange-app-id> <mygeotab-database> <mygeotab-username> <mygeotab-password> <equipment-domain> <exchange-cert-display-name>"
  echo ""
  echo "Example:"
  echo "  $0 Autotrace-au/ExchangeLink-MyGeotab-AddIn <subscription-id> <exchange-app-id> goac admin@example.com 'secret' garageofawesome.com.au exchangelink-gha-cert"
  exit 1
fi

GITHUB_REPO="$1"
SUBSCRIPTION_ID="$2"
EXCHANGE_APP_ID="$3"
MYGEOTAB_DATABASE="$4"
MYGEOTAB_USERNAME="$5"
MYGEOTAB_PASSWORD="$6"
EQUIPMENT_DOMAIN="$7"
EXCHANGE_CERT_DISPLAY_NAME="$8"

TENANT_ID="$(az account show --query tenantId -o tsv)"
SUBSCRIPTION_SCOPE="/subscriptions/${SUBSCRIPTION_ID}"
DEPLOY_APP_NAME="ExchangeLink GitHub Actions"
FEDERATED_CREDENTIAL_NAME="github-main"
TEMP_DIR="$(mktemp -d)"
CERT_PATH="${TEMP_DIR}/exchange-gha-cert.pfx"

cleanup() {
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

echo "Ensuring Azure deployment app registration exists"
DEPLOY_APP_ID="$(az ad app list --display-name "${DEPLOY_APP_NAME}" --query "[0].appId" -o tsv)"
if [ -z "${DEPLOY_APP_ID}" ]; then
  DEPLOY_APP_ID="$(az ad app create --display-name "${DEPLOY_APP_NAME}" --sign-in-audience AzureADMyOrg --query appId -o tsv)"
fi

echo "Ensuring service principal exists"
DEPLOY_SP_OBJECT_ID="$(az ad sp show --id "${DEPLOY_APP_ID}" --query id -o tsv 2>/dev/null || true)"
if [ -z "${DEPLOY_SP_OBJECT_ID}" ]; then
  az ad sp create --id "${DEPLOY_APP_ID}" >/dev/null
  DEPLOY_SP_OBJECT_ID="$(az ad sp show --id "${DEPLOY_APP_ID}" --query id -o tsv)"
fi

echo "Configuring GitHub OIDC federated credential"
FEDERATED_CREDENTIAL_FILE="${TEMP_DIR}/federated-credential.json"
cat > "${FEDERATED_CREDENTIAL_FILE}" <<EOF
{
  "name": "${FEDERATED_CREDENTIAL_NAME}",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:${GITHUB_REPO}:ref:refs/heads/main",
  "description": "GitHub Actions deployment for ${GITHUB_REPO}",
  "audiences": [
    "api://AzureADTokenExchange"
  ]
}
EOF
az ad app federated-credential delete --id "${DEPLOY_APP_ID}" --federated-credential-id "${FEDERATED_CREDENTIAL_NAME}" >/dev/null 2>&1 || true
az ad app federated-credential create --id "${DEPLOY_APP_ID}" --parameters "@${FEDERATED_CREDENTIAL_FILE}" >/dev/null

echo "Assigning Azure roles to deployment principal"
az role assignment create --assignee-object-id "${DEPLOY_SP_OBJECT_ID}" --assignee-principal-type ServicePrincipal --role Contributor --scope "${SUBSCRIPTION_SCOPE}" >/dev/null 2>&1 || true
az role assignment create --assignee-object-id "${DEPLOY_SP_OBJECT_ID}" --assignee-principal-type ServicePrincipal --role "User Access Administrator" --scope "${SUBSCRIPTION_SCOPE}" >/dev/null 2>&1 || true

echo "Generating Exchange certificate for runtime auth"
CERT_PASSWORD="$(openssl rand -base64 36 | tr -d '\n')"
openssl req -x509 -newkey rsa:2048 -keyout "${TEMP_DIR}/exchange.key" -out "${TEMP_DIR}/exchange.crt" -days 365 -nodes -subj "/CN=${EXCHANGE_CERT_DISPLAY_NAME}" >/dev/null 2>&1
openssl pkcs12 -export -out "${CERT_PATH}" -inkey "${TEMP_DIR}/exchange.key" -in "${TEMP_DIR}/exchange.crt" -password "pass:${CERT_PASSWORD}" >/dev/null 2>&1
az ad app credential reset \
  --id "${EXCHANGE_APP_ID}" \
  --cert "@${TEMP_DIR}/exchange.crt" \
  --append \
  >/dev/null

EXCHANGE_PFX_BASE64="$(base64 < "${CERT_PATH}" | tr -d '\n')"

echo "Writing GitHub Actions secrets"
gh secret set AZURE_CLIENT_ID --repo "${GITHUB_REPO}" --body "${DEPLOY_APP_ID}"
gh secret set AZURE_TENANT_ID --repo "${GITHUB_REPO}" --body "${TENANT_ID}"
gh secret set AZURE_SUBSCRIPTION_ID --repo "${GITHUB_REPO}" --body "${SUBSCRIPTION_ID}"
gh secret set MYGEOTAB_DATABASE --repo "${GITHUB_REPO}" --body "${MYGEOTAB_DATABASE}"
gh secret set MYGEOTAB_USERNAME --repo "${GITHUB_REPO}" --body "${MYGEOTAB_USERNAME}"
gh secret set MYGEOTAB_PASSWORD --repo "${GITHUB_REPO}" --body "${MYGEOTAB_PASSWORD}"
gh secret set EXCHANGE_PFX_BASE64 --repo "${GITHUB_REPO}" --body "${EXCHANGE_PFX_BASE64}"
gh secret set EXCHANGE_PFX_PASSWORD --repo "${GITHUB_REPO}" --body "${CERT_PASSWORD}"

echo "Bootstrap complete."
echo "Azure client ID: ${DEPLOY_APP_ID}"
echo "Tenant ID: ${TENANT_ID}"
echo "Subscription ID: ${SUBSCRIPTION_ID}"
