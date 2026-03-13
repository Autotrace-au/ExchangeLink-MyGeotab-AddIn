param(
  [Parameter(Mandatory = $true)][string]$PrimarySmtpAddress,
  [Parameter(Mandatory = $true)][string]$Alias,
  [Parameter(Mandatory = $true)][string]$DisplayName,
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
  [Parameter(Mandatory = $false)][string]$LicensePlate = ''
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

try {
  Import-Module ExchangeOnlineManagement -ErrorAction Stop

  $allowConflictsValue = To-Bool -Value $AllowConflicts -Default $false
  $allowRecurringMeetingsValue = To-Bool -Value $AllowRecurringMeetings -Default $true
  $makeVisibleValue = To-Bool -Value $MakeVisible -Default $true

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

  $mailbox = Get-EXOMailbox -Identity $PrimarySmtpAddress -ErrorAction SilentlyContinue
  if (-not $mailbox) {
    $mailbox = Get-EXOMailbox -Identity $Alias -ErrorAction SilentlyContinue
  }

  if (-not $mailbox) {
    Write-Output (To-JsonResult -Success $false -Message 'Mailbox not found' -Extra @{
      primarySmtpAddress = $PrimarySmtpAddress
      alias = $Alias
      found = $false
    })
    exit 0
  }

  $wasHidden = $mailbox.HiddenFromAddressListsEnabled
  $mailboxIdentity = $mailbox.UserPrincipalName
  if ([string]::IsNullOrWhiteSpace($mailboxIdentity)) {
    $mailboxIdentity = $mailbox.PrimarySmtpAddress
  }

  Set-Mailbox -Identity $mailboxIdentity -DisplayName $DisplayName

  if ($mailbox.Alias -ne $Alias) {
    Set-Mailbox -Identity $mailboxIdentity -Alias $Alias
  }

  if ($mailbox.PrimarySmtpAddress -ne $PrimarySmtpAddress) {
    Set-Mailbox -Identity $mailboxIdentity -PrimarySmtpAddress $PrimarySmtpAddress
  }

  if ($makeVisibleValue -and $wasHidden) {
    Set-Mailbox -Identity $mailboxIdentity -HiddenFromAddressListsEnabled:$false
  }

  Set-MailboxRegionalConfiguration -Identity $mailboxIdentity -TimeZone $TimeZone -Language $Language

  $calParams = @{
    Identity                 = $mailboxIdentity
    AutomateProcessing       = 'AutoAccept'
    AllowConflicts           = $allowConflictsValue
    BookingWindowInDays      = $BookingWindowInDays
    MaximumDurationInMinutes = $MaximumDurationInMinutes
    AllowRecurringMeetings   = $allowRecurringMeetingsValue
    AllBookInPolicy          = $true
    AllRequestInPolicy       = $false
  }
  Set-CalendarProcessing @calParams

  if (-not [string]::IsNullOrWhiteSpace($VIN) -or -not [string]::IsNullOrWhiteSpace($LicensePlate)) {
    Set-Mailbox -Identity $mailboxIdentity `
      -CustomAttribute1 $VIN `
      -CustomAttribute2 $LicensePlate
  }

  $approverList = @()
  if (-not [string]::IsNullOrWhiteSpace($Approvers)) {
    $approverList = $Approvers.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  }
  if ($approverList.Count -gt 0) {
    Set-CalendarProcessing -Identity $mailboxIdentity -BookInPolicy $approverList
  }

  $managerList = @()
  if (-not [string]::IsNullOrWhiteSpace($FleetManagers)) {
    $managerList = $FleetManagers.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
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

  Write-Output (To-JsonResult -Success $true -Message 'Mailbox updated' -Extra @{
    found = $true
    primarySmtpAddress = $PrimarySmtpAddress
    displayName = $DisplayName
    wasHidden = [bool]$wasHidden
    madeVisible = [bool]($makeVisibleValue -and $wasHidden)
  })
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
