#!/bin/bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <resource-group> <parameters-file>"
  echo ""
  echo "Example:"
  echo "  $0 FleetBridgeRG infra/parameters.prod.json"
  exit 1
fi

RESOURCE_GROUP="$1"
PARAMETERS_FILE="$2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ ! -f "${REPO_ROOT}/infra/main.bicep" ]; then
  echo "Missing infra/main.bicep"
  exit 1
fi

if [ ! -f "${REPO_ROOT}/${PARAMETERS_FILE}" ] && [ ! -f "${PARAMETERS_FILE}" ]; then
  echo "Parameters file not found: ${PARAMETERS_FILE}"
  exit 1
fi

PARAMETERS_PATH="${PARAMETERS_FILE}"
if [ -f "${REPO_ROOT}/${PARAMETERS_FILE}" ]; then
  PARAMETERS_PATH="${REPO_ROOT}/${PARAMETERS_FILE}"
fi

DEPLOYMENT_PRINCIPAL_OBJECT_ID="${DEPLOYMENT_PRINCIPAL_OBJECT_ID:-}"
DEPLOYMENT_PRINCIPAL_TYPE="${DEPLOYMENT_PRINCIPAL_TYPE:-}"
if [ -z "${DEPLOYMENT_PRINCIPAL_OBJECT_ID}" ]; then
  if DEPLOYMENT_PRINCIPAL_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null)"; then
    DEPLOYMENT_PRINCIPAL_TYPE="User"
  elif [ -n "${AZURE_CLIENT_ID:-}" ]; then
    DEPLOYMENT_PRINCIPAL_OBJECT_ID="$(az ad sp show --id "${AZURE_CLIENT_ID}" --query id -o tsv)"
    DEPLOYMENT_PRINCIPAL_TYPE="ServicePrincipal"
  else
    echo "Could not determine deployment principal object ID."
    echo "Set DEPLOYMENT_PRINCIPAL_OBJECT_ID or AZURE_CLIENT_ID before running this script."
    exit 1
  fi
fi

if [ -z "${DEPLOYMENT_PRINCIPAL_TYPE}" ]; then
  DEPLOYMENT_PRINCIPAL_TYPE="ServicePrincipal"
fi

echo "Deploying Azure resources to resource group: ${RESOURCE_GROUP}"
LOCATION="$(python3 - <<'PY' "${PARAMETERS_PATH}"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

print(data["parameters"].get("location", {}).get("value", "australiaeast"))
PY
)"

echo "Ensuring resource group exists in location: ${LOCATION}"
az group create \
  --name "${RESOURCE_GROUP}" \
  --location "${LOCATION}" \
  >/dev/null

az deployment group create \
  --resource-group "${RESOURCE_GROUP}" \
  --template-file "${REPO_ROOT}/infra/main.bicep" \
  --parameters @"${PARAMETERS_PATH}" \
  --parameters deploymentPrincipalObjectId="${DEPLOYMENT_PRINCIPAL_OBJECT_ID}" \
  --parameters deploymentPrincipalType="${DEPLOYMENT_PRINCIPAL_TYPE}"

CONTAINER_APP_NAME="$(python3 - <<'PY' "${PARAMETERS_PATH}"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

print(data["parameters"]["containerAppName"]["value"])
PY
)"

ACR_NAME="$(python3 - <<'PY' "${PARAMETERS_PATH}"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

print(data["parameters"]["containerRegistryName"]["value"])
PY
)"

IMAGE_REPOSITORY="$(python3 - <<'PY' "${PARAMETERS_PATH}"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

print(data["parameters"].get("functionImageRepository", {}).get("value", "fleetbridge-function"))
PY
)"

IMAGE_TAG="$(python3 - <<'PY' "${PARAMETERS_PATH}"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

print(data["parameters"].get("functionImageTag", {}).get("value", "latest"))
PY
)"

if [ -n "${FUNCTION_IMAGE_TAG_OVERRIDE:-}" ]; then
  IMAGE_TAG="${FUNCTION_IMAGE_TAG_OVERRIDE}"
fi

ACR_LOGIN_SERVER="$(az acr show --name "${ACR_NAME}" --resource-group "${RESOURCE_GROUP}" --query loginServer -o tsv)"

echo "Building and pushing backend container image: ${ACR_LOGIN_SERVER}/${IMAGE_REPOSITORY}:${IMAGE_TAG}"
az acr build \
  --registry "${ACR_NAME}" \
  --image "${IMAGE_REPOSITORY}:${IMAGE_TAG}" \
  "${REPO_ROOT}/function-app"

echo "Updating Container App image tag to: ${IMAGE_TAG}"
az deployment group create \
  --resource-group "${RESOURCE_GROUP}" \
  --template-file "${REPO_ROOT}/infra/main.bicep" \
  --parameters @"${PARAMETERS_PATH}" \
  --parameters deploymentPrincipalObjectId="${DEPLOYMENT_PRINCIPAL_OBJECT_ID}" \
  --parameters deploymentPrincipalType="${DEPLOYMENT_PRINCIPAL_TYPE}" \
  --parameters functionImageTag="${IMAGE_TAG}" \
  >/dev/null

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
