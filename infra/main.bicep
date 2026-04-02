targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Short environment name used in resource naming.')
param environmentName string = 'prod'

@description('Base application name used in resource naming.')
param appName string = 'fleetbridge'

@description('Storage account name for the backend.')
param storageAccountName string

@description('Container App name.')
param containerAppName string = '${appName}-${environmentName}-app'

@description('Container Apps managed environment name.')
param containerAppEnvironmentName string = '${appName}-${environmentName}-env'

@description('User-assigned managed identity name used for Azure Container Registry pulls.')
param containerRegistryPullIdentityName string = '${appName}-${environmentName}-pull'

@description('Azure Container Registry name.')
param containerRegistryName string

@description('Repository name for the backend container image.')
param functionImageRepository string = 'fleetbridge-function'

@description('Container image tag for the backend.')
param functionImageTag string = 'latest'

@description('Maximum Container App replica count.')
param containerAppMaxReplicas int = 3

@description('Container CPU cores.')
param containerCpu string = '0.5'

@description('Container memory allocation.')
param containerMemory string = '1.0Gi'

@description('Single-tenant Exchange tenant ID.')
param exchangeTenantId string = ''

@description('Single-tenant Exchange app registration client ID.')
param exchangeClientId string = ''

@description('Equipment mailbox domain used for serial-based mailbox lookup.')
param equipmentDomain string

@description('Default timezone applied when no device-specific timezone is available.')
param defaultTimezone string = 'AUS Eastern Standard Time'

@description('MyGeotab API host name.')
param myGeotabServer string = 'my.geotab.com'

@description('Whether first successful sync should make pre-created hidden mailboxes visible.')
param makeMailboxVisibleOnFirstSync bool = true

@description('Whether to deploy the Container App resource.')
param deployContainerApp bool = true

@secure()
@description('MyGeotab database name.')
param myGeotabDatabase string

@secure()
@description('MyGeotab username.')
param myGeotabUsername string

@secure()
@description('MyGeotab password.')
param myGeotabPassword string

@secure()
@description('Base64 encoded Exchange PFX certificate.')
param exchangeCertificate string

@secure()
@description('Exchange PFX certificate password.')
param exchangeCertificatePassword string

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
}

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: containerRegistryName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource managedEnvironment 'Microsoft.App/managedEnvironments@2022-03-01' = {
  name: containerAppEnvironmentName
  location: location
  properties: {}
}

resource containerRegistryPullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: containerRegistryPullIdentityName
  location: location
}

var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
var containerImage = '${containerRegistry.properties.loginServer}/${functionImageRepository}:${functionImageTag}'

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, containerRegistryPullIdentity.id, 'AcrPull')
  scope: containerRegistry
  properties: {
    principalId: containerRegistryPullIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7f951dda-4ed3-4680-a7ca-43fe172d538d'
    )
  }
}

resource containerApp 'Microsoft.App/containerApps@2022-03-01' = if (deployContainerApp) {
  name: containerAppName
  location: location
  kind: 'functionapp'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${containerRegistryPullIdentity.id}': {}
    }
  }
  dependsOn: [
    acrPullRole
  ]
  properties: {
    managedEnvironmentId: managedEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        allowInsecure: false
        targetPort: 80
        transport: 'auto'
      }
      registries: [
        {
          server: containerRegistry.properties.loginServer
          identity: containerRegistryPullIdentity.id
        }
      ]
      secrets: [
        {
          name: 'azurewebjobsstorage'
          value: storageConnectionString
        }
        {
          name: 'mygeotab-database'
          value: myGeotabDatabase
        }
        {
          name: 'mygeotab-username'
          value: myGeotabUsername
        }
        {
          name: 'mygeotab-password'
          value: myGeotabPassword
        }
        {
          name: 'exchange-certificate'
          value: exchangeCertificate
        }
        {
          name: 'exchange-certificate-password'
          value: exchangeCertificatePassword
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'fleetbridge-backend'
          image: containerImage
          env: [
            {
              name: 'AzureWebJobsStorage'
              secretRef: 'azurewebjobsstorage'
            }
            {
              name: 'MYGEOTAB_DATABASE'
              secretRef: 'mygeotab-database'
            }
            {
              name: 'MYGEOTAB_USERNAME'
              secretRef: 'mygeotab-username'
            }
            {
              name: 'MYGEOTAB_PASSWORD'
              secretRef: 'mygeotab-password'
            }
            {
              name: 'EXCHANGE_CERTIFICATE'
              secretRef: 'exchange-certificate'
            }
            {
              name: 'EXCHANGE_CERTIFICATE_PASSWORD'
              secretRef: 'exchange-certificate-password'
            }
            {
              name: 'FUNCTIONS_EXTENSION_VERSION'
              value: '~4'
            }
            {
              name: 'FUNCTIONS_WORKER_RUNTIME'
              value: 'python'
            }
            {
              name: 'EXCHANGE_TENANT_ID'
              value: exchangeTenantId
            }
            {
              name: 'EXCHANGE_CLIENT_ID'
              value: exchangeClientId
            }
            {
              name: 'EQUIPMENT_DOMAIN'
              value: equipmentDomain
            }
            {
              name: 'DEFAULT_TIMEZONE'
              value: defaultTimezone
            }
            {
              name: 'MAKE_MAILBOX_VISIBLE_ON_FIRST_SYNC'
              value: string(makeMailboxVisibleOnFirstSync)
            }
            {
              name: 'MYGEOTAB_SERVER'
              value: myGeotabServer
            }
            {
              name: 'EXCHANGE_ORGANIZATION'
              value: equipmentDomain
            }
          ]
          resources: {
            cpu: json(containerCpu)
            memory: containerMemory
          }
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: containerAppMaxReplicas
      }
    }
  }
}

output containerAppName string = deployContainerApp ? containerApp!.name : ''
output containerAppUrl string = deployContainerApp ? 'https://${containerApp!.properties.configuration.ingress.fqdn}' : ''
output containerRegistryLoginServer string = containerRegistry.properties.loginServer
output containerImage string = containerImage
