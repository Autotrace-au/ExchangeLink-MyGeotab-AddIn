targetScope = 'resourceGroup'

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Short environment name used in resource naming.')
param environmentName string = 'prod'

@description('Base application name used in resource naming.')
param appName string = 'fleetbridge'

@description('Storage account name for the Function App.')
param storageAccountName string

@description('Function App name.')
param functionAppName string

@description('Key Vault name.')
param keyVaultName string

@description('App Service plan name.')
param appServicePlanName string = '${appName}-${environmentName}-plan'

@description('Azure Container Registry name.')
param containerRegistryName string

@description('Repository name for the Function App container image.')
param functionImageRepository string = 'fleetbridge-function'

@description('Container image tag for the Function App.')
param functionImageTag string = 'latest'

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

@description('Secret name containing the MyGeotab password.')
param myGeotabPasswordSecretName string = 'MyGeotabPassword'

@description('Secret name containing the Exchange certificate or secret material.')
param exchangeCertificateSecretName string = 'ExchangeCertificate'

@description('Optional object ID of the deployment principal that needs Key Vault secret write access.')
param deploymentPrincipalObjectId string = ''

@description('Principal type for the deployment principal role assignment.')
@allowed([
  'ServicePrincipal'
  'User'
])
param deploymentPrincipalType string = 'ServicePrincipal'

@description('Allowed CORS origins for the Function App.')
param allowedCorsOrigins array = [
  'https://*.geotab.com'
  'https://*.geotab.com.au'
]

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

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enabledForTemplateDeployment: true
    enableRbacAuthorization: true
    softDeleteRetentionInDays: 90
    enableSoftDelete: true
    publicNetworkAccess: 'Enabled'
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: 'EP1'
    tier: 'ElasticPremium'
  }
  kind: 'functionapp'
  properties: {
    reserved: true
  }
}

var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
var containerImage = '${containerRegistry.properties.loginServer}/${functionImageRepository}:${functionImageTag}'
var keyVaultDnsSuffix = environment().suffixes.keyvaultDns

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux,container'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOCKER|${containerImage}'
      acrUseManagedIdentityCreds: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      cors: {
        allowedOrigins: allowedCorsOrigins
      }
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: storageConnectionString
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
          name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
          value: 'false'
        }
        {
          name: 'DOCKER_REGISTRY_SERVER_URL'
          value: 'https://${containerRegistry.properties.loginServer}'
        }
        {
          name: 'KEY_VAULT_URL'
          value: 'https://${keyVault.name}${keyVaultDnsSuffix}/'
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
          name: 'MYGEOTAB_PASSWORD_SECRET_NAME'
          value: myGeotabPasswordSecretName
        }
        {
          name: 'MYGEOTAB_DATABASE_SECRET_NAME'
          value: 'MyGeotabDatabase'
        }
        {
          name: 'MYGEOTAB_USERNAME_SECRET_NAME'
          value: 'MyGeotabUsername'
        }
        {
          name: 'MYGEOTAB_SERVER'
          value: myGeotabServer
        }
        {
          name: 'EXCHANGE_CERTIFICATE_SECRET_NAME'
          value: exchangeCertificateSecretName
        }
        {
          name: 'EXCHANGE_CERTIFICATE_PASSWORD_SECRET_NAME'
          value: 'ExchangeCertificatePassword'
        }
        {
          name: 'EXCHANGE_ORGANIZATION'
          value: equipmentDomain
        }
        {
          name: 'EQUIPMENT_DOMAIN_SECRET_NAME'
          value: 'EquipmentDomain'
        }
      ]
    }
  }
}

resource keyVaultSecretsUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, functionApp.id, 'KeyVaultSecretsUser')
  scope: keyVault
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    )
  }
}

resource keyVaultSecretsOfficerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deploymentPrincipalObjectId)) {
  name: guid(keyVault.id, deploymentPrincipalObjectId, 'KeyVaultSecretsOfficer')
  scope: keyVault
  properties: {
    principalId: deploymentPrincipalObjectId
    principalType: deploymentPrincipalType
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
    )
  }
}

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, functionApp.id, 'AcrPull')
  scope: containerRegistry
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7f951dda-4ed3-4680-a7ca-43fe172d538d'
    )
  }
}

output functionAppName string = functionApp.name
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}'
output keyVaultUrl string = 'https://${keyVault.name}${keyVaultDnsSuffix}/'
output containerRegistryLoginServer string = containerRegistry.properties.loginServer
output containerImage string = containerImage
