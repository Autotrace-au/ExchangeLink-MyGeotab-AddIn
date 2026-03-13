# Production MyGeotab to Exchange Calendar Sync
# This script implements the full production functionality for syncing MyGeotab devices
# to Exchange Online equipment mailboxes with real calendar processing.

param(
    [string]$ApiKey,
    [int]$MaxDevices = 0
)

# Production configuration
$KEY_VAULT_URL = $env:KEY_VAULT_URL
$ENTRA_CLIENT_ID = $env:ENTRA_CLIENT_ID
$ENTRA_TENANT_ID = $env:ENTRA_TENANT_ID

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

function Get-KeyVaultSecret {
    param([string]$SecretName)
    
    try {
        Write-Log "Retrieving secret: $SecretName"
        
        # Ensure Azure CLI is authenticated with managed identity
        $null = az login --identity 2>$null
        
        # Use Azure CLI to get the secret (works with managed identity)
        $result = az keyvault secret show --vault-name "fleetbridge-vault" --name $SecretName --query "value" -o tsv 2>$null
        
        if ($LASTEXITCODE -eq 0 -and $result) {
            Write-Log "Successfully retrieved secret: $SecretName"
            return $result.Trim()
        } else {
            Write-Log "Failed to retrieve secret: $SecretName" "ERROR"
            return $null
        }
    } catch {
        Write-Log "Exception retrieving secret ${SecretName}: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

function Get-MyGeotabCredentials {
    param([string]$ApiKey)
    
    Write-Log "Getting MyGeotab credentials for API key: $(if ($ApiKey) { $ApiKey.Substring(0,[Math]::Min(8,$ApiKey.Length)) } else { 'null' })..."
    
    try {
        $database = Get-KeyVaultSecret "client-$ApiKey-database"
        $username = Get-KeyVaultSecret "client-$ApiKey-username"
        $password = Get-KeyVaultSecret "client-$ApiKey-password"
        $domain = Get-KeyVaultSecret "client-$ApiKey-equipment-domain"
        
        if ($database -and $username -and $password -and $domain) {
            Write-Log "Successfully retrieved MyGeotab credentials"
            return @{
                Database = $database
                Username = $username
                Password = $password
                EquipmentDomain = $domain
            }
        } else {
            Write-Log "Missing MyGeotab credentials in Key Vault" "ERROR"
            return $null
        }
    } catch {
        Write-Log "Error retrieving MyGeotab credentials: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

function Get-MyGeotabDevices {
    param(
        [string]$Database,
        [string]$Username,
        [string]$Password,
        [int]$MaxDevices = 0
    )
    
    Write-Log "Connecting to MyGeotab database: $Database"
    
    try {
        # Install MyGeotab Python module if not available
        $pythonPath = (Get-Command python3 -ErrorAction SilentlyContinue)?.Source
        if (-not $pythonPath) {
            $pythonPath = (Get-Command python -ErrorAction SilentlyContinue)?.Source
        }
        
        if (-not $pythonPath) {
            Write-Log "Python not found. Installing..." "WARNING"
            # Install Python if needed
            apt-get update -qq
            apt-get install -y python3 python3-pip
            $pythonPath = "python3"
        }
        
        # Install mygeotab if not available
        & $pythonPath -c "import mygeotab" 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Installing MyGeotab Python library..."
            & $pythonPath -m pip install mygeotab --quiet
        }
        
        # Create Python script to fetch devices
        $pythonScript = @"
import json
import sys
from mygeotab import API

try:
    # Connect to MyGeotab
    api = API(username='$Username', password='$Password', database='$Database')
    api.authenticate()
    
    # Fetch devices
    devices_raw = api.get('Device')
    
    # Fetch property catalog for normalization
    properties_catalog = api.get('Property')
    prop_name_map = {p.get('id'): p.get('name') for p in properties_catalog if p.get('id') and p.get('name')}
    
    # Normalize devices
    devices = []
    for d in devices_raw:
        device_normalized = {
            'Id': d.get('id'),
            'Name': d.get('name'),
            'SerialNumber': d.get('serialNumber'),
            'VIN': d.get('vehicleIdentificationNumber'),
            'LicensePlate': d.get('licensePlate'),
            'StateOrProvince': d.get('state'),
            'AssetType': d.get('deviceType'),
            'TimeZone': d.get('timeZoneId'),
            'Bookable': False,
            'BookingWindowInDays': 90,
            'MaximumDurationInMinutes': 1440,
            'MailboxLanguage': 'en-AU',
            'AllowConflicts': False,
            'RecurringAllowed': True,
            'Approvers': [],
            'FleetManagers': []
        }
        
        # Extract custom properties
        custom_props = d.get('customProperties', [])
        for cp in custom_props:
            prop_id = cp.get('property', {}).get('id')
            prop_name = prop_name_map.get(prop_id, '')
            prop_value = cp.get('value')
            
            if prop_name == 'Enable Equipment Booking':
                device_normalized['Bookable'] = str(prop_value).lower() in ['true', '1', 'on', 'yes']
            elif prop_name == 'Allow Recurring Bookings':
                device_normalized['RecurringAllowed'] = str(prop_value).lower() in ['true', '1', 'on', 'yes']
            elif prop_name == 'Booking Approvers':
                device_normalized['Approvers'] = prop_value.split(',') if isinstance(prop_value, str) else []
            elif prop_name == 'Fleet Managers':
                device_normalized['FleetManagers'] = prop_value.split(',') if isinstance(prop_value, str) else []
            elif prop_name == 'Allow Double Booking':
                device_normalized['AllowConflicts'] = str(prop_value).lower() in ['true', '1', 'on', 'yes']
            elif prop_name == 'Booking Window (Days)':
                device_normalized['BookingWindowInDays'] = int(prop_value) if prop_value else 90
            elif prop_name == 'Maximum Booking Duration (Hours)':
                device_normalized['MaximumDurationInMinutes'] = int(prop_value) * 60 if prop_value else 1440
            elif prop_name == 'Mailbox Language':
                device_normalized['MailboxLanguage'] = prop_value or 'en-AU'
        
        # Only include devices with serial numbers
        if device_normalized.get('SerialNumber'):
            devices.append(device_normalized)
    
    # Output as JSON
    print(json.dumps(devices, indent=2))
    
except Exception as e:
    print(f"ERROR: {str(e)}", file=sys.stderr)
    sys.exit(1)
"@
        
        # Write Python script to temporary file
        $tempPyFile = "/tmp/fetch_devices.py"
        $pythonScript | Out-File -FilePath $tempPyFile -Encoding UTF8
        
        # Execute Python script
        Write-Log "Fetching devices from MyGeotab..."
        $devicesJson = & $pythonPath $tempPyFile
        
        if ($LASTEXITCODE -eq 0) {
            $devices = $devicesJson | ConvertFrom-Json
            Write-Log "Retrieved $($devices.Count) devices from MyGeotab"
            
            # Apply device limit if specified
            if ($MaxDevices -gt 0 -and $devices.Count -gt $MaxDevices) {
                $devices = $devices[0..($MaxDevices-1)]
                Write-Log "Limited to $MaxDevices devices for processing"
            }
            
            return $devices
        } else {
            Write-Log "Failed to fetch devices from MyGeotab" "ERROR"
            return @()
        }
        
    } catch {
        Write-Log "Error fetching MyGeotab devices: $($_.Exception.Message)" "ERROR"
        return @()
    } finally {
        # Clean up temporary file
        if (Test-Path $tempPyFile) {
            Remove-Item $tempPyFile -Force
        }
    }
}

function Connect-FleetSyncExchangeOnline {
    param([string]$TenantId, [string]$ClientId, [string]$EquipmentDomain)
    
    Write-Log "Connecting to Exchange Online with certificate authentication..."
    
    try {
        # Use the equipment domain directly as the organization domain
        # The equipment domain in Key Vault is already the base domain (e.g., "garageofawesome.com.au")
        $organizationDomain = $EquipmentDomain
        
        Write-Log "Equipment domain from Key Vault: $EquipmentDomain"
        Write-Log "Using organization domain: $organizationDomain"
        
        # Get certificate from Key Vault
        $certName = "ExchangeOnline-PowerShell"
        Write-Log "Retrieving certificate: $certName"
        
        # Get certificate data from Key Vault as base64 encoded PFX
        Write-Log "Downloading certificate from Key Vault..."
        $certData = az keyvault secret show --vault-name "fleetbridge-vault" --name $certName --query "value" -o tsv 2>$null
        
        if ($LASTEXITCODE -ne 0 -or -not $certData) {
            Write-Log "Failed to retrieve certificate from Key Vault" "ERROR"
            return $false
        }
        
        # Write certificate to temporary file
        $tempCertFile = "/tmp/exchange_cert.pfx"
        Write-Log "Writing certificate to temporary file: $tempCertFile"
        
        # Decode base64 and write binary data (PowerShell 7 compatible)
        $certBytes = [System.Convert]::FromBase64String($certData)
        [System.IO.File]::WriteAllBytes($tempCertFile, $certBytes)
        
        # Verify certificate thumbprint for debugging
        try {
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($tempCertFile, $null, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
            Write-Log "Certificate thumbprint: $($cert.Thumbprint)"
            Write-Log "Certificate subject: $($cert.Subject)"
            Write-Log "Certificate has private key: $($cert.HasPrivateKey)"
        } catch {
            Write-Log "Warning: Could not verify certificate details: $($_.Exception.Message)" "WARNING"
        }
        
        # Connect to Exchange Online using certificate
        Write-Log "Connecting to Exchange Online with App ID: $ClientId"
        Write-Log "Organization: $organizationDomain"
        
        if (-not $ClientId -or -not $organizationDomain) {
            Write-Log "Missing required parameters: ClientId=$ClientId, OrganizationDomain=$organizationDomain" "ERROR"
            return $false
        }
        
        # Import the ExchangeOnlineManagement module if not already loaded
        Write-Log "Importing ExchangeOnlineManagement module..."
        Import-Module ExchangeOnlineManagement -Force -Global
        
        # Load certificate from file to get thumbprint
        Write-Log "Loading certificate from file..."
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($tempCertFile, $null, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet)
        $thumbprint = $cert.Thumbprint
        Write-Log "Certificate loaded with thumbprint: $thumbprint"
        
        # Import certificate to current user store so Connect-ExchangeOnline can find it
        Write-Log "Importing certificate to current user certificate store..."
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("My", "CurrentUser")
        $store.Open("ReadWrite")
        $store.Add($cert)
        $store.Close()
        Write-Log "Certificate imported to store"
        
        # Connect using certificate thumbprint for app-only authentication
        Write-Log "Executing Connect-ExchangeOnline with certificate thumbprint..."
        Write-Log "Debug - Thumbprint: '$thumbprint', AppId: '$ClientId', Organization: '$organizationDomain'"
        
        if ([string]::IsNullOrWhiteSpace($thumbprint)) {
            Write-Log "ERROR: Thumbprint is empty!" "ERROR"
            return $false
        }
        if ([string]::IsNullOrWhiteSpace($ClientId)) {
            Write-Log "ERROR: ClientId is empty!" "ERROR"
            return $false
        }
        if ([string]::IsNullOrWhiteSpace($organizationDomain)) {
            Write-Log "ERROR: Organization domain is empty!" "ERROR"
            return $false
        }
        
        Connect-ExchangeOnline -Certificate $cert -AppId $ClientId -Organization $organizationDomain -ShowBanner:$false -ErrorAction Stop
        
        # Force import all Exchange Online cmdlets into global scope
        Write-Log "Importing Exchange Online cmdlets to global scope..."
        $exchangeSession = Get-PSSession | Where-Object { $_.ConfigurationName -eq "Microsoft.Exchange" -and $_.State -eq "Opened" } | Select-Object -First 1
        if ($exchangeSession) {
            Import-PSSession $exchangeSession -AllowClobber -DisableNameChecking -Force -Global
            Write-Log "Exchange Online session imported to global scope"
        } else {
            Write-Log "No Exchange Online session found to import" "WARNING"
        }
        
        # Verify connection by testing commands
        Write-Log "Verifying Exchange Online connection and cmdlets..."
        try {
            $testResult = Get-OrganizationConfig -ErrorAction SilentlyContinue
            $mailboxTest = Get-Command Get-Mailbox -ErrorAction SilentlyContinue
            $calendarTest = Get-Command Set-CalendarProcessing -ErrorAction SilentlyContinue
            
            if ($testResult -and $mailboxTest -and $calendarTest) {
                Write-Log "Exchange Online connection and cmdlets verified successfully"
                Write-Log "Available cmdlets: Get-Mailbox, Set-CalendarProcessing"
            } else {
                Write-Log "Exchange Online cmdlet verification failed" "ERROR"
                Write-Log "Get-OrganizationConfig: $($testResult -ne $null)"
                Write-Log "Get-Mailbox available: $($mailboxTest -ne $null)"
                Write-Log "Set-CalendarProcessing available: $($calendarTest -ne $null)"
                return $false
            }
        } catch {
            Write-Log "Exchange Online verification error: $($_.Exception.Message)" "ERROR"
            return $false
        }
        
        Write-Log "Successfully connected to Exchange Online"
        return $true
        
    } catch {
        Write-Log "Failed to connect to Exchange Online: $($_.Exception.Message)" "ERROR"
        Write-Log "Full error: $($_.Exception)" "ERROR"
        return $false
    } finally {
        # Clean up certificate file
        if (Test-Path $tempCertFile) {
            Remove-Item $tempCertFile -Force -ErrorAction SilentlyContinue
            Write-Log "Cleaned up temporary certificate file"
        }
    }
}

function Set-EquipmentMailboxCalendarProcessing {
    param(
        [object]$Device,
        [string]$EquipmentDomain
    )
    
    $startTime = Get-Date
    $mailboxEmail = "$($Device.SerialNumber)@$EquipmentDomain"
    
    Write-Log "Processing mailbox: $mailboxEmail"
    
    try {
        # Check if mailbox exists
        Write-Log "Checking Exchange Online session status..."
        
        # Verify Exchange Online connection is active
        $exchangeSession = Get-PSSession | Where-Object { $_.ConfigurationName -eq "Microsoft.Exchange" -and $_.State -eq "Opened" }
        if (-not $exchangeSession) {
            Write-Log "No active Exchange Online session found" "WARNING"
            # Try to get available commands to debug
            $availableCommands = Get-Command *Mailbox*, *Calendar* -ErrorAction SilentlyContinue | Select-Object -First 10
            Write-Log "Available mailbox/calendar commands: $($availableCommands.Name -join ', ')" "WARNING"
        } else {
            Write-Log "Exchange Online session active: $($exchangeSession.ComputerName)"
        }
        
        $mailbox = Get-EXOMailbox -Identity $mailboxEmail -ErrorAction SilentlyContinue
        if (-not $mailbox) {
            Write-Log "Mailbox not found: $mailboxEmail" "WARNING"
            return @{
                deviceId = $Device.Id
                deviceName = $Device.Name
                serialNumber = $Device.SerialNumber
                mailboxEmail = $mailboxEmail
                status = "skipped"
                action = "mailbox_not_found"
                message = "Mailbox does not exist - must be pre-created"
                timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                processingTime = "0ms"
            }
        }
        
        # Configure calendar processing settings
        $calendarSettings = @{
            AutomateProcessing = "AutoAccept"
            BookingWindowInDays = $Device.BookingWindowInDays
            MaximumDurationInMinutes = $Device.MaximumDurationInMinutes
            AllowConflicts = $Device.AllowConflicts
            AllowRecurringMeetings = $Device.RecurringAllowed
            ProcessExternalMeetingMessages = $true
            DeleteComments = $false
            DeleteSubject = $false
            RemovePrivateProperty = $false
        }
        
        # Add resource delegates (approvers/fleet managers)
        $allDelegates = @()
        $allDelegates += $Device.Approvers
        $allDelegates += $Device.FleetManagers
        $allDelegates = $allDelegates | Where-Object { $_ -and $_.Trim() } | Select-Object -Unique
        
        if ($allDelegates.Count -gt 0) {
            $calendarSettings.ResourceDelegates = $allDelegates
        }
        
        # Apply calendar processing settings
        Write-Log "Applying calendar processing settings for $mailboxEmail"
        
        # Try Set-CalendarProcessing first, then fallback to Set-EXOCalendarProcessing if available
        try {
            Set-CalendarProcessing -Identity $mailboxEmail @calendarSettings -ErrorAction Stop
            Write-Log "Calendar processing configured successfully with Set-CalendarProcessing"
        } catch {
            Write-Log "Set-CalendarProcessing failed: $($_.Exception.Message)" "WARNING"
            try {
                # Check if Set-EXOCalendarProcessing exists
                $exoCommand = Get-Command Set-EXOCalendarProcessing -ErrorAction SilentlyContinue
                if ($exoCommand) {
                    Set-EXOCalendarProcessing -Identity $mailboxEmail @calendarSettings -ErrorAction Stop
                    Write-Log "Calendar processing configured successfully with Set-EXOCalendarProcessing"
                } else {
                    throw "Neither Set-CalendarProcessing nor Set-EXOCalendarProcessing are available"
                }
            } catch {
                Write-Log "Both calendar processing cmdlets failed: $($_.Exception.Message)" "ERROR"
                throw $_
            }
        }
        
        # Set mailbox regional settings
        Write-Log "Setting regional configuration for $mailboxEmail"
        try {
            Set-MailboxRegionalConfiguration -Identity $mailboxEmail -Language $Device.MailboxLanguage -TimeZone "AUS Eastern Standard Time" -ErrorAction Stop
            Write-Log "Regional configuration set successfully"
        } catch {
            Write-Log "Failed to set regional configuration: $($_.Exception.Message)" "WARNING"
            # Try EXO version if available
            try {
                $exoRegionalCmd = Get-Command Set-EXOMailboxRegionalConfiguration -ErrorAction SilentlyContinue
                if ($exoRegionalCmd) {
                    Set-EXOMailboxRegionalConfiguration -Identity $mailboxEmail -Language $Device.MailboxLanguage -TimeZone "AUS Eastern Standard Time" -ErrorAction Stop
                    Write-Log "Regional configuration set successfully with EXO cmdlet"
                } else {
                    Write-Log "Regional configuration skipped - cmdlet not available" "WARNING"
                }
            } catch {
                Write-Log "EXO regional configuration also failed: $($_.Exception.Message)" "WARNING"
            }
        }
        
        $processingTime = [math]::Round(((Get-Date) - $startTime).TotalMilliseconds)
        Write-Log "Successfully processed $mailboxEmail in ${processingTime}ms"
        
        return @{
            deviceId = $Device.Id
            deviceName = $Device.Name
            serialNumber = $Device.SerialNumber
            mailboxEmail = $mailboxEmail
            status = "success"
            action = "calendar_processing_configured"
            message = "Calendar processing configured successfully"
            timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            processingTime = "${processingTime}ms"
            details = @{
                bookingEnabled = $Device.Bookable
                autoAccept = $true
                allowConflicts = $Device.AllowConflicts
                bookingWindowDays = $Device.BookingWindowInDays
                maxDurationMinutes = $Device.MaximumDurationInMinutes
                language = $Device.MailboxLanguage
                delegates = $allDelegates
            }
        }
        
    } catch {
        $processingTime = [math]::Round(((Get-Date) - $startTime).TotalMilliseconds)
        $errorMessage = $_.Exception.Message
        Write-Log "Failed to process $mailboxEmail`: $errorMessage" "ERROR"
        
        return @{
            deviceId = $Device.Id
            deviceName = $Device.Name
            serialNumber = $Device.SerialNumber
            mailboxEmail = $mailboxEmail
            status = "failed"
            action = "calendar_processing_error"
            message = "Error configuring calendar processing: $errorMessage"
            timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            processingTime = "${processingTime}ms"
            error = $errorMessage
        }
    }
}

function Main {
    param([string]$ApiKey, [int]$MaxDevices = 0)
    
    $startTime = Get-Date
    Write-Log "=== Starting Production MyGeotab to Exchange Sync ==="
    Write-Log "API Key: $(if ($ApiKey) { $ApiKey.Substring(0,[Math]::Min(8,$ApiKey.Length)) } else { 'null' })..., Max Devices: $MaxDevices"
    
    # Validate parameters
    if (-not $ApiKey) {
        Write-Log "API Key is required" "ERROR"
        return @{
            success = $false
            error = "API Key is required"
            processed = 0
            successful = 0
            failed = 0
            results = @()
        }
    }
    
    # Get MyGeotab credentials
    $credentials = Get-MyGeotabCredentials -ApiKey $ApiKey
    if (-not $credentials) {
        return @{
            success = $false
            error = "Failed to retrieve MyGeotab credentials from Key Vault"
            processed = 0
            successful = 0
            failed = 0
            results = @()
        }
    }
    
    # Fetch devices from MyGeotab
    $devices = Get-MyGeotabDevices -Database $credentials.Database -Username $credentials.Username -Password $credentials.Password -MaxDevices $MaxDevices
    if (-not $devices -or $devices.Count -eq 0) {
        return @{
            success = $false
            error = "No devices found in MyGeotab or failed to fetch devices"
            processed = 0
            successful = 0
            failed = 0
            results = @()
        }
    }
    
    $deviceCount = if ($devices) { $devices.Count } else { 0 }
    Write-Log "Found $deviceCount devices to process"
    Write-Log "Environment variables: CLIENT_ID=$ENTRA_CLIENT_ID, TENANT_ID=$ENTRA_TENANT_ID"
    Write-Log "Equipment domain: $($credentials.EquipmentDomain)"
    
    # For Exchange Online app-only authentication with RBAC, use .onmicrosoft.com domain
    # Extract the base domain and construct the onmicrosoft.com domain
    $baseDomain = $credentials.EquipmentDomain -replace '\..*$', ''
    $exchangeOrgDomain = "$baseDomain.onmicrosoft.com"
    Write-Log "Using Exchange organization domain: $exchangeOrgDomain (derived from equipment domain: $($credentials.EquipmentDomain))"
    
    # Connect to Exchange Online
    $exchangeConnected = Connect-FleetSyncExchangeOnline -TenantId $ENTRA_TENANT_ID -ClientId $ENTRA_CLIENT_ID -EquipmentDomain $exchangeOrgDomain
    if (-not $exchangeConnected) {
        return @{
            success = $false
            error = "Failed to connect to Exchange Online"
            processed = 0
            successful = 0
            failed = 0
            results = @()
        }
    }
    
    # Process each device
    $results = @()
    $successful = 0
    $failed = 0
    
    foreach ($device in $devices) {
        Write-Log "Processing device: $($device.Name) (Serial: $($device.SerialNumber))"
        
        $result = Set-EquipmentMailboxCalendarProcessing -Device $device -EquipmentDomain $credentials.EquipmentDomain
        $results += $result
        
        if ($result.status -eq "success") {
            $successful++
        } else {
            $failed++
        }
    }
    
    # Disconnect from Exchange Online
    try {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "Disconnected from Exchange Online"
    } catch {
        Write-Log "Warning: Could not disconnect from Exchange Online: $($_.Exception.Message)" "WARNING"
    }
    
    $deviceCount = if ($devices) { $devices.Count } else { 0 }
    
    $executionTime = [math]::Round(((Get-Date) - $startTime).TotalMilliseconds)
    Write-Log "=== Sync Complete ==="
    Write-Log "Processed: $deviceCount, Successful: $successful, Failed: $failed"
    Write-Log "Total execution time: ${executionTime}ms"
    
    return @{
        success = $true
        processed = $deviceCount
        successful = $successful
        failed = $failed
        timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        message = "Production sync completed - processed $deviceCount devices from MyGeotab"
        executionTimeMs = $executionTime
        results = $results
        details = @{
            mygeotabDatabase = $credentials.Database
            equipmentDomain = $credentials.EquipmentDomain
            totalDevicesInMyGeotab = $deviceCount
            exchangeConnection = "Certificate-based authentication"
        }
    }
}

# Execute main function with parameters
try {
    $result = Main -ApiKey $ApiKey -MaxDevices $MaxDevices
    return ($result | ConvertTo-Json -Depth 4)
} catch {
    $errorResult = @{
        success = $false
        error = "Script execution error: $($_.Exception.Message)"
        processed = 0
        successful = 0
        failed = 0
        timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        scriptLine = $_.InvocationInfo.ScriptLineNumber
        details = @{
            errorType = $_.Exception.GetType().Name
            stackTrace = $_.ScriptStackTrace
        }
    }
    return ($errorResult | ConvertTo-Json -Depth 4)
}