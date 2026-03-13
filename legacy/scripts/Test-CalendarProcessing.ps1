# Test-CalendarProcessing.ps1
# Test script to verify calendar processing functionality for equipment mailboxes
# Uses the same authentication pattern as the working FleetSync-Orchestrator.ps1

param(
    [Parameter(Mandatory=$true)]
    [string]$MailboxEmail,
    
    [Parameter(Mandatory=$false)]
    [switch]$TestOnly,
    
    [Parameter(Mandatory=$false)]
    [switch]$EnableBooking = $true,
    
    [Parameter(Mandatory=$false)]
    [string[]]$Approvers = @()
)

$ErrorActionPreference = 'Stop'

function Get-Var {
    param([string]$Name,[string]$Fallback=$null)
    try { $v = Get-AutomationVariable -Name $Name -ErrorAction Stop } catch { $v = $null }
    if ([string]::IsNullOrWhiteSpace($v)) { return $Fallback } else { return $v }
}

function Ensure-ExchangeOnline {
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    $appId = Get-Var 'EXO_AppId'
    $cert  = Get-AutomationCertificate -Name 'EXO-AppCert'
    if ([string]::IsNullOrWhiteSpace($appId) -or -not $cert) { 
        throw "Missing EXO_AppId or EXO-AppCert. For testing, set these values manually." 
    }
    
    # Expose for reuse
    $script:EXO_AppId    = $appId
    $script:EXO_CertThumb = $cert.Thumbprint
    
    # Install certificate in current user store
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store "My","CurrentUser"
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try { $store.Add($cert) } finally { $store.Close() }
    
    # Determine organization domain
    $org = if ($MailboxEmail -like '*@*') { 
        ($MailboxEmail.Split('@')[1]) 
    } else { 
        "garageofawesome.com.au"  # Default for testing
    }
    
    Write-Output "Connecting to Exchange Online org: $org"
    Write-Output "Using EXO AppId: $appId"
    
    $exo = @{ 
        AppId=$appId; 
        CertificateThumbprint=$cert.Thumbprint; 
        Organization=$org; 
        ShowBanner=$false 
    }
    Connect-ExchangeOnline @exo
}

function Test-CalendarProcessingSettings {
    param([string]$Identity)
    
    Write-Output "`n=== Current Calendar Processing Settings for $Identity ==="
    try {
        $current = Get-CalendarProcessing -Identity $Identity -ErrorAction Stop
        
        Write-Output "AutomateProcessing: $($current.AutomateProcessing)"
        Write-Output "AllBookInPolicy: $($current.AllBookInPolicy)"
        Write-Output "AllRequestInPolicy: $($current.AllRequestInPolicy)"
        Write-Output "AllowConflicts: $($current.AllowConflicts)"
        Write-Output "BookingWindowInDays: $($current.BookingWindowInDays)"
        Write-Output "MaximumDurationInMinutes: $($current.MaximumDurationInMinutes)"
        Write-Output "AllowRecurringMeetings: $($current.AllowRecurringMeetings)"
        Write-Output "ResourceDelegates: $($current.ResourceDelegates -join ', ')"
        Write-Output "ScheduleOnlyDuringWorkHours: $($current.ScheduleOnlyDuringWorkHours)"
        
        return $current
    } catch {
        Write-Error "Failed to get calendar processing settings: $($_.Exception.Message)"
        return $null
    }
}

function Update-CalendarProcessingSettings {
    param(
        [string]$Identity,
        [bool]$Bookable = $true,
        [string[]]$ResourceDelegates = @(),
        [switch]$TestOnly
    )
    
    Write-Output "`n=== Updating Calendar Processing Settings for $Identity ==="
    
    if ($TestOnly) {
        Write-Output "TEST MODE: Would apply the following settings:"
    }
    
    $params = @{
        Identity = $Identity
    }
    
    if ($Bookable) {
        Write-Output "Setting: Bookable equipment with auto-accept"
        $params += @{
            AutomateProcessing = 'AutoAccept'
            AllBookInPolicy = $true
            AllRequestInPolicy = $false
            AllowConflicts = $false
            ConflictPercentageAllowed = 0
            MaximumConflictInstances = 0
            BookingWindowInDays = 90
            MaximumDurationInMinutes = 1440
            AllowRecurringMeetings = $true
            AddAdditionalResponse = $true
            AdditionalResponse = @"
IMPORTANT: Check the meeting status in your calendar:
- ACCEPTED = Equipment is reserved for you
- DECLINED = Equipment is NOT available - DELETE this calendar entry immediately
- TENTATIVE = Awaiting approval from fleet manager

Always cancel bookings you no longer need so others can use the equipment.
"@
            DeleteComments = $false
            DeleteSubject = $false
            RemovePrivateProperty = $true
            AddOrganizerToSubject = $true
            EnforceCapacity = $true
            EnforceSchedulingHorizon = $true
            ScheduleOnlyDuringWorkHours = $false
        }
        
        # Add delegates if provided
        if ($ResourceDelegates -and $ResourceDelegates.Count -gt 0) {
            Write-Output "Setting approvers/delegates: $($ResourceDelegates -join ', ')"
            $params.ResourceDelegates = $ResourceDelegates
            $params.AllRequestInPolicy = $true
            $params.AllBookInPolicy = $false
        }
    } else {
        Write-Output "Setting: NOT bookable (disabled booking)"
        $params += @{
            AutomateProcessing = 'None'
            AllBookInPolicy = $false
            AllRequestInPolicy = $false
            BookingWindowInDays = 0
        }
    }
    
    if ($TestOnly) {
        Write-Output "TEST MODE: Settings prepared but not applied"
        $params | ConvertTo-Json -Depth 2 | Write-Output
        return $true
    }
    
    try {
        Set-CalendarProcessing @params -ErrorAction Stop
        Write-Output "✓ Successfully updated calendar processing settings"
        return $true
    } catch {
        Write-Error "Failed to update calendar processing settings: $($_.Exception.Message)"
        return $false
    }
}

# MAIN EXECUTION
try {
    Write-Output "Testing Calendar Processing for: $MailboxEmail"
    Write-Output "Enable Booking: $EnableBooking"
    if ($Approvers.Count -gt 0) {
        Write-Output "Approvers: $($Approvers -join ', ')"
    }
    
    # Connect to Exchange Online
    Ensure-ExchangeOnline
    
    # Get current settings
    $currentSettings = Test-CalendarProcessingSettings -Identity $MailboxEmail
    
    if ($currentSettings) {
        # Update settings
        $success = Update-CalendarProcessingSettings -Identity $MailboxEmail -Bookable $EnableBooking -ResourceDelegates $Approvers -TestOnly:$TestOnly
        
        if ($success -and -not $TestOnly) {
            # Verify changes
            Write-Output "`n=== Verifying Changes ==="
            Start-Sleep -Seconds 2
            Test-CalendarProcessingSettings -Identity $MailboxEmail | Out-Null
        }
    }
    
    Write-Output "`n=== Test Completed Successfully ==="
    
} catch {
    Write-Error "Test failed: $($_.Exception.Message)"
    Write-Output $_.ScriptStackTrace
} finally {
    # Cleanup
    try {
        Disconnect-ExchangeOnline -Confirm:$false
    } catch {
        # Ignore disconnect errors
    }
}

<#
.EXAMPLE
# Test mode (no changes)
.\Test-CalendarProcessing.ps1 -MailboxEmail "vehicle123@garageofawesome.com.au" -TestOnly

.EXAMPLE  
# Enable booking with auto-accept
.\Test-CalendarProcessing.ps1 -MailboxEmail "vehicle123@garageofawesome.com.au" -EnableBooking

.EXAMPLE
# Enable booking with approvers
.\Test-CalendarProcessing.ps1 -MailboxEmail "vehicle123@garageofawesome.com.au" -EnableBooking -Approvers @("manager@garageofawesome.com.au", "admin@garageofawesome.com.au")

.EXAMPLE
# Disable booking
.\Test-CalendarProcessing.ps1 -MailboxEmail "vehicle123@garageofawesome.com.au" -EnableBooking:$false
#>