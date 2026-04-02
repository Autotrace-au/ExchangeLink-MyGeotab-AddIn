#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "Missing required environment variable: ${name}"
    exit 1
  fi
}

required_vars=(
  RESOURCE_GROUP
  LOCATION
  STORAGE_ACCOUNT_NAME
  CONTAINER_APP_NAME
  CONTAINER_APP_ENVIRONMENT_NAME
  CONTAINER_REGISTRY_NAME
  EQUIPMENT_DOMAIN
  EXCHANGE_TENANT_ID
  EXCHANGE_CLIENT_ID
  MYGEOTAB_DATABASE
  MYGEOTAB_USERNAME
  MYGEOTAB_PASSWORD
  EXCHANGE_PFX_BASE64
  EXCHANGE_PFX_PASSWORD
)

for var_name in "${required_vars[@]}"; do
  require_env "${var_name}"
done

ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-prod}"
APP_NAME="${APP_NAME:-fleetbridge}"
FUNCTION_IMAGE_REPOSITORY="${FUNCTION_IMAGE_REPOSITORY:-fleetbridge-function}"
FUNCTION_IMAGE_TAG="${FUNCTION_IMAGE_TAG_OVERRIDE:-${FUNCTION_IMAGE_TAG:-latest}}"
CONTAINER_APP_MAX_REPLICAS="${CONTAINER_APP_MAX_REPLICAS:-3}"
CONTAINER_CPU="${CONTAINER_CPU:-0.5}"
CONTAINER_MEMORY="${CONTAINER_MEMORY:-1.0Gi}"
DEFAULT_TIMEZONE="${DEFAULT_TIMEZONE:-AUS Eastern Standard Time}"
MYGEOTAB_SERVER="${MYGEOTAB_SERVER:-my.geotab.com}"
MAKE_MAILBOX_VISIBLE_ON_FIRST_SYNC="${MAKE_MAILBOX_VISIBLE_ON_FIRST_SYNC:-true}"

if [ ! -f "${REPO_ROOT}/infra/main.bicep" ]; then
  echo "Missing infra/main.bicep"
  exit 1
fi

echo "Ensuring resource group exists in location: ${LOCATION}"
az group create \
  --name "${RESOURCE_GROUP}" \
  --location "${LOCATION}" \
  >/dev/null

deploy_infra() {
  az deployment group create \
    --resource-group "${RESOURCE_GROUP}" \
    --template-file "${REPO_ROOT}/infra/main.bicep" \
    --parameters \
      location="${LOCATION}" \
      environmentName="${ENVIRONMENT_NAME}" \
      appName="${APP_NAME}" \
      storageAccountName="${STORAGE_ACCOUNT_NAME}" \
      containerAppName="${CONTAINER_APP_NAME}" \
      containerAppEnvironmentName="${CONTAINER_APP_ENVIRONMENT_NAME}" \
      containerRegistryName="${CONTAINER_REGISTRY_NAME}" \
      functionImageRepository="${FUNCTION_IMAGE_REPOSITORY}" \
      functionImageTag="${FUNCTION_IMAGE_TAG}" \
      containerAppMaxReplicas="${CONTAINER_APP_MAX_REPLICAS}" \
      containerCpu="${CONTAINER_CPU}" \
      containerMemory="${CONTAINER_MEMORY}" \
      exchangeTenantId="${EXCHANGE_TENANT_ID}" \
      exchangeClientId="${EXCHANGE_CLIENT_ID}" \
      equipmentDomain="${EQUIPMENT_DOMAIN}" \
      defaultTimezone="${DEFAULT_TIMEZONE}" \
      myGeotabServer="${MYGEOTAB_SERVER}" \
      makeMailboxVisibleOnFirstSync="${MAKE_MAILBOX_VISIBLE_ON_FIRST_SYNC}" \
      myGeotabDatabase="${MYGEOTAB_DATABASE}" \
      myGeotabUsername="${MYGEOTAB_USERNAME}" \
      myGeotabPassword="${MYGEOTAB_PASSWORD}" \
      exchangeCertificate="${EXCHANGE_PFX_BASE64}" \
      exchangeCertificatePassword="${EXCHANGE_PFX_PASSWORD}" \
    >/dev/null
}

echo "Deploying Azure resources to resource group: ${RESOURCE_GROUP}"
deploy_infra

ACR_LOGIN_SERVER="$(az acr show --name "${CONTAINER_REGISTRY_NAME}" --resource-group "${RESOURCE_GROUP}" --query loginServer -o tsv)"

echo "Building and pushing backend container image: ${ACR_LOGIN_SERVER}/${FUNCTION_IMAGE_REPOSITORY}:${FUNCTION_IMAGE_TAG}"
az acr build \
  --registry "${CONTAINER_REGISTRY_NAME}" \
  --image "${FUNCTION_IMAGE_REPOSITORY}:${FUNCTION_IMAGE_TAG}" \
  "${REPO_ROOT}/function-app"

echo "Re-deploying Container App with image tag: ${FUNCTION_IMAGE_TAG}"
deploy_infra

echo "Waiting for Container App ingress FQDN"
for attempt in $(seq 1 30); do
  CONTAINER_APP_FQDN="$(az containerapp show \
    --name "${CONTAINER_APP_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query properties.configuration.ingress.fqdn \
    -o tsv 2>/dev/null || true)"
  if [ -n "${CONTAINER_APP_FQDN}" ] && [ "${CONTAINER_APP_FQDN}" != "null" ]; then
    break
  fi
  echo "Container App ingress not ready yet (attempt ${attempt}/30); waiting 10s"
  sleep 10
done

if [ -z "${CONTAINER_APP_FQDN:-}" ] || [ "${CONTAINER_APP_FQDN}" = "null" ]; then
  echo "Container App ingress did not become ready in time."
  exit 1
fi

echo "Waiting for backend health endpoint"
for attempt in $(seq 1 30); do
  if curl -fsS --max-time 10 "https://${CONTAINER_APP_FQDN}/api/health" >/dev/null 2>&1; then
    echo "Container App is healthy: https://${CONTAINER_APP_FQDN}/api/health"
    echo "Deployment complete."
    exit 0
  fi

  echo "Health check not ready yet (attempt ${attempt}/30); waiting 10s"
  sleep 10
done

echo "Deployment finished, but the health endpoint did not become ready in time."
echo "Check Container Apps revision and console logs in Azure."
exit 1
