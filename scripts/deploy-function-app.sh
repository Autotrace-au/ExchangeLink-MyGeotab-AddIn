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
  --parameters @"${PARAMETERS_PATH}"

FUNCTION_APP_NAME="$(python3 - <<'PY' "${PARAMETERS_PATH}"
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

print(data["parameters"]["functionAppName"]["value"])
PY
)"

FUNCTION_APP_HOST="${FUNCTION_APP_NAME}.azurewebsites.net"

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

echo "Building and pushing Function App container image: ${ACR_LOGIN_SERVER}/${IMAGE_REPOSITORY}:${IMAGE_TAG}"
az acr build \
  --registry "${ACR_NAME}" \
  --image "${IMAGE_REPOSITORY}:${IMAGE_TAG}" \
  "${REPO_ROOT}/function-app"

echo "Updating Function App container tag to: ${IMAGE_TAG}"
az deployment group create \
  --resource-group "${RESOURCE_GROUP}" \
  --template-file "${REPO_ROOT}/infra/main.bicep" \
  --parameters @"${PARAMETERS_PATH}" \
  --parameters functionImageTag="${IMAGE_TAG}" \
  >/dev/null

echo "Restarting Function App to pull the latest image"
az functionapp restart \
  --name "${FUNCTION_APP_NAME}" \
  --resource-group "${RESOURCE_GROUP}"

echo "Waiting for Function App health endpoint"
for attempt in $(seq 1 30); do
  if curl -fsS --max-time 10 "https://${FUNCTION_APP_HOST}/api/health" >/dev/null 2>&1; then
    echo "Function App is healthy: https://${FUNCTION_APP_HOST}/api/health"
    echo "Deployment complete."
    exit 0
  fi

  echo "Health check not ready yet (attempt ${attempt}/30); waiting 10s"
  sleep 10
done

echo "Deployment finished, but the health endpoint did not become ready in time."
echo "Check container startup logs in the Azure Portal or via Kudu."
exit 1
