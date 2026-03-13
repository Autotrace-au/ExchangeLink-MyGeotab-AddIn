<#
.SYNOPSIS
Creates or updates an Equipment mailbox (e.g., vehicle/trailer) for booking via Outlook/Teams.

.DESCRIPTION
- Connects to Exchange Online using app-only certificate-based authentication only.
- Update-only: will NOT create a mailbox; skips if not found.
- Sets timezone, language, and auto-accept rules.
- Enforces Primary SMTP = serial@domain and Alias = serial.
- Updates VIN/reg/category/policy in CustomAttributes.
- Grants Fleet Manager access (optional).
- Keeps mailbox visible in GAL and sets default calendar visibility.
- Idempotent: safe to rerun anytime.
#>

param(
  [Parameter(Mandatory=$false)][object]$WebhookData,
  [Parameter(Mandatory=$false)][string]$PrimarySmtpAddress,   # e.g. 2022racetrailersolar@garageofawesome.com.au
  [Parameter(Mandatory=$false)][string]$Alias,                # e.g. 2022racetrailersolar
  [Parameter(Mandatory=$false)][string]$DisplayName,          # e.g. "2022 Race Trailer - Solar"
  [Parameter(Mandatory=$false)][string]$VIN,
  [Parameter(Mandatory=$false)][string]$LicensePlate,
  [Parameter(Mandatory=$false)][string]$FleetManagers = "",
  [Parameter(Mandatory=$false)][string]$Org       = "",
  [Parameter(Mandatory=$false)][string]$TimeZone  = "AUS Eastern Standard Time",
  [Parameter(Mandatory=$false)][string]$Language  = "en-AU",
  # Policy inputs (FS_*). Defaults applied if not supplied
  [Parameter(Mandatory=$false)][string]$Category,
  [Parameter(Mandatory=$false)][ValidateSet('AutoAccept','AutoUpdate','None')][string]$AutomateProcessing = 'AutoAccept',
  [Parameter(Mandatory=$false)][bool]$AllBookInPolicy = $true,
  [Parameter(Mandatory=$false)][string]$BookInPolicyGroups, # semicolon-separated emails
  [Parameter(Mandatory=$false)][string]$RequestInPolicyGroups, # semicolon-separated emails
  [Parameter(Mandatory=$false)][bool]$AllRequestInPolicy = $false,
  [Parameter(Mandatory=$false)][string]$ResourceDelegates, # semicolon-separated emails
  [Parameter(Mandatory=$false)][bool]$AllowConflicts = $false,
  [Parameter(Mandatory=$false)][int]$ConflictPercentageAllowed = 0,
  [Parameter(Mandatory=$false)][int]$MaximumConflictInstances = 0,
  [Parameter(Mandatory=$false)][int]$BookingWindowInDays = 90,
  [Parameter(Mandatory=$false)][int]$MaximumDurationInMinutes = 480,
  [Parameter(Mandatory=$false)][bool]$AllowRecurringMeetings = $false,
  [Parameter(Mandatory=$false)][bool]$AddAdditionalResponse = $false,
  [Parameter(Mandatory=$false)][string]$AdditionalResponse,
  [Parameter(Mandatory=$false)][bool]$DeleteSubject = $false,
  [Parameter(Mandatory=$false)][bool]$DeleteComments = $false,
  [Parameter(Mandatory=$false)][bool]$RemovePrivateProperty = $true,
  [Parameter(Mandatory=$false)][string]$WorkingHoursStartTime, # e.g. 08:00:00
  [Parameter(Mandatory=$false)][string]$WorkingHoursEndTime,   # e.g. 17:00:00
  [Parameter(Mandatory=$false)][string]$WorkingHoursTimeZone,  # falls back to $TimeZone if not supplied
  [Parameter(Mandatory=$false)][string[]]$WorkDays = @('Monday','Tuesday','Wednesday','Thursday','Friday'),
  [Parameter(Mandatory=$false)][string]$PolicyId,
  [Parameter(Mandatory=$false)][string]$PolicyVersion = '1'

)

$ErrorActionPreference = 'Stop'

# Enforce webhook-only invocation
$invokedByWebhook = $false
if ($WebhookData) {
  $invokedByWebhook = ($WebhookData.PSObject.Properties.Name -contains 'WebhookName') -and -not [string]::IsNullOrWhiteSpace($WebhookData.WebhookName)
}
if (-not $invokedByWebhook) {
  throw "This runbook can only be invoked via Azure Automation Webhook."
}


# If invoked via webhook, parse body and override parameters (with type normalisation)
if ($WebhookData -and $WebhookData.RequestBody) {
  try {
    $body = $WebhookData.RequestBody
    if ($body -isnot [string]) { $body = $body | ConvertTo-Json -Depth 10 }
    $payload = $body | ConvertFrom-Json

    $keys = @(
      'PrimarySmtpAddress','Alias','DisplayName','VIN','LicensePlate','Category',
      'AutomateProcessing','AllBookInPolicy','BookInPolicyGroups','AllRequestInPolicy','RequestInPolicyGroups',
      'ResourceDelegates','AllowConflicts','ConflictPercentageAllowed','MaximumConflictInstances',
      'BookingWindowInDays','MaximumDurationInMinutes','AllowRecurringMeetings',
      'AddAdditionalResponse','AdditionalResponse','DeleteSubject','DeleteComments','RemovePrivateProperty',
      'WorkingHoursStartTime','WorkingHoursEndTime','WorkingHoursTimeZone','PolicyId','PolicyVersion'
    )

    $boolKeys = @('AllBookInPolicy','AllRequestInPolicy','AllowConflicts','AllowRecurringMeetings',
                  'AddAdditionalResponse','DeleteSubject','DeleteComments','RemovePrivateProperty')
    $intKeys  = @('ConflictPercentageAllowed','MaximumConflictInstances','BookingWindowInDays','MaximumDurationInMinutes')

    foreach ($k in $keys) {
      if ($payload.PSObject.Properties.Name -contains $k) {
        $val = $payload.$k
        if ($null -eq $val) { continue }
        # Normalise empty strings to $null
        if ($val -is [string] -and [string]::IsNullOrWhiteSpace($val)) { continue }

        # Convert booleans passed as strings ("true"/"false" or "1"/"0")
        if ($boolKeys -contains $k) {
          if ($val -is [string]) {
            $s = $val.Trim().ToLowerInvariant()
            if ($s -eq 'true' -or $s -eq '1') { $val = $true }
            elseif ($s -eq 'false' -or $s -eq '0') { $val = $false }
          }
          $val = [bool]$val
        }
        elseif ($intKeys -contains $k) {
          if ($val -is [string]) { $val = $val.Trim() }
          if ($val -ne '') { $val = [int]$val }
        }

        Set-Variable -Name $k -Value $val -Scope Local
      }
    }
  } catch {
    Write-Warning "Failed to parse WebhookData.RequestBody: $($_.Exception.Message)"
  }
}

# Validate required fields
if ([string]::IsNullOrWhiteSpace($PrimarySmtpAddress) -or -not ($PrimarySmtpAddress -match '.+@.+')) { throw "PrimarySmtpAddress is required and must be a full address" }
if ([string]::IsNullOrWhiteSpace($Alias)) { throw "Alias is required" }
if ([string]::IsNullOrWhiteSpace($DisplayName)) { throw "DisplayName is required" }

Write-Output "Starting equipment mailbox process for $DisplayName ($PrimarySmtpAddress)..."

# 1 Connect to Exchange Online using App Registration + Certificate (app-only)
Import-Module ExchangeOnlineManagement -ErrorAction Stop
# Derive organisation (tenant domain) from PrimarySmtpAddress if not provided
$orgDomain = $Org
if ([string]::IsNullOrWhiteSpace($orgDomain) -and $PrimarySmtpAddress -and ($PrimarySmtpAddress -match '.+@.+')) {
  $orgDomain = ($PrimarySmtpAddress -split '@')[1]
}
if ([string]::IsNullOrWhiteSpace($orgDomain)) { throw "Org (tenant domain) is required. Provide -Org or include a domain in PrimarySmtpAddress." }
# Retrieve Automation assets: AppId and Certificate
$appId = Get-AutomationVariable -Name 'EXO_AppId'
$cert  = Get-AutomationCertificate -Name 'EXO-AppCert'
if ([string]::IsNullOrWhiteSpace($appId) -or -not $cert) { throw "Missing automation assets. Ensure Variable 'EXO_AppId' and Certificate 'EXO-AppCert' exist." }
# Ensure certificate is in CurrentUser\My store for EXO module
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store "My","CurrentUser"
$store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
try { $store.Add($cert) } finally { $store.Close() }
# Connect using certificate thumbprint
Connect-ExchangeOnline -AppId $appId -CertificateThumbprint $cert.Thumbprint -Organization $orgDomain -ShowBanner:$false

# Helper: test if a cmdlet exists in this session (RPS cmdlets aren't available in app-only)
function Test-Cmdlet { param([string]$Name) return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue) }


# 2 Check if mailbox exists (by SMTP or alias)
$mbx = $null
if (Test-Cmdlet 'Get-Mailbox') {
  $mbx = Get-Mailbox -Identity $PrimarySmtpAddress -ErrorAction SilentlyContinue
  if (-not $mbx) { $mbx = Get-Mailbox -Identity $Alias -ErrorAction SilentlyContinue }
} else {
  $mbx = Get-EXOMailbox -Identity $PrimarySmtpAddress -ErrorAction SilentlyContinue
  if (-not $mbx) { $mbx = Get-EXOMailbox -Identity $Alias -ErrorAction SilentlyContinue }
}

# 3️ Update-only mode: creation is disabled (mailboxes are pre-created per device serial)
if (-not $mbx) {
  Write-Warning "Mailbox not found: $PrimarySmtpAddress (alias: $Alias). Creation is disabled; skipping update."
  Write-Output "No changes applied."
  Disconnect-ExchangeOnline -Confirm:$false
  return
} else {
  Write-Output "Existing mailbox found: $($mbx.PrimarySmtpAddress)"
}


# 6 Configure calendar processing per policy
# Parse semicolon-separated lists
$bookIn = @()
if ($BookInPolicyGroups) { $bookIn = ($BookInPolicyGroups -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
# 5 Identity and directory properties (ensure visibility, display name, alias, primary SMTP)
Set-Mailbox -Identity $mbx.Identity -HiddenFromAddressListsEnabled:$false

# Update DisplayName and Alias if provided
if ($DisplayName) { Set-Mailbox -Identity $mbx.Identity -DisplayName $DisplayName }
if ($Alias) {
  if ($mbx.Alias -ne $Alias) { Set-Mailbox -Identity $mbx.Identity -Alias $Alias }
}

# Enforce primary SMTP address from payload (serial@domain)
if ($PrimarySmtpAddress -and ($mbx.PrimarySmtpAddress -ne $PrimarySmtpAddress)) {
  Set-Mailbox -Identity $mbx.Identity -PrimarySmtpAddress $PrimarySmtpAddress
}

# 6 Regional settings (AU defaults)
Set-MailboxRegionalConfiguration -Identity $mbx.Identity -TimeZone $TimeZone -Language $Language

$requestIn = @()
if ($RequestInPolicyGroups) { $requestIn = ($RequestInPolicyGroups -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
$delegates = @()
if ($ResourceDelegates) { $delegates = ($ResourceDelegates -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ } }

# Base calendar processing settings
Set-CalendarProcessing -Identity $mbx.Identity `
  -AutomateProcessing $AutomateProcessing `
  -AllBookInPolicy:$AllBookInPolicy `
  -AllRequestInPolicy:$AllRequestInPolicy `
  -AllowConflicts:$AllowConflicts `
  -ConflictPercentageAllowed $ConflictPercentageAllowed `
  -MaximumConflictInstances $MaximumConflictInstances `
  -BookingWindowInDays $BookingWindowInDays `
  -MaximumDurationInMinutes $MaximumDurationInMinutes `
  -AllowRecurringMeetings:$AllowRecurringMeetings `
  -AddAdditionalResponse:$AddAdditionalResponse `
  -DeleteComments:$DeleteComments `
  -DeleteSubject:$DeleteSubject `
  -RemovePrivateProperty:$RemovePrivateProperty `
  -AddOrganizerToSubject:$false `
  -EnforceCapacity:$true `
  -EnforceSchedulingHorizon:$true

if ($AddAdditionalResponse -and $AdditionalResponse) {
  Set-CalendarProcessing -Identity $mbx.Identity -AdditionalResponse $AdditionalResponse
}
if ($bookIn.Count -gt 0) {
  Set-CalendarProcessing -Identity $mbx.Identity -BookInPolicy $bookIn
}
if ($requestIn.Count -gt 0) {
  Set-CalendarProcessing -Identity $mbx.Identity -RequestInPolicy $requestIn
}
if ($delegates.Count -gt 0) {
  Set-CalendarProcessing -Identity $mbx.Identity -ResourceDelegates $delegates
}

# 7 Working hours configuration (optional)
$calCfg = @{ Identity = $mbx.Identity }
if ($WorkingHoursStartTime) { $calCfg.WorkingHoursStartTime = $WorkingHoursStartTime } else { $calCfg.WorkingHoursStartTime = '09:00:00' }
if ($WorkingHoursEndTime)   { $calCfg.WorkingHoursEndTime   = $WorkingHoursEndTime }   else { $calCfg.WorkingHoursEndTime = '17:00:00' }
if ($WorkingHoursTimeZone)  { $calCfg.WorkingHoursTimeZone  = $WorkingHoursTimeZone }  else { $calCfg.WorkingHoursTimeZone = $TimeZone }
if ($WorkDays) { $calCfg.WorkDays = $WorkDays }
Set-MailboxCalendarConfiguration @calCfg

# 8 Update custom attributes (VIN / Rego / Category / Policy)
if ($VIN -or $LicensePlate -or $Category -or $PolicyId -or $PolicyVersion) {
  Write-Output "Applying mailbox metadata (VIN/Rego/Category/Policy)..."
  Set-Mailbox -Identity $mbx.Identity `
    -CustomAttribute1 $VIN `
    -CustomAttribute2 $LicensePlate `
    -CustomAttribute3 $Category `
    -CustomAttribute4 $PolicyId `
    -CustomAttribute5 $PolicyVersion
}

# 8 Ensure Fleet Managers have calendar access (optional)
if ($FleetManagers) {
  try {
    $calendarPath = "$($mbx.PrimarySmtpAddress):\Calendar"
    $perm = Get-MailboxFolderPermission -Identity $calendarPath -User $FleetManagers -ErrorAction SilentlyContinue
    if (-not $perm) {
      Add-MailboxFolderPermission -Identity $calendarPath -User $FleetManagers -AccessRights Editor
      Write-Output "Granted calendar Editor rights to $FleetManagers"
    } else {
      Write-Output "Fleet Managers already have access."
    }
  } catch {
    Write-Warning "Could not update calendar permissions: $($_.Exception.Message)"
  }
}

# 9 Ensure default calendar visibility is AvailabilityOnly
try {
  $calendarPath = "$($mbx.PrimarySmtpAddress):\Calendar"
  $defaultPerm = Get-MailboxFolderPermission -Identity $calendarPath -User Default -ErrorAction SilentlyContinue
  if ($defaultPerm) {
    if ($defaultPerm.AccessRights -ne 'AvailabilityOnly') {
      Set-MailboxFolderPermission -Identity $calendarPath -User Default -AccessRights AvailabilityOnly -Confirm:$false
      Write-Output "Set Default calendar permission to AvailabilityOnly"
    } else {
      Write-Output "Default calendar permission already AvailabilityOnly."
    }
  } else {
    # If no explicit Default entry, add one
    Add-MailboxFolderPermission -Identity $calendarPath -User Default -AccessRights AvailabilityOnly -Confirm:$false
    Write-Output "Added Default calendar permission: AvailabilityOnly"
  }
} catch {
  Write-Warning "Could not ensure Default calendar permission: $($_.Exception.Message)"
}

Write-Output "Done. Equipment mailbox ready for booking: $($mbx.PrimarySmtpAddress)"
Disconnect-ExchangeOnline -Confirm:$false