param(
  [Parameter(Mandatory = $false)][string]$PrimarySmtpAddress,
  [Parameter(Mandatory = $false)][string]$Alias,
  [Parameter(Mandatory = $false)][string]$DisplayName,
  [Parameter(Mandatory = $true)][string]$Organization,
  [Parameter(Mandatory = $true)][string]$AppId,
  [Parameter(Mandatory = $true)][string]$CertificatePath,
  [Parameter(Mandatory = $false)][string]$CertificatePassword = '',
  [Parameter(Mandatory = $false)][string]$TimeZone = 'AUS Eastern Standard Time',
  [Parameter(Mandatory = $false)][string]$Language = 'en-AU',
  [Parameter(Mandatory = $false)][string]$AllowConflicts = '0',
  [Parameter(Mandatory = $false)][int]$BookingWindowInDays = 90,
  [Parameter(Mandatory = $false)][int]$MaximumDurationInMinutes = 1440,
  [Parameter(Mandatory = $false)][string]$AllowRecurringMeetings = '1',
  [Parameter(Mandatory = $false)][string]$MakeVisible = '1',
  [Parameter(Mandatory = $false)][string]$FleetManagers = '',
  [Parameter(Mandatory = $false)][string]$Approvers = '',
  [Parameter(Mandatory = $false)][string]$VIN = '',
  [Parameter(Mandatory = $false)][string]$LicensePlate = '',
  [Parameter(Mandatory = $false)][string]$InputJsonPath = ''
)

$ErrorActionPreference = 'Stop'

function To-JsonResult {
  param(
    [bool]$Success,
    [string]$Message,
    [hashtable]$Extra = @{}
  )

  $payload = @{
    success = $Success
    message = $Message
  }

  foreach ($key in $Extra.Keys) {
    $payload[$key] = $Extra[$key]
  }

  $payload | ConvertTo-Json -Depth 10 -Compress
}

function To-Bool {
  param(
    [string]$Value,
    [bool]$Default = $false
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $Default
  }

  switch ($Value.Trim().ToLowerInvariant()) {
    '1' { return $true }
    'true' { return $true }
    'yes' { return $true }
    'on' { return $true }
    '0' { return $false }
    'false' { return $false }
    'no' { return $false }
    'off' { return $false }
    default { return $Default }
  }
}

function To-Hashtable {
  param(
    [Parameter(Mandatory = $true)]$InputObject
  )

  if ($InputObject -is [hashtable]) {
    return $InputObject
  }

  $result = @{}
  foreach ($property in $InputObject.PSObject.Properties) {
    $result[$property.Name] = $property.Value
  }
  return $result
}

function Invoke-MailboxSync {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Item
  )

  $primarySmtpAddress = [string]($Item.primarySmtpAddress ?? '')
  $alias = [string]($Item.alias ?? '')
  $displayName = [string]($Item.displayName ?? '')
  $timeZone = [string]($Item.timeZone ?? $TimeZone)
  $language = [string]($Item.language ?? $Language)
  $allowConflictsValue = To-Bool -Value ([string]($Item.allowConflicts ?? $AllowConflicts)) -Default $false
  $bookingWindowInDaysValue = [int]($Item.bookingWindowInDays ?? $BookingWindowInDays)
  $maximumDurationInMinutesValue = [int]($Item.maximumDurationInMinutes ?? $MaximumDurationInMinutes)
  $allowRecurringMeetingsValue = To-Bool -Value ([string]($Item.allowRecurringMeetings ?? $AllowRecurringMeetings)) -Default $true
  $makeVisibleValue = To-Bool -Value ([string]($Item.makeVisible ?? $MakeVisible)) -Default $true
  $fleetManagersValue = [string]($Item.fleetManagers ?? $FleetManagers)
  $approversValue = [string]($Item.approvers ?? $Approvers)
  $vinValue = [string]($Item.vin ?? $VIN)
  $licensePlateValue = [string]($Item.licensePlate ?? $LicensePlate)
  $deviceId = [string]($Item.deviceId ?? '')
  $serial = [string]($Item.serial ?? '')
  $vehicleName = [string]($Item.vehicleName ?? $displayName)

  try {
    $mailbox = Get-EXOMailbox -Identity $primarySmtpAddress -ErrorAction SilentlyContinue
    if (-not $mailbox) {
      $mailbox = Get-EXOMailbox -Identity $alias -ErrorAction SilentlyContinue
    }

    if (-not $mailbox) {
      return @{
        success = $false
        message = 'Mailbox not found'
        primarySmtpAddress = $primarySmtpAddress
        alias = $alias
        found = $false
        deviceId = $deviceId
        serial = $serial
        vehicleName = $vehicleName
      }
    }

    $wasHidden = $mailbox.HiddenFromAddressListsEnabled
    $mailboxIdentity = $mailbox.UserPrincipalName
    if ([string]::IsNullOrWhiteSpace($mailboxIdentity)) {
      $mailboxIdentity = $mailbox.PrimarySmtpAddress
    }

    $setMailboxParams = @{
      Identity = $mailboxIdentity
    }
    if ($mailbox.DisplayName -ne $displayName) {
      $setMailboxParams.DisplayName = $displayName
    }
    if ($mailbox.Alias -ne $alias) {
      $setMailboxParams.Alias = $alias
    }
    if ([string]$mailbox.PrimarySmtpAddress -ne $primarySmtpAddress) {
      $setMailboxParams.PrimarySmtpAddress = $primarySmtpAddress
    }
    if ($makeVisibleValue -and $wasHidden) {
      $setMailboxParams.HiddenFromAddressListsEnabled = $false
    }
    if (-not [string]::IsNullOrWhiteSpace($vinValue) -or -not [string]::IsNullOrWhiteSpace($licensePlateValue)) {
      $setMailboxParams.CustomAttribute1 = $vinValue
      $setMailboxParams.CustomAttribute2 = $licensePlateValue
    }
    if ($setMailboxParams.Count -gt 1) {
      Set-Mailbox @setMailboxParams
    }

    Set-MailboxRegionalConfiguration -Identity $mailboxIdentity -TimeZone $timeZone -Language $language

    $calParams = @{
      Identity                 = $mailboxIdentity
      AutomateProcessing       = 'AutoAccept'
      AllowConflicts           = $allowConflictsValue
      BookingWindowInDays      = $bookingWindowInDaysValue
      MaximumDurationInMinutes = $maximumDurationInMinutesValue
      AllowRecurringMeetings   = $allowRecurringMeetingsValue
      AllBookInPolicy          = $true
      AllRequestInPolicy       = $false
    }
    Set-CalendarProcessing @calParams

    $approverList = @()
    if (-not [string]::IsNullOrWhiteSpace($approversValue)) {
      $approverList = $approversValue.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    if ($approverList.Count -gt 0) {
      Set-CalendarProcessing -Identity $mailboxIdentity -BookInPolicy $approverList
    }

    $managerList = @()
    if (-not [string]::IsNullOrWhiteSpace($fleetManagersValue)) {
      $managerList = $fleetManagersValue.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }

    foreach ($manager in $managerList) {
      try {
        Add-MailboxFolderPermission `
          -Identity "$($mailbox.PrimarySmtpAddress):\Calendar" `
          -User $manager `
          -AccessRights Editor `
          -ErrorAction Stop | Out-Null
      } catch {
        if ($_.Exception.Message -notmatch 'already') {
          throw
        }
      }
    }

    return @{
      success = $true
      message = 'Mailbox updated'
      found = $true
      primarySmtpAddress = $primarySmtpAddress
      displayName = $displayName
      wasHidden = [bool]$wasHidden
      madeVisible = [bool]($makeVisibleValue -and $wasHidden)
      deviceId = $deviceId
      serial = $serial
      vehicleName = $vehicleName
    }
  } catch {
    return @{
      success = $false
      message = $_.Exception.Message
      found = $false
      primarySmtpAddress = $primarySmtpAddress
      alias = $alias
      deviceId = $deviceId
      serial = $serial
      vehicleName = $vehicleName
    }
  }
}

try {
  Import-Module ExchangeOnlineManagement -ErrorAction Stop

  if ([string]::IsNullOrWhiteSpace($CertificatePassword)) {
    Connect-ExchangeOnline `
      -AppId $AppId `
      -CertificateFilePath $CertificatePath `
      -Organization $Organization `
      -ShowBanner:$false | Out-Null
  } else {
    $securePassword = ConvertTo-SecureString -String $CertificatePassword -AsPlainText -Force
    Connect-ExchangeOnline `
      -AppId $AppId `
      -CertificateFilePath $CertificatePath `
      -CertificatePassword $securePassword `
      -Organization $Organization `
      -ShowBanner:$false | Out-Null
  }

  if (-not [string]::IsNullOrWhiteSpace($InputJsonPath)) {
    $items = Get-Content -Raw -Path $InputJsonPath | ConvertFrom-Json -Depth 10
    $results = @()
    foreach ($item in $items) {
      $results += Invoke-MailboxSync -Item (To-Hashtable -InputObject $item)
    }
    Write-Output (ConvertTo-Json -InputObject @($results) -Depth 10 -Compress)
    exit 0
  }

  $singleItem = @{
    primarySmtpAddress = $PrimarySmtpAddress
    alias = $Alias
    displayName = $DisplayName
    timeZone = $TimeZone
    language = $Language
    allowConflicts = $AllowConflicts
    bookingWindowInDays = $BookingWindowInDays
    maximumDurationInMinutes = $MaximumDurationInMinutes
    allowRecurringMeetings = $AllowRecurringMeetings
    makeVisible = $MakeVisible
    fleetManagers = $FleetManagers
    approvers = $Approvers
    vin = $VIN
    licensePlate = $LicensePlate
  }
  $result = Invoke-MailboxSync -Item $singleItem
  Write-Output ($result | ConvertTo-Json -Depth 10 -Compress)
}
catch {
  Write-Output (To-JsonResult -Success $false -Message $_.Exception.Message -Extra @{
    found = $false
    primarySmtpAddress = $PrimarySmtpAddress
    alias = $Alias
  })
  exit 1
}
finally {
  try {
    Disconnect-ExchangeOnline -Confirm:$false | Out-Null
  } catch {
  }
}
