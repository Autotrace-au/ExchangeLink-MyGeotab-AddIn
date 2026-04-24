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
  ENTRA_API_AUDIENCE
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
APP_NAME="${APP_NAME:-exchangelink}"
FUNCTION_IMAGE_REPOSITORY="${FUNCTION_IMAGE_REPOSITORY:-exchangelink-function}"
FUNCTION_IMAGE_TAG="${FUNCTION_IMAGE_TAG_OVERRIDE:-${FUNCTION_IMAGE_TAG:-latest}}"
CONTAINER_APP_MAX_REPLICAS="${CONTAINER_APP_MAX_REPLICAS:-3}"
CONTAINER_CPU="${CONTAINER_CPU:-0.5}"
CONTAINER_MEMORY="${CONTAINER_MEMORY:-1.0Gi}"
SCHEDULER_JOB_NAME="${SCHEDULER_JOB_NAME:-${APP_NAME}-${ENVIRONMENT_NAME}-scheduler}"
SCHEDULER_CPU="${SCHEDULER_CPU:-0.25}"
SCHEDULER_MEMORY="${SCHEDULER_MEMORY:-0.5Gi}"
SCHEDULER_HEARTBEAT_CRON="${SCHEDULER_HEARTBEAT_CRON:-*/5 * * * *}"
SCHEDULER_REPLICA_TIMEOUT="${SCHEDULER_REPLICA_TIMEOUT:-1800}"
SCHEDULER_REPLICA_RETRY_LIMIT="${SCHEDULER_REPLICA_RETRY_LIMIT:-1}"
DEFAULT_TIMEZONE="${DEFAULT_TIMEZONE:-AUS Eastern Standard Time}"
MYGEOTAB_SERVER="${MYGEOTAB_SERVER:-my.geotab.com}"
MAKE_MAILBOX_VISIBLE_ON_FIRST_SYNC="${MAKE_MAILBOX_VISIBLE_ON_FIRST_SYNC:-true}"
ENTRA_TENANT_ID="${ENTRA_TENANT_ID:-${EXCHANGE_TENANT_ID}}"
ENTRA_REQUIRED_ROLE="${ENTRA_REQUIRED_ROLE:-ExchangeLink.Operator}"
ENTRA_CI_ROLE="${ENTRA_CI_ROLE:-}"
ALLOWED_CORS_ORIGINS="${ALLOWED_CORS_ORIGINS:-https://my.geotab.com}"
MANUAL_SYNC_COOLDOWN_SECONDS="${MANUAL_SYNC_COOLDOWN_SECONDS:-60}"

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
  local deployment_name="$1"
  local deploy_container_app="$2"

  az deployment group create \
    --name "${deployment_name}" \
    --resource-group "${RESOURCE_GROUP}" \
    --template-file "${REPO_ROOT}/infra/main.bicep" \
    --parameters \
      location="${LOCATION}" \
      environmentName="${ENVIRONMENT_NAME}" \
      appName="${APP_NAME}" \
      storageAccountName="${STORAGE_ACCOUNT_NAME}" \
      containerAppName="${CONTAINER_APP_NAME}" \
      schedulerJobName="${SCHEDULER_JOB_NAME}" \
      containerAppEnvironmentName="${CONTAINER_APP_ENVIRONMENT_NAME}" \
      containerRegistryName="${CONTAINER_REGISTRY_NAME}" \
      functionImageRepository="${FUNCTION_IMAGE_REPOSITORY}" \
      functionImageTag="${FUNCTION_IMAGE_TAG}" \
      containerAppMaxReplicas="${CONTAINER_APP_MAX_REPLICAS}" \
      containerCpu="${CONTAINER_CPU}" \
      containerMemory="${CONTAINER_MEMORY}" \
      schedulerCpu="${SCHEDULER_CPU}" \
      schedulerMemory="${SCHEDULER_MEMORY}" \
      schedulerHeartbeatCron="${SCHEDULER_HEARTBEAT_CRON}" \
      schedulerReplicaTimeout="${SCHEDULER_REPLICA_TIMEOUT}" \
      schedulerReplicaRetryLimit="${SCHEDULER_REPLICA_RETRY_LIMIT}" \
      exchangeTenantId="${EXCHANGE_TENANT_ID}" \
      exchangeClientId="${EXCHANGE_CLIENT_ID}" \
      entraTenantId="${ENTRA_TENANT_ID}" \
      entraApiAudience="${ENTRA_API_AUDIENCE}" \
      entraRequiredRole="${ENTRA_REQUIRED_ROLE}" \
      entraCiRole="${ENTRA_CI_ROLE}" \
      allowedCorsOrigins="${ALLOWED_CORS_ORIGINS}" \
      manualSyncCooldownSeconds="${MANUAL_SYNC_COOLDOWN_SECONDS}" \
      equipmentDomain="${EQUIPMENT_DOMAIN}" \
      defaultTimezone="${DEFAULT_TIMEZONE}" \
      myGeotabServer="${MYGEOTAB_SERVER}" \
      makeMailboxVisibleOnFirstSync="${MAKE_MAILBOX_VISIBLE_ON_FIRST_SYNC}" \
      deployContainerApp="${deploy_container_app}" \
      myGeotabDatabase="${MYGEOTAB_DATABASE}" \
      myGeotabUsername="${MYGEOTAB_USERNAME}" \
      myGeotabPassword="${MYGEOTAB_PASSWORD}" \
      exchangeCertificate="${EXCHANGE_PFX_BASE64}" \
      exchangeCertificatePassword="${EXCHANGE_PFX_PASSWORD}" \
    >/dev/null
}

echo "Deploying foundation Azure resources to resource group: ${RESOURCE_GROUP}"
deploy_infra foundation false

ACR_LOGIN_SERVER="$(az acr show --name "${CONTAINER_REGISTRY_NAME}" --resource-group "${RESOURCE_GROUP}" --query loginServer -o tsv)"

echo "Building and pushing backend container image: ${ACR_LOGIN_SERVER}/${FUNCTION_IMAGE_REPOSITORY}:${FUNCTION_IMAGE_TAG}"
az acr build \
  --registry "${CONTAINER_REGISTRY_NAME}" \
  --image "${FUNCTION_IMAGE_REPOSITORY}:${FUNCTION_IMAGE_TAG}" \
  "${REPO_ROOT}/function-app"

echo "Deploying Container App with image tag: ${FUNCTION_IMAGE_TAG}"
deploy_infra app true

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
  BACKEND_URL="https://${CONTAINER_APP_FQDN}"
  if curl -fsS --max-time 10 "${BACKEND_URL}/api/health" >/dev/null 2>&1; then
    echo "Container App is healthy: ${BACKEND_URL}/api/health"
    echo "Checking automatic sync schedule endpoint and browser preflight"
    if ! SCHEDULE_PREFLIGHT_HEADERS="$(curl -fsS -i --max-time 10 -X OPTIONS \
      -H "Origin: https://my.geotab.com" \
      -H "Access-Control-Request-Method: PUT" \
      -H "Access-Control-Request-Headers: authorization,content-type" \
      "${BACKEND_URL}/api/sync-schedule")"; then
      echo "Sync schedule preflight request failed."
      exit 1
    fi

    if ! printf '%s' "${SCHEDULE_PREFLIGHT_HEADERS}" | tr -d '\r' | grep -Eqi '^access-control-allow-origin: https://my\.geotab\.com$'; then
      echo "Sync schedule preflight did not return Access-Control-Allow-Origin."
      exit 1
    fi

    if ! printf '%s' "${SCHEDULE_PREFLIGHT_HEADERS}" | tr -d '\r' | grep -Eqi '^access-control-allow-methods: .*PUT'; then
      echo "Sync schedule preflight did not allow PUT."
      exit 1
    fi

    echo "Deployment complete."
    exit 0
  fi

  echo "Health check not ready yet (attempt ${attempt}/30); waiting 10s"
  sleep 10
done

echo "Deployment finished, but the health endpoint did not become ready in time."
echo "Check Container Apps revision and console logs in Azure."
exit 1
