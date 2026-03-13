# PowerShell HTTP Server for Exchange Calendar Processing
# Multi-tenant SaaS version with API key (Function key style) enforcement
# TODO: Replace environment variable key store with Azure Key Vault + persistent metadata (Cosmos/Table) for production

function Get-AllowedApiKeys {
    <#
        Returns the set of allowed API keys.
        Current strategy (bootstrap): comma-separated environment variable FLEETBRIDGE_ALLOWED_KEYS.
        Upgrade path:
          - Azure Key Vault secret "fleetbridge-apikeys" storing JSON array [{"keyId":"...","hash":"...","tenantId":"...","created":"...","revoked":false}]
          - Cache in-memory with refresh TTL (e.g. 5 minutes)
    #>
    if (-not $script:ApiKeyCache -or (Get-Date) -gt $script:ApiKeyCacheExpiry) {
        $raw = $env:FLEETBRIDGE_ALLOWED_KEYS
        $list = @()
        if ($raw) {
            $list = $raw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        }
        $script:ApiKeyCache = $list
        # 5 minute cache
        $script:ApiKeyCacheExpiry = (Get-Date).AddMinutes(5)
    }
    return $script:ApiKeyCache
}

function Test-ApiKey {
    param(
        [string]$ApiKey
    )
    if (-not $ApiKey) { return $false }
    $allowed = Get-AllowedApiKeys
    return $allowed -contains $ApiKey
}

function Test-ApiKeyAuthorization {
    param(
        [System.Net.HttpListenerRequest]$Request,
        [System.Net.HttpListenerResponse]$Response
    )
    # Support both x-functions-key (Azure Functions style) and x-api-key headers
    $apiKeyHeader = $Request.Headers['x-functions-key']
    if (-not $apiKeyHeader) { $apiKeyHeader = $Request.Headers['x-api-key'] }
    # Fallback: allow body-provided key for backward compatibility (deprecated)
    $bodyKey = $null
    try {
        if ($Request.HasEntityBody) {
            $sr = New-Object System.IO.StreamReader($Request.InputStream)
            $rawBody = $sr.ReadToEnd(); $sr.Close()
            if ($rawBody) {
                try { $parsed = $rawBody | ConvertFrom-Json } catch { $parsed = $null }
                if ($parsed -and $parsed.apiKey) { $bodyKey = $parsed.apiKey }
                elseif ($parsed -and $parsed.clientId) { $bodyKey = $parsed.clientId }
            }
            # Reset stream position for subsequent handlers
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($rawBody)
            $Request.InputStream.SetLength(0)
            $Request.InputStream.Write($bytes,0,$bytes.Length)
            $Request.InputStream.Position = 0
        }
    } catch {}

    $apiKey = if ($apiKeyHeader) { $apiKeyHeader } else { $bodyKey }

    if (-not (Test-ApiKey -ApiKey $apiKey)) {
        $errorResponse = @{ 
            success = $false
            timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            error = 'Invalid or missing API key'
        } | ConvertTo-Json
        $Response.StatusCode = 401
        $Response.ContentType = 'application/json'
        $buffer = [System.Text.Encoding]::UTF8.GetBytes($errorResponse)
        $Response.OutputStream.Write($buffer,0,$buffer.Length)
        $Response.Close()
        return $null
    }
    return $apiKey
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add('http://+:8080/')
$listener.Start()

Write-Host "Exchange Calendar Processor listening on port 8080..."

while ($listener.IsListening) {
    try {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        
        # Add comprehensive CORS headers
        $response.Headers.Add("Access-Control-Allow-Origin", "*")
        $response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS, PUT, DELETE")
        $response.Headers.Add("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Requested-With, Accept, Origin")
        $response.Headers.Add("Access-Control-Max-Age", "3600")
        
        $path = $request.Url.AbsolutePath
        $method = $request.HttpMethod
        
        Write-Host "Request: $method $path"
        
        if ($method -eq "OPTIONS") {
            # Handle preflight requests
            $response.StatusCode = 200
            $response.Close()
            continue
        }
        
        if ($path -eq "/health" -and $method -eq "GET") {
            # Health check endpoint
            $healthResponse = @{
                timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                status = "healthy"
                service = "exchange-calendar-processor"
            } | ConvertTo-Json
            
            $response.StatusCode = 200
            $response.ContentType = "application/json"
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($healthResponse)
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        elseif ($path -eq "/process-mailbox" -and $method -eq "POST") {
            $validatedKey = Test-ApiKeyAuthorization -Request $request -Response $response
            if (-not $validatedKey) { continue }
            # Calendar processing endpoint
            $reader = New-Object System.IO.StreamReader($request.InputStream)
            $requestBody = $reader.ReadToEnd()
            $reader.Close()
            
            try {
                $requestData = $requestBody | ConvertFrom-Json
                
                # Validate required parameters
                if (-not $requestData.mailboxEmail -or -not $requestData.deviceName -or -not $requestData.tenantId -or -not $requestData.clientId) {
                    $errorResponse = @{
                        success = $false
                        timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                        error = "Missing required parameters: mailboxEmail, deviceName, tenantId, clientId"
                    } | ConvertTo-Json
                    
                    $response.StatusCode = 400
                    $response.ContentType = "application/json"
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($errorResponse)
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                else {
                    # Call the calendar processing script
                    $result = & ./exchange-processor.ps1 -MailboxEmail $requestData.mailboxEmail -DeviceName $requestData.deviceName -TenantId $requestData.tenantId -ClientId $requestData.clientId -CertificateData $requestData.certificateData
                    
                    $response.StatusCode = 200
                    $response.ContentType = "application/json"
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($result)
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
            }
            catch {
                $errorResponse = @{
                    success = $false
                    timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                    error = "Error processing request: $($_.Exception.Message)"
                } | ConvertTo-Json
                
                $response.StatusCode = 500
                $response.ContentType = "application/json"
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($errorResponse)
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            }
        }
        elseif ($path -eq "/api/sync-to-exchange" -and $method -eq "POST") {
            $validatedKey = Test-ApiKeyAuthorization -Request $request -Response $response
            if (-not $validatedKey) { continue }
            # MyGeotab Add-in compatibility endpoint - PRODUCTION VERSION
            $reader = New-Object System.IO.StreamReader($request.InputStream)
            $requestBody = $reader.ReadToEnd()
            $reader.Close()
            
            try {
                $requestData = $requestBody | ConvertFrom-Json
                
                # Extract parameters from add-in request format (support both clientId and apiKey)
                $apiKey = if ($requestData.clientId) { $requestData.clientId } else { $requestData.apiKey }
                $maxDevices = if ($requestData.maxDevices) { $requestData.maxDevices } else { 0 }
                
                Write-Host "=== PRODUCTION SYNC REQUEST ==="
                Write-Host "API Key: $($apiKey.Substring(0,8))..., Max Devices: $maxDevices"
                
                if (-not $apiKey) {
                    $errorResponse = @{
                        success = $false
                        timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                        error = "API Key is required for MyGeotab authentication"
                        processed = 0
                        successful = 0
                        failed = 0
                    } | ConvertTo-Json
                    
                    $response.StatusCode = 400
                    $response.ContentType = "application/json"
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($errorResponse)
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                else {
                    # Call the production MyGeotab sync script
                    Write-Host "Executing production MyGeotab to Exchange sync..."
                    $syncResult = & ./mygeotab-exchange-sync.ps1 -ApiKey $apiKey -MaxDevices $maxDevices
                    
                    $response.StatusCode = 200
                    $response.ContentType = "application/json"
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($syncResult)
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
            }
            catch {
                $errorResponse = @{
                    success = $false
                    timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                    error = "Error processing production sync request: $($_.Exception.Message)"
                    processed = 0
                    successful = 0
                    failed = 0
                } | ConvertTo-Json
                
                $response.StatusCode = 500
                $response.ContentType = "application/json"
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($errorResponse)
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            }
        }
        elseif ($path -eq "/api/update-device-properties" -and $method -eq "POST") {
            $validatedKey = Test-ApiKeyAuthorization -Request $request -Response $response
            if (-not $validatedKey) { continue }
            # Update device properties endpoint
            $reader = New-Object System.IO.StreamReader($request.InputStream)
            $requestBody = $reader.ReadToEnd()
            $reader.Close()
            
            try {
                $requestData = $requestBody | ConvertFrom-Json
                
                # Extract parameters
                $apiKey = if ($requestData.clientId) { $requestData.clientId } else { $requestData.apiKey }
                $deviceId = $requestData.deviceId
                $properties = $requestData.properties
                
                Write-Host "=== UPDATE DEVICE PROPERTIES REQUEST ==="
                Write-Host "API Key: $($apiKey.Substring(0,8))..., Device: $deviceId"
                
                if (-not $apiKey) {
                    $errorResponse = @{
                        success = $false
                        timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                        error = "API Key is required for MyGeotab authentication"
                    } | ConvertTo-Json
                    
                    $response.StatusCode = 400
                    $response.ContentType = "application/json"
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($errorResponse)
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                elseif (-not $deviceId -or -not $properties) {
                    $errorResponse = @{
                        success = $false
                        timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                        error = "Missing required parameters: deviceId, properties"
                    } | ConvertTo-Json
                    
                    $response.StatusCode = 400
                    $response.ContentType = "application/json"
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($errorResponse)
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                else {
                    # Call the update device properties script
                    Write-Host "Executing device property update..."
                    $updateResult = & ./update-device-properties.ps1 -ApiKey $apiKey -DeviceId $deviceId -Properties $properties
                    
                    $response.StatusCode = 200
                    $response.ContentType = "application/json"
                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($updateResult)
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                }
            }
            catch {
                $errorResponse = @{
                    success = $false
                    timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                    error = "Error processing update request: $($_.Exception.Message)"
                } | ConvertTo-Json
                
                $response.StatusCode = 500
                $response.ContentType = "application/json"
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($errorResponse)
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            }
        }
        else {
            # 404 Not Found
            $notFoundResponse = @{
                error = "Endpoint not found"
                path = $path
                method = $method
                timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            } | ConvertTo-Json
            
            $response.StatusCode = 404
            $response.ContentType = "application/json"
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($notFoundResponse)
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
        }
        
        $response.Close()
    }
    catch {
        Write-Host "Error handling request: $($_.Exception.Message)"
        try {
            $response.StatusCode = 500
            $response.Close()
        }
        catch {
            # Ignore errors when closing response
        }
    }
}