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
  [Parameter(Mandatory = $false)][string]$Bookable = '0',
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

function Split-IdentifierList {
  param(
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return @()
  }

  return @(
    $Value -split '[,;\r\n]+' |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ } |
    Select-Object -Unique
  )
}

function Get-IdentityKeys {
  param(
    $Value
  )

  $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

  function Add-IdentityKey {
    param(
      [string]$Candidate
    )

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
      return
    }

    $trimmed = $Candidate.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
      return
    }

    [void]$keys.Add($trimmed.ToLowerInvariant())

    if ($trimmed.Contains('\')) {
      $suffix = $trimmed.Split('\')[-1]
      if (-not [string]::IsNullOrWhiteSpace($suffix)) {
        [void]$keys.Add($suffix.Trim().ToLowerInvariant())
      }
    }
  }

  if ($null -eq $Value) {
    return @()
  }

  if ($Value -is [string]) {
    Add-IdentityKey -Candidate $Value
    return @($keys)
  }

  foreach ($property in $Value.PSObject.Properties) {
    $propertyValue = $property.Value
    if ($null -eq $propertyValue) {
      continue
    }
    if ($propertyValue -is [string]) {
      Add-IdentityKey -Candidate $propertyValue
      continue
    }
    if ($propertyValue -is [System.Collections.IEnumerable] -and -not ($propertyValue -is [string])) {
      foreach ($item in $propertyValue) {
        if ($item -is [string]) {
          Add-IdentityKey -Candidate $item
        }
      }
    }
  }

  return @($keys)
}

function Resolve-RecipientIdentity {
  param(
    [string]$Identity
  )

  $resolvedIdentity = $Identity
  $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

  foreach ($key in (Get-IdentityKeys -Value $Identity)) {
    [void]$keys.Add($key)
  }

  $recipient = $null
  try {
    $recipient = Get-EXORecipient -Identity $Identity -ErrorAction Stop
  } catch {
    try {
      $recipient = Get-Recipient -Identity $Identity -ErrorAction Stop
    } catch {
      $recipient = $null
    }
  }

  if ($recipient) {
    foreach ($candidate in @(
      $recipient.DisplayName,
      $recipient.Name,
      $recipient.Alias,
      $recipient.Identity,
      $recipient.PrimarySmtpAddress,
      $recipient.WindowsEmailAddress,
      $recipient.UserPrincipalName,
      $recipient.ExternalEmailAddress
    )) {
      foreach ($key in (Get-IdentityKeys -Value $candidate)) {
        [void]$keys.Add($key)
      }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$recipient.PrimarySmtpAddress)) {
      $resolvedIdentity = [string]$recipient.PrimarySmtpAddress
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$recipient.UserPrincipalName)) {
      $resolvedIdentity = [string]$recipient.UserPrincipalName
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$recipient.Identity)) {
      $resolvedIdentity = [string]$recipient.Identity
    }
  }

  return @{
    Identity = $resolvedIdentity
    Keys = @($keys)
  }
}

function Normalize-Text {
  param(
    $Value,
    [switch]$ToLower
  )

  if ($null -eq $Value) {
    return ''
  }

  $text = [string]$Value
  $trimmed = $text.Trim()
  if ($ToLower) {
    return $trimmed.ToLowerInvariant()
  }
  return $trimmed
}

function Get-IdentityKeySet {
  param(
    $Values
  )

  $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  if ($null -eq $Values) {
    return ,$set
  }

  if (($Values -is [System.Collections.IEnumerable]) -and -not ($Values -is [string])) {
    foreach ($value in $Values) {
      foreach ($key in (Get-IdentityKeys -Value $value)) {
        [void]$set.Add($key)
      }
    }
    return ,$set
  }

  foreach ($key in (Get-IdentityKeys -Value $Values)) {
    [void]$set.Add($key)
  }
  return ,$set
}

function Test-IdentitySetsEqual {
  param(
    $Left,
    $Right
  )

  $leftSet = Get-IdentityKeySet -Values $Left
  $rightSet = Get-IdentityKeySet -Values $Right

  if ($leftSet.Count -ne $rightSet.Count) {
    return $false
  }

  foreach ($key in $leftSet) {
    if (-not $rightSet.Contains($key)) {
      return $false
    }
  }

  return $true
}

function Get-SerialPlaceholderKey {
  param(
    [string]$Value
  )

  return [regex]::Replace((Normalize-Text -Value $Value -ToLower), '[^a-z0-9]+', '')
}

function Test-IsPlaceholderSerial {
  param(
    [string]$Serial
  )

  $placeholderKeys = @(
    '0000000000',
    'unknown',
    'na',
    'none',
    'null'
  )

  $serialKey = Get-SerialPlaceholderKey -Value $Serial
  if ([string]::IsNullOrWhiteSpace($serialKey)) {
    return $false
  }

  return $placeholderKeys -contains $serialKey
}

function Get-MailboxAliasCandidate {
  param(
    [string]$Serial,
    [string]$Alias,
    [string]$PrimarySmtpAddress
  )

  $normalizedAlias = Normalize-Text -Value $Alias -ToLower
  if (-not [string]::IsNullOrWhiteSpace($normalizedAlias)) {
    return $normalizedAlias
  }

  $normalizedSerial = Normalize-Text -Value $Serial -ToLower
  if (-not [string]::IsNullOrWhiteSpace($normalizedSerial)) {
    return $normalizedSerial
  }

  $normalizedPrimarySmtpAddress = Normalize-Text -Value $PrimarySmtpAddress -ToLower
  if ($normalizedPrimarySmtpAddress.Contains('@')) {
    return $normalizedPrimarySmtpAddress.Split('@')[0]
  }

  return ''
}

function Test-IsValidMailboxAliasCandidate {
  param(
    [string]$AliasCandidate
  )

  $normalized = Normalize-Text -Value $AliasCandidate -ToLower
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    return $false
  }

  if ($normalized.Contains('@') -or $normalized.StartsWith('.') -or $normalized.EndsWith('.') -or $normalized.Contains('..')) {
    return $false
  }

  if ($normalized -notmatch '^[a-z0-9!#$%&''*+\-/=?^_`{|}~.]+$') {
    return $false
  }

  return ($normalized -match '[a-z0-9]')
}

function Test-TimeZoneMatchesDesired {
  param(
    $RegionalConfiguration,
    [string]$DesiredTimeZone
  )

  $currentTimeZone = Normalize-Text -Value ($RegionalConfiguration.TimeZone)
  $desired = Normalize-Text -Value $DesiredTimeZone

  if ($currentTimeZone -eq $desired) {
    return $true
  }

  if ([string]::IsNullOrWhiteSpace($currentTimeZone) -or [string]::IsNullOrWhiteSpace($desired)) {
    return $false
  }

  try {
    $timeZoneInfo = [System.TimeZoneInfo]::FindSystemTimeZoneById($desired)
  } catch {
    return $false
  }

  foreach ($candidate in @(
    $timeZoneInfo.Id,
    $timeZoneInfo.DisplayName,
    $timeZoneInfo.StandardName,
    $timeZoneInfo.DaylightName
  )) {
    if ((Normalize-Text -Value $candidate) -eq $currentTimeZone) {
      return $true
    }
  }

  return $false
}

function Get-RegionalLanguageCode {
  param(
    $RegionalConfiguration
  )

  if ($null -eq $RegionalConfiguration) {
    return ''
  }

  $language = $RegionalConfiguration.Language
  if ($null -eq $language) {
    return ''
  }

  if ($language -is [string]) {
    return Normalize-Text -Value $language -ToLower
  }

  if ($language.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace([string]$language.Name)) {
    return Normalize-Text -Value ([string]$language.Name) -ToLower
  }

  return Normalize-Text -Value ([string]$language) -ToLower
}

function Test-IsEditorPermission {
  param(
    $Permission
  )

  $accessRights = @()
  if ($Permission -and $Permission.AccessRights) {
    $accessRights = @($Permission.AccessRights | ForEach-Object { Normalize-Text -Value ([string]$_) })
  }

  return ($accessRights -contains 'Editor')
}

function Test-CalendarProcessingNeedsUpdate {
  param(
    $CalendarProcessing,
    [bool]$BookableValue,
    [bool]$AllowConflictsValue,
    [int]$BookingWindowInDaysValue,
    [int]$MaximumDurationInMinutesValue,
    [bool]$AllowRecurringMeetingsValue,
    $DesiredApproverKeys
  )

  if ($null -eq $CalendarProcessing) {
    return $true
  }

  if ((Normalize-Text -Value ([string]$CalendarProcessing.AutomateProcessing)) -ne 'AutoAccept') {
    return $true
  }

  if ($BookableValue) {
    if ([bool]$CalendarProcessing.AllowConflicts -ne $AllowConflictsValue) {
      return $true
    }
    if ([int]$CalendarProcessing.BookingWindowInDays -ne $BookingWindowInDaysValue) {
      return $true
    }
    if ([int]$CalendarProcessing.MaximumDurationInMinutes -ne $MaximumDurationInMinutesValue) {
      return $true
    }
    if ([bool]$CalendarProcessing.AllowRecurringMeetings -ne $AllowRecurringMeetingsValue) {
      return $true
    }
    if (-not [bool]$CalendarProcessing.AllBookInPolicy) {
      return $true
    }
    if ([bool]$CalendarProcessing.AllRequestInPolicy) {
      return $true
    }

    $currentBookInPolicyKeys = Get-IdentityKeySet -Values $CalendarProcessing.BookInPolicy
    if (-not (Test-IdentitySetsEqual -Left $currentBookInPolicyKeys -Right $DesiredApproverKeys)) {
      return $true
    }

    return $false
  }

  if ([bool]$CalendarProcessing.AllBookInPolicy) {
    return $true
  }
  if ([bool]$CalendarProcessing.AllRequestInPolicy) {
    return $true
  }
  if ([bool]$CalendarProcessing.AllRequestOutOfPolicy) {
    return $true
  }
  if ([bool]$CalendarProcessing.ForwardRequestsToDelegates) {
    return $true
  }
  if ((Get-IdentityKeySet -Values $CalendarProcessing.BookInPolicy).Count -gt 0) {
    return $true
  }
  if ((Get-IdentityKeySet -Values $CalendarProcessing.RequestInPolicy).Count -gt 0) {
    return $true
  }
  if ((Get-IdentityKeySet -Values $CalendarProcessing.RequestOutOfPolicy).Count -gt 0) {
    return $true
  }
  if ((Get-IdentityKeySet -Values $CalendarProcessing.ResourceDelegates).Count -gt 0) {
    return $true
  }

  return $false
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
  $bookableValue = To-Bool -Value ([string]($Item.bookable ?? $Bookable)) -Default $false
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
  $aliasCandidate = Get-MailboxAliasCandidate -Serial $serial -Alias $alias -PrimarySmtpAddress $primarySmtpAddress

  if ((-not [string]::IsNullOrWhiteSpace($serial) -and (Test-IsPlaceholderSerial -Serial $serial)) -or
      (-not (Test-IsValidMailboxAliasCandidate -AliasCandidate $aliasCandidate))) {
    return @{
      success = $true
      message = 'Skipped invalid or placeholder serial'
      found = $false
      skipped = $true
      primarySmtpAddress = $primarySmtpAddress
      alias = $alias
      deviceId = $deviceId
      serial = $serial
      vehicleName = $vehicleName
    }
  }

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

    $mailboxUpdated = $false
    $setMailboxParams = @{
      Identity = $mailboxIdentity
    }
    if ((Normalize-Text -Value $mailbox.DisplayName) -ne (Normalize-Text -Value $displayName)) {
      $setMailboxParams.DisplayName = $displayName
    }
    if ((Normalize-Text -Value $mailbox.Alias -ToLower) -ne (Normalize-Text -Value $alias -ToLower)) {
      $setMailboxParams.Alias = $alias
    }
    if ((Normalize-Text -Value ([string]$mailbox.PrimarySmtpAddress) -ToLower) -ne (Normalize-Text -Value $primarySmtpAddress -ToLower)) {
      $setMailboxParams.PrimarySmtpAddress = $primarySmtpAddress
    }
    if ($bookableValue) {
      if ($makeVisibleValue -and $wasHidden) {
        $setMailboxParams.HiddenFromAddressListsEnabled = $false
      }
    } elseif (-not $wasHidden) {
      $setMailboxParams.HiddenFromAddressListsEnabled = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($vinValue) -or -not [string]::IsNullOrWhiteSpace($licensePlateValue)) {
      if ((Normalize-Text -Value $mailbox.CustomAttribute1) -ne (Normalize-Text -Value $vinValue) -or
          (Normalize-Text -Value $mailbox.CustomAttribute2) -ne (Normalize-Text -Value $licensePlateValue)) {
        $setMailboxParams.CustomAttribute1 = $vinValue
        $setMailboxParams.CustomAttribute2 = $licensePlateValue
      }
    }
    if ($setMailboxParams.Count -gt 1) {
      Set-Mailbox @setMailboxParams
      $mailboxUpdated = $true
    }

    $regionalConfiguration = Get-MailboxRegionalConfiguration -Identity $mailboxIdentity -ErrorAction SilentlyContinue
    $regionalConfigUpdated = $false
    if (-not (Test-TimeZoneMatchesDesired -RegionalConfiguration $regionalConfiguration -DesiredTimeZone $timeZone) -or
        (Get-RegionalLanguageCode -RegionalConfiguration $regionalConfiguration) -ne (Normalize-Text -Value $language -ToLower)) {
      Set-MailboxRegionalConfiguration -Identity $mailboxIdentity -TimeZone $timeZone -Language $language
      $regionalConfigUpdated = $true
    }

    $approverList = Split-IdentifierList -Value $approversValue
    $desiredApproverKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($approver in $approverList) {
      $resolvedApprover = Resolve-RecipientIdentity -Identity $approver
      foreach ($key in $resolvedApprover.Keys) {
        [void]$desiredApproverKeys.Add($key)
      }
    }

    $calendarProcessing = Get-CalendarProcessing -Identity $mailboxIdentity -ErrorAction SilentlyContinue
    $calendarProcessingUpdated = $false

    if (Test-CalendarProcessingNeedsUpdate `
      -CalendarProcessing $calendarProcessing `
      -BookableValue $bookableValue `
      -AllowConflictsValue $allowConflictsValue `
      -BookingWindowInDaysValue $bookingWindowInDaysValue `
      -MaximumDurationInMinutesValue $maximumDurationInMinutesValue `
      -AllowRecurringMeetingsValue $allowRecurringMeetingsValue `
      -DesiredApproverKeys $desiredApproverKeys) {
      if ($bookableValue) {
        $calParams = @{
          Identity                 = $mailboxIdentity
          AutomateProcessing       = 'AutoAccept'
          AllowConflicts           = $allowConflictsValue
          BookingWindowInDays      = $bookingWindowInDaysValue
          MaximumDurationInMinutes = $maximumDurationInMinutesValue
          AllowRecurringMeetings   = $allowRecurringMeetingsValue
          AllBookInPolicy          = $true
          AllRequestInPolicy       = $false
          BookInPolicy             = $approverList
        }
        Set-CalendarProcessing @calParams
      } else {
        Set-CalendarProcessing `
          -Identity $mailboxIdentity `
          -AutomateProcessing 'AutoAccept' `
          -AllBookInPolicy:$false `
          -AllRequestInPolicy:$false `
          -AllRequestOutOfPolicy:$false `
          -BookInPolicy @() `
          -RequestInPolicy @() `
          -RequestOutOfPolicy @() `
          -ResourceDelegates @() `
          -ForwardRequestsToDelegates:$false
      }
      $calendarProcessingUpdated = $true
    }

    $managerList = Split-IdentifierList -Value $fleetManagersValue
    $calendarIdentity = "$($primarySmtpAddress):\Calendar"
    $existingManagerPermissions = @(
      Get-MailboxFolderPermission -Identity $calendarIdentity -ErrorAction SilentlyContinue |
      Where-Object {
        $_.User -and
        $_.User.UserType -eq 'Internal' -and
        $_.User.DisplayName -notin @('Default', 'Anonymous')
      }
    )
    $existingManagerEntries = @()
    foreach ($permission in $existingManagerPermissions) {
      $entryKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
      foreach ($key in (Get-IdentityKeys -Value $permission.User)) {
        [void]$entryKeys.Add($key)
      }
      $displayName = [string]$permission.User.DisplayName
      if (-not [string]::IsNullOrWhiteSpace($displayName)) {
        $resolvedPermissionUser = Resolve-RecipientIdentity -Identity $displayName
        foreach ($key in $resolvedPermissionUser.Keys) {
          [void]$entryKeys.Add($key)
        }
      }

      $existingManagerEntries += @{
        Permission = $permission
        DisplayName = $displayName
        Keys = @($entryKeys)
      }
    }

    $desiredManagerKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $resolvedManagers = @()
    foreach ($manager in $managerList) {
      $resolvedManager = Resolve-RecipientIdentity -Identity $manager
      foreach ($key in $resolvedManager.Keys) {
        [void]$desiredManagerKeys.Add($key)
      }
      $resolvedManagers += $resolvedManager
    }

    $managerPermissionsUpdated = $false
    foreach ($resolvedManager in $resolvedManagers) {
      $managerIdentity = [string]$resolvedManager.Identity
      $matchingPermission = $null
      foreach ($entry in $existingManagerEntries) {
        if ($entry.Keys | Where-Object { $resolvedManager.Keys -contains $_ } | Select-Object -First 1) {
          $matchingPermission = $entry.Permission
          break
        }
      }

      try {
        if ($matchingPermission) {
          if (-not (Test-IsEditorPermission -Permission $matchingPermission)) {
            Set-MailboxFolderPermission `
              -Identity $calendarIdentity `
              -User $managerIdentity `
              -AccessRights Editor `
              -ErrorAction Stop | Out-Null
            $managerPermissionsUpdated = $true
          }
        } else {
          Add-MailboxFolderPermission `
            -Identity $calendarIdentity `
            -User $managerIdentity `
            -AccessRights Editor `
            -ErrorAction Stop | Out-Null
          $managerPermissionsUpdated = $true
        }
      } catch {
        if ($_.Exception.Message -notmatch 'already' -and $_.Exception.Message -notmatch 'existing permission entry') {
          throw
        }
      }
    }

    foreach ($entry in $existingManagerEntries) {
      $existingManager = $entry.DisplayName
      if ([string]::IsNullOrWhiteSpace($existingManager)) {
        continue
      }
      if ($entry.Keys | Where-Object { $desiredManagerKeys.Contains($_) } | Select-Object -First 1) {
        continue
      }
      Remove-MailboxFolderPermission `
        -Identity $calendarIdentity `
        -User $existingManager `
        -Confirm:$false `
        -ErrorAction SilentlyContinue | Out-Null
      $managerPermissionsUpdated = $true
    }

    $changesApplied = $mailboxUpdated -or $regionalConfigUpdated -or $calendarProcessingUpdated -or $managerPermissionsUpdated
    if (-not $changesApplied) {
      return @{
        success = $true
        message = 'Mailbox already up to date'
        found = $true
        skipped = $true
        bookable = [bool]$bookableValue
        allowRecurringMeetings = [bool]$allowRecurringMeetingsValue
        allowConflicts = [bool]$allowConflictsValue
        approverCount = $approverList.Count
        fleetManagerCount = $managerList.Count
        primarySmtpAddress = $primarySmtpAddress
        displayName = $displayName
        wasHidden = [bool]$wasHidden
        madeVisible = $false
        deviceId = $deviceId
        serial = $serial
        vehicleName = $vehicleName
      }
    }

    return @{
      success = $true
      message = 'Mailbox updated'
      found = $true
      bookable = [bool]$bookableValue
      allowRecurringMeetings = [bool]$allowRecurringMeetingsValue
      allowConflicts = [bool]$allowConflictsValue
      approverCount = $approverList.Count
      fleetManagerCount = $managerList.Count
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
      $result = Invoke-MailboxSync -Item (To-Hashtable -InputObject $item)
      $results += $result
      $progressEvent = @{
        serial = [string]($result.serial ?? '')
        success = [bool]($result.success)
        message = [string]($result.message ?? '')
        vehicleName = [string]($result.vehicleName ?? '')
      }
      Write-Output ("__FLEETBRIDGE_PROGRESS__" + (ConvertTo-Json -InputObject $progressEvent -Depth 5 -Compress))
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
    bookable = $Bookable
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
