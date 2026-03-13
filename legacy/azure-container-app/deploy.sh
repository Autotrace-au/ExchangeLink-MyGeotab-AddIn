#!/bin/bash

# Azure Container App Deployment Script for Exchange Calendar Processing

set -e

# Configuration
RESOURCE_GROUP="fleetbridge-rg"
CONTAINER_APP_ENV="fleetbridge-env"
CONTAINER_APP_NAME="exchange-calendar-processor"
CONTAINER_REGISTRY="fleetbridgeregistry"
IMAGE_NAME="exchange-calendar-processor"
LOCATION="eastus"

echo "🚀 Starting Azure Container App deployment..."

# Build and push container image
echo "📦 Building container image..."
docker build -t ${CONTAINER_REGISTRY}.azurecr.io/${IMAGE_NAME}:latest .

echo "🔐 Logging into Azure Container Registry..."
az acr login --name ${CONTAINER_REGISTRY}

echo "📤 Pushing image to registry..."
docker push ${CONTAINER_REGISTRY}.azurecr.io/${IMAGE_NAME}:latest

# Create or update Container App
echo "🔧 Deploying Container App..."
az containerapp create \
  --name ${CONTAINER_APP_NAME} \
  --resource-group ${RESOURCE_GROUP} \
  --environment ${CONTAINER_APP_ENV} \
  --image ${CONTAINER_REGISTRY}.azurecr.io/${IMAGE_NAME}:latest \
  --target-port 8080 \
  --ingress external \
  --min-replicas 0 \
  --max-replicas 100 \
  --cpu 1.0 \
  --memory 2.0Gi \
  --scale-rule-name http-scale-rule \
  --scale-rule-http-concurrency 10 \
  --registry-server ${CONTAINER_REGISTRY}.azurecr.io \
  --registry-identity system

echo "✅ Container App deployed successfully!"

# Get the URL
CONTAINER_APP_URL=$(az containerapp show \
  --name ${CONTAINER_APP_NAME} \
  --resource-group ${RESOURCE_GROUP} \
  --query "properties.configuration.ingress.fqdn" \
  --output tsv)

echo "🌐 Container App URL: https://${CONTAINER_APP_URL}"
echo "🔗 Health endpoint: https://${CONTAINER_APP_URL}/health"
echo "🔗 Process endpoint: https://${CONTAINER_APP_URL}/process-mailbox"

# Test health endpoint
echo "🧪 Testing health endpoint..."
curl -s "https://${CONTAINER_APP_URL}/health" | jq .

echo "🎉 Deployment complete!"