#!/usr/bin/env pwsh
#Requires -Version 7

<#
.SYNOPSIS
    Updates MyGeotab device custom properties
.DESCRIPTION
    Updates custom properties for specified MyGeotab devices using the MyGeotab API
    Matches the logic from the proven Azure Function implementation
.PARAMETER ApiKey
    MyGeotab API key for authentication
.PARAMETER DeviceId
    Device ID to update
.PARAMETER Properties
    Properties object to update
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ApiKey,
    
    [Parameter(Mandatory=$true)]
    [string]$DeviceId,
    
    [Parameter(Mandatory=$true)]
    [object]$Properties
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Log incoming properties
Write-Host "=== INCOMING PROPERTIES ==="
Write-Host ($Properties | ConvertTo-Json -Depth 10)
Write-Host "==========================="

# Initialize response
$response = @{
    success = $false
    message = ""
    database = ""
    deviceId = $DeviceId
    executionTimeMs = 0
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    Write-Host "Starting device property update for device: $DeviceId"
    
    # Login to Azure using managed identity (for Container App)
    try {
        $null = az login --identity 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Logged in to Azure using managed identity"
        }
    }
    catch {
        Write-Host "Note: Azure login with managed identity failed, continuing..."
    }
    
    # Get MyGeotab credentials from Key Vault
    Write-Host "Retrieving MyGeotab credentials from Key Vault..."
    $secretPrefix = "client-$ApiKey"
    
    $mygeotabUsername = az keyvault secret show --vault-name fleetbridge-vault --name "$secretPrefix-username" --query value -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to retrieve MyGeotab username: $mygeotabUsername"
    }
    
    $mygeotabPassword = az keyvault secret show --vault-name fleetbridge-vault --name "$secretPrefix-password" --query value -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to retrieve MyGeotab password: $mygeotabPassword"
    }
    
    $mygeotabDatabase = az keyvault secret show --vault-name fleetbridge-vault --name "$secretPrefix-database" --query value -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to retrieve MyGeotab database: $mygeotabDatabase"
    }
    
    Write-Host "Retrieved credentials for database: $mygeotabDatabase"
    $response.database = $mygeotabDatabase
    
    # Convert properties to JSON for Python
    $propertiesJson = $Properties | ConvertTo-Json -Compress -Depth 10
    
    # Execute external Python script to avoid here-string indentation issues
    Write-Host "Executing Python script to update device (external file)..."
    $pythonOutput = $propertiesJson | python3 -u update_device_properties.py --username $mygeotabUsername --password $mygeotabPassword --database $mygeotabDatabase --device-id $DeviceId 2>&1
    # Emit all diagnostic lines BEFORE parsing result (excluding the final JSON line)
    $outputLinesAll = $pythonOutput -split "`n"
    if ($outputLinesAll.Length -gt 1) {
        Write-Host "=== PYTHON DIAGNOSTICS (BEGIN) ==="
        $outputLinesAll[0..($outputLinesAll.Length-2)] | ForEach-Object { Write-Host $_ }
        Write-Host "=== PYTHON DIAGNOSTICS (END) ==="
    }
    $pythonExitCode = $LASTEXITCODE
    
    if ($pythonExitCode -eq 0) {
        # Parse the last line as JSON (the actual result)
        $outputLines = $pythonOutput -split "`n"
        $jsonLine = $outputLines[-1]
        $result = $jsonLine | ConvertFrom-Json
        
        $response.success = $result.success
        $response.message = $result.message
        $response.database = $result.database
        
    Write-Host "✓ Successfully updated device: $DeviceId"
    Write-Host "Result JSON: $jsonLine"
    }
    else {
        # Try to parse error from output
        $outputLines = $pythonOutput -split "`n"
        $jsonLine = $outputLines[-1]
        try {
            $errorResult = $jsonLine | ConvertFrom-Json
            throw $errorResult.error
        }
        catch {
            throw "Python script failed: $pythonOutput"
        }
    }
    
}
catch {
    $errorMessage = $_.Exception.Message
    Write-Host "ERROR: $errorMessage"
    
    $response.success = $false
    $response.message = "Error: $errorMessage"
}
finally {
    $stopwatch.Stop()
    $response.executionTimeMs = $stopwatch.Elapsed.TotalMilliseconds
    
    Write-Host "`nExecution Summary:"
    Write-Host "- Success: $($response.success)"
    Write-Host "- Duration: $([math]::Round($response.executionTimeMs / 1000, 2))s"
}

# Return JSON response
$response | ConvertTo-Json -Depth 10 -Compress
