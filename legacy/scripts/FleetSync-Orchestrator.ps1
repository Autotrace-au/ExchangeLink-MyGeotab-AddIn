<#
.SYNOPSIS
End-to-end FleetSync orchestrator. Creates equipment mailboxes for vehicles from MyGeotab if missing; skips existing.

.DESCRIPTION
- Reads config from Automation Variables (overrideable via parameters)
- Authenticates to MyGeotab and fetches devices (name, serialNumber, VIN)
- Connects to Exchange Online (app-only, certificate)
- For each device:
  - alias = serialNumber (lowercase)
  - primary SMTP = alias@Equipment_Domain
  - If mailbox exists: update friendly name (to vehicle name), enforce alias and primary SMTP, and apply sensible booking defaults
  - If missing: skip (no creation)

.REQUIREMENTS (Automation Assets)
- Variable: EXO_AppId (App registration application ID)
- Certificate: EXO-AppCert (assigned to EXO App; EXO Graph RBAC roles as needed)
- Variables (recommended):
  - FS_Equipment_Domain
  - FS_Default_TimeZone (e.g. "AUS Eastern Standard Time")
  - FS_MyGeotab_Server (optional)
  - FS_MyGeotab_Database
  - FS_MyGeotab_Username
  - FS_MyGeotab_Password (secure variable recommended; plain var supported)

.NOTES
- Update-only by design: users create mailboxes per serial; if mailbox exists update its details and defaults, if missing skip (no creation).
#>

param(
  [Parameter(Mandatory=$false)][object]$WebhookData,
  # Overrides; if not supplied, Automation Variables will be used
  [Parameter(Mandatory=$false)][string]$EquipmentDomain,
  [Parameter(Mandatory=$false)][string]$DefaultTimeZone,
  [Parameter(Mandatory=$false)][string]$MyGeotabServer,
  [Parameter(Mandatory=$false)][string]$MyGeotabDatabase,
  [Parameter(Mandatory=$false)][string]$MyGeotabUsername,
  [Parameter(Mandatory=$false)][string]$MyGeotabPassword,
  # Optional: Limit processing for testing
  [Parameter(Mandatory=$false)][int]$MaxDevices = 0
)

$ErrorActionPreference = 'Stop'
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12 } catch {}

try { Import-Module Microsoft.Graph.Authentication -ErrorAction Stop } catch { Write-Warning "Microsoft.Graph.Authentication module not found; Graph calendar updates will be skipped." }
try { Import-Module Microsoft.Graph.Calendar -ErrorAction Stop } catch { Write-Warning "Microsoft.Graph.Calendar module not found; Graph calendar updates will be skipped." }


function Get-Var {
  param([string]$Name,[string]$Fallback=$null)
  try { $v = Get-AutomationVariable -Name $Name -ErrorAction Stop } catch { $v = $null }
  if ([string]::IsNullOrWhiteSpace($v)) { return $Fallback } else { return $v }
}

function Get-IfPresent {
  param([object]$Obj,[string[]]$Names)
  foreach ($n in $Names) {
    if ($Obj -and ($Obj.PSObject.Properties.Name -contains $n)) {
      $val = $Obj.$n
      if ($null -ne $val) {
        if ($val -is [string]) { if (-not [string]::IsNullOrWhiteSpace($val)) { return $val } }
        else { return $val }
      }
    }
  }
  return $null
}
function Has-Cmd {
  param([string]$Name)
  return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}
function Convert-ToWindowsTimeZone {
  param([string]$TimeZone)
  if ([string]::IsNullOrWhiteSpace($TimeZone)) { return $script:DefaultTimeZone }
  $tz = $TimeZone.Trim()
  # If already a Windows TZ id, return as-is
  $knownWin = @(
    'AUS Eastern Standard Time','E. Australia Standard Time','Cen. Australia Standard Time','AUS Central Standard Time',
    'Tasmania Standard Time','W. Australia Standard Time','Lord Howe Standard Time','Aus Central W. Standard Time'
  )
  if ($knownWin -contains $tz) { return $tz }
  # Map common IANA -> Windows (AU focus)
  $map = @{
    'Australia/Sydney'      = 'AUS Eastern Standard Time'
    'Australia/Melbourne'   = 'AUS Eastern Standard Time'
    'Australia/Canberra'    = 'AUS Eastern Standard Time'
    'Australia/Brisbane'    = 'E. Australia Standard Time'
    'Australia/Hobart'      = 'Tasmania Standard Time'
    'Australia/Lindeman'    = 'E. Australia Standard Time'
    'Australia/Adelaide'    = 'Cen. Australia Standard Time'
    'Australia/Darwin'      = 'AUS Central Standard Time'
    'Australia/Perth'       = 'W. Australia Standard Time'
    'Australia/Broken_Hill' = 'Cen. Australia Standard Time'
    'Australia/Eucla'       = 'Aus Central W. Standard Time'
    'Australia/Lord_Howe'   = 'Lord Howe Standard Time'
  }
  if ($map.ContainsKey($tz)) { return $map[$tz] }
  # Fallback: try to detect by substring
  if ($tz -match 'sydney|melbourne|canberra|nsw|vic|act') { return 'AUS Eastern Standard Time' }
  if ($tz -match 'brisbane|qld|queensland|lindeman') { return 'E. Australia Standard Time' }
  if ($tz -match 'hobart|tas') { return 'Tasmania Standard Time' }
  if ($tz -match 'adelaide|south australia|broken') { return 'Cen. Australia Standard Time' }
  if ($tz -match 'darwin|nt|northern territory') { return 'AUS Central Standard Time' }
  if ($tz -match 'perth|wa|western australia') { return 'W. Australia Standard Time' }
  return $script:DefaultTimeZone
}

function Resolve-WorkingHoursProfile {
  param([object]$WorkHours)
  if (-not $WorkHours) { return $null }
  # Common indicators
  $s = if ($WorkHours -is [string]) { $WorkHours.Trim().ToLowerInvariant() } else { ($WorkHours | Out-String).Trim().ToLowerInvariant() }
  if ($s -match 'standardhours|worktimestandardhours|business|9-5|9to5') {
    return [pscustomobject]@{ Start='09:00:00'; End='17:00:00'; Days=@('Monday','Tuesday','Wednesday','Thursday','Friday') }
  }
  if ($s -match '24x7|24/7|always|all\s*hours|anytime') {
    return [pscustomobject]@{ Start='00:00:00'; End='23:59:59'; Days=@('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday') }
  }
  # If object has explicit fields
  try {
    $start = Get-IfPresent -Obj $WorkHours -Names @('start','startTime','workingHoursStart','from')
    $end   = Get-IfPresent -Obj $WorkHours -Names @('end','endTime','workingHoursEnd','to')
    $days  = Get-IfPresent -Obj $WorkHours -Names @('days','weekDays','workDays')
    if ($start -and $end -and $days) {
      # Normalise days into full names
      $dn = @()
      foreach ($d in $days) {
        switch -Regex ($d.ToString()) {
          'mon' { $dn += 'Monday' }
          'tue' { $dn += 'Tuesday' }
          'wed' { $dn += 'Wednesday' }
          'thu' { $dn += 'Thursday' }
          'fri' { $dn += 'Friday' }
          'sat' { $dn += 'Saturday' }
          'sun' { $dn += 'Sunday' }
          default { if ($d) { $dn += $d } }
        }
      }
      return [pscustomobject]@{ Start=([string]$start); End=([string]$end); Days=$dn }
    }
  } catch {}
  return $null
}

function Find-EquipmentMailbox {
  param(
    [string]$PrimarySmtpAddress,
    [string]$Alias
  )
  # Normalise
  if ($PrimarySmtpAddress) { $PrimarySmtpAddress = $PrimarySmtpAddress.Trim().Trim('"').Trim("'") }
  if ($Alias) { $Alias = $Alias.Trim().Trim('"').Trim("'") }
  $local = $null
  if ($PrimarySmtpAddress -and ($PrimarySmtpAddress -like '*@*')) { $local = ($PrimarySmtpAddress.Split('@')[0]).ToLowerInvariant() }
  elseif ($Alias) { $local = $Alias.ToLowerInvariant() }
  $domain = Get-OrgDomain
  $targetSmtp = if ($PrimarySmtpAddress -and ($PrimarySmtpAddress -like '*@*')) { $PrimarySmtpAddress.ToLowerInvariant() } elseif ($local -and $domain) { ("$local@$domain").ToLowerInvariant() } else { $null }

  $mbx = $null

  # A) Direct mailbox identity, with REST filter fallback
  if ($targetSmtp) {
    try { $mbx = Get-EXOMailbox -Identity $targetSmtp -ErrorAction Stop } catch {
      try { $mbx = Get-EXOMailbox -ResultSize 1 -Filter "PrimarySmtpAddress -eq '$targetSmtp'" -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { $mbx = $null }
      if (-not $mbx) { try { $mbx = Get-EXOMailbox -ResultSize 1 -Filter "EmailAddresses -eq 'smtp:$targetSmtp'" -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { $mbx = $null } }
    }
    if (-not $mbx -and (Has-Cmd 'Get-Mailbox')) { try { $mbx = Get-Mailbox -Identity $targetSmtp -ErrorAction SilentlyContinue } catch {} }
    if ($mbx) { Write-Output "Find-EquipmentMailbox: resolved via mailbox identity/filter ($targetSmtp)"; return $mbx }
  }

  # B) Recipient exact matches (Primary and proxy)
  if ($targetSmtp) {
    try { $rec = Get-EXORecipient -Identity $targetSmtp -ErrorAction SilentlyContinue } catch { $rec = $null }
    if ($rec) {
      try { $mbx = Get-EXOMailbox -Identity $rec.Identity -ErrorAction SilentlyContinue } catch { $mbx = $null }
      if (-not $mbx -and (Has-Cmd 'Get-Mailbox')) { try { $mbx = Get-Mailbox -Identity $rec.Identity -ErrorAction SilentlyContinue } catch {} }
      if ($mbx) { Write-Output "Find-EquipmentMailbox: resolved via recipient identity ($targetSmtp)"; return $mbx }
    }
    try { $rec = Get-EXORecipient -ResultSize 1 -Filter "PrimarySmtpAddress -eq '$targetSmtp'" -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { $rec = $null }
    if ($rec) { try { $mbx = Get-EXOMailbox -Identity $rec.Identity -ErrorAction SilentlyContinue } catch { $mbx = $null }; if ($mbx) { Write-Output "Find-EquipmentMailbox: resolved via recipient PrimarySmtpAddress eq ($targetSmtp)"; return $mbx } }
    try { $rec = Get-EXORecipient -ResultSize 1 -Filter "EmailAddresses -eq 'smtp:$targetSmtp'" -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { $rec = $null }
    if ($rec) { try { $mbx = Get-EXOMailbox -Identity $rec.Identity -ErrorAction SilentlyContinue } catch { $mbx = $null }; if ($mbx) { Write-Output "Find-EquipmentMailbox: resolved via recipient proxy eq ($targetSmtp)"; return $mbx } }
  }

  # C) Local-part wildcard fallback across recipients
  if ($local) {
    try { $rec = Get-EXORecipient -ResultSize 1 -Filter "EmailAddresses -like 'smtp:$local@*'" -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { $rec = $null }
    if ($rec) { try { $mbx = Get-EXOMailbox -Identity $rec.Identity -ErrorAction SilentlyContinue } catch { $mbx = $null }; if ($mbx) { Write-Output "Find-EquipmentMailbox: resolved via recipient proxy like ($local)"; return $mbx } }
  }

  # D) Mailbox filter wildcard across common types (no broad download)
  if ($local) {
    foreach ($type in 'EquipmentMailbox','RoomMailbox','SharedMailbox','UserMailbox') {
      try { $m = Get-EXOMailbox -ResultSize 1 -RecipientTypeDetails $type -Filter "EmailAddresses -like 'smtp:$local@*'" -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { $m = $null }
      if ($m) { Write-Output "Find-EquipmentMailbox: resolved via mailbox $type proxy like ($local)"; return $m }
    }
  }

  # E) Remote PowerShell fallback (if available)
  if ($local -and (Has-Cmd 'Get-Recipient')) {
    try {
      $rec = Get-Recipient -ResultSize Unlimited -Filter "EmailAddresses -like 'SMTP:$local@*'" -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($rec -and (Has-Cmd 'Get-Mailbox')) {
        try { $mbx = Get-Mailbox -Identity $rec.Identity -ErrorAction SilentlyContinue } catch {}
        if ($mbx) { Write-Output "Find-EquipmentMailbox: resolved via Get-Recipient RPS ($local)"; return $mbx }
      }
    } catch {}
  }

  return $null
}


function Connect-GraphApp {
  param([string]$Tenant=$null)
  if (-not (Has-Cmd 'Connect-MgGraph')) { return $false }
  $t = if ($Tenant) { $Tenant } else { $envTenant = Get-Var 'FS_TenantId'; if ([string]::IsNullOrWhiteSpace($envTenant)) { Get-OrgDomain } else { $envTenant } }
  try {
    Connect-MgGraph -TenantId $t -ClientId $script:EXO_AppId -CertificateThumbprint $script:EXO_CertThumb -NoWelcome -ErrorAction Stop | Out-Null
    try { Select-MgProfile -Name 'v1.0' -ErrorAction SilentlyContinue } catch {}
    return $true
  } catch {
    Write-Warning ("Graph connect failed: {0}" -f $_.Exception.Message)
    return $false
  }
}

function Set-DefaultCalendarPermission-Graph {
  param(
    [Parameter(Mandatory=$true)][string]$UserUpn,
    [Parameter(Mandatory=$false)][ValidateSet('freeBusyRead','limitedRead','read','write')][string]$Role='freeBusyRead'
  )
  if (-not (Has-Cmd 'Get-MgUserCalendarPermission') -or -not (Has-Cmd 'Update-MgUserCalendarPermission')) { return $false }
  if (-not (Connect-GraphApp)) { return $false }
  try {
    $perms = Get-MgUserCalendarPermission -UserId $UserUpn -ErrorAction Stop
    # Prefer the special org-wide entry
    $org = $perms | Where-Object { $_.EmailAddress -and $_.EmailAddress.Name -eq 'My Organization' } | Select-Object -First 1
    if (-not $org) {
      # Fallback for 'Default' entry id (commonly base64 of 'Default')
      $org = $perms | Where-Object { $_.Id -eq 'RGVmYXVsdA==' -or $_.Id -eq 'Default' } | Select-Object -First 1
    }
    if (-not $org) { Write-Warning "Graph: could not locate 'My Organization' calendar permission for $UserUpn"; return $false }
    if ($org.Role -ne $Role) {
      Update-MgUserCalendarPermission -UserId $UserUpn -CalendarPermissionId $org.Id -BodyParameter @{ role = $Role } | Out-Null
    }
    return $true
  } catch {
    Write-Warning ("Graph calendar permission update failed for {0}: {1}" -f $UserUpn,$_.Exception.Message)
    return $false
  }
}



function Ensure-ExchangeOnline {
  Import-Module ExchangeOnlineManagement -ErrorAction Stop
  $appId = Get-Var 'EXO_AppId'
  $cert  = Get-AutomationCertificate -Name 'EXO-AppCert'
  if ([string]::IsNullOrWhiteSpace($appId) -or -not $cert) { throw "Missing EXO_AppId or EXO-AppCert" }
  # Expose for Graph connection reuse
  $script:EXO_AppId    = $appId
  $script:EXO_CertThumb = $cert.Thumbprint
  $store = New-Object System.Security.Cryptography.X509Certificates.X509Store "My","CurrentUser"
  $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
  try { $store.Add($cert) } finally { $store.Close() }
  $org = Get-OrgDomain
  Write-Output "Connecting to Exchange Online org (REST): $org"
  Write-Output "Using EXO AppId: $appId"
  $exo = @{ AppId=$appId; CertificateThumbprint=$cert.Thumbprint; Organization=$org; ShowBanner=$false }
  Connect-ExchangeOnline @exo
}

function Get-OrgDomain {
  # Prefer Equipment domain as org domain; override in param if needed
  if ($script:OrgDomain) { return $script:OrgDomain }
  $d = if ($script:EquipmentDomain) { $script:EquipmentDomain } elseif ($EquipmentDomain) { $EquipmentDomain } else { Get-Var 'FS_Equipment_Domain' }
  if ($d -is [string]) { $d = $d.Trim().Trim('"').Trim("'") }
  if ([string]::IsNullOrWhiteSpace($d)) { throw "Equipment domain required (FS_Equipment_Domain or -EquipmentDomain)." }
  $script:OrgDomain = $d; return $d
}

function Get-Config {
  $script:EquipmentDomain  = if ($EquipmentDomain) { $EquipmentDomain } else { Get-Var 'FS_Equipment_Domain' }
  $script:DefaultTimeZone  = if ($DefaultTimeZone) { $DefaultTimeZone } else { (Get-Var 'FS_Default_TimeZone' 'AUS Eastern Standard Time') }
  $script:MyGeotabServer   = if ($MyGeotabServer) { $MyGeotabServer } else { Get-Var 'FS_MyGeotab_Server' }
  $script:MyGeotabDatabase = if ($MyGeotabDatabase) { $MyGeotabDatabase } else { Get-Var 'FS_MyGeotab_Database' }
  $script:MyGeotabUsername = if ($MyGeotabUsername) { $MyGeotabUsername } else { Get-Var 'FS_MyGeotab_Username' }
  $script:MyGeotabPassword = if ($MyGeotabPassword) { $MyGeotabPassword } else { Get-Var 'FS_MyGeotab_Password' }
  # Normalise string inputs (trim spaces and surrounding quotes)
  $toNorm = @('EquipmentDomain','DefaultTimeZone','MyGeotabServer','MyGeotabDatabase','MyGeotabUsername','MyGeotabPassword')
  foreach ($n in $toNorm) {
    $v = Get-Variable -Name $n -Scope Script -ErrorAction SilentlyContinue
    if ($v -and $v.Value -is [string]) {
      $nv = $v.Value.Trim().Trim('"').Trim("'")
      Set-Variable -Name $n -Scope Script -Value $nv
    }
  }

  if ([string]::IsNullOrWhiteSpace($script:EquipmentDomain)) { throw "FS_Equipment_Domain missing" }
  if ([string]::IsNullOrWhiteSpace($script:MyGeotabDatabase)) { throw "FS_MyGeotab_Database missing" }
  if ([string]::IsNullOrWhiteSpace($script:MyGeotabUsername)) { throw "FS_MyGeotab_Username missing" }
  if ([string]::IsNullOrWhiteSpace($script:MyGeotabPassword)) { throw "FS_MyGeotab_Password missing" }
}

function Invoke-GeotabRequest {
  param(
    [string]$Uri,
    [string]$MethodName,
    [hashtable]$Params
  )
  $payload = @{ method = $MethodName; params = $Params } | ConvertTo-Json -Depth 8
  $resp = Invoke-RestMethod -Uri $Uri -Method Post -ContentType 'application/json' -Body $payload -ErrorAction Stop
  if ($resp | Get-Member -Name 'result' -MemberType NoteProperty) { return $resp.result }
  return $resp
}

function Get-GeotabDevices {
  # Authenticate (stage 1): use global login server to discover data server
  # Determine base host for discovery
  $baseHost = if ($script:MyGeotabServer) { $script:MyGeotabServer } else { 'my.geotab.com' }
  $base = "https://$baseHost/apiv1"
  $auth1 = Invoke-GeotabRequest -Uri $base -MethodName 'Authenticate' -Params @{ userName=$script:MyGeotabUsername; password=$script:MyGeotabPassword; database=$script:MyGeotabDatabase }

  # Resolve the data server host (Authenticate 'path' can be 'thisserver')
  $serverHost = $baseHost
  if ($auth1 -and ($auth1 | Get-Member -Name 'path' -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
    $p = [string]$auth1.path
    if (-not [string]::IsNullOrWhiteSpace($p)) {
      $pl = $p.ToLowerInvariant()
      if ($pl -eq 'thisserver' -or $pl -eq 'this server') { $serverHost = $baseHost }
      else {
        try { if ($p -match '^https?://') { $serverHost = ([uri]$p).Host } else { $serverHost = $p } } catch { $serverHost = $baseHost }
      }
    }
  }
  if ([string]::IsNullOrWhiteSpace($serverHost)) { throw "Could not resolve MyGeotab data server" }
  $uri = "https://$serverHost/apiv1"
  Write-Output "MyGeotab data server: $serverHost"

  # Authenticate (stage 2): credentials on data server
  $auth2 = Invoke-GeotabRequest -Uri $uri -MethodName 'Authenticate' -Params @{ userName=$script:MyGeotabUsername; password=$script:MyGeotabPassword; database=$script:MyGeotabDatabase }
  $credentials = $auth2.credentials
  if (-not $credentials) { throw "MyGeotab authentication failed" }

  # Get devices
  $devices = Invoke-GeotabRequest -Uri $uri -MethodName 'Get' -Params @{ typeName = 'Device'; search = @{ } ; credentials = $credentials }

  # Get property catalogue to resolve custom property IDs -> names
  $propNameMap = @{}
  try {
    $props = Invoke-GeotabRequest -Uri $uri -MethodName 'Get' -Params @{ typeName = 'Property'; search = @{ } ; credentials = $credentials }
    if ($props) {
      foreach ($p in $props) {
        $id = $null; $name = $null
        if ($p.PSObject.Properties.Name -contains 'id')   { $id = [string]$p.id }
        if ($p.PSObject.Properties.Name -contains 'name') { $name = [string]$p.name }
        if ($id -and $name) { $propNameMap[$id] = $name }
      }
    }
  } catch {}

  # Normalise fields with best-effort mapping (prefer custom property names discovered above)
  return $devices | ForEach-Object {
    $lic = Get-IfPresent -Obj $_ -Names @('licensePlate','licencePlate','registration','rego')
    $state = Get-IfPresent -Obj $_ -Names @('state','province','stateOrProvince')
    $atype = Get-IfPresent -Obj $_ -Names @('assetType','type','vehicleType','category')
    $timeZone = Get-IfPresent -Obj $_ -Names @('timeZone','timeZoneId','timezoneId','timeZoneName')
    $workHours = Get-IfPresent -Obj $_ -Names @('workTime','workHours','workingHours','hoursOfOperation','workSchedule','WorkTimeStandardHoursId','workTimeStandardHoursId')

    # Resolve custom properties into Name/Value pairs
    $rawCp = $null
    if ($_.PSObject.Properties.Name -contains 'customProperties') { $rawCp = $_.customProperties }
    elseif ($_.PSObject.Properties.Name -contains 'CustomProperties') { $rawCp = $_.CustomProperties }
    $cpDetailed = @()
    if ($rawCp) {
      foreach ($cp in $rawCp) {
        $nm = $null
        if ($cp.PSObject.Properties.Name -contains 'name' -and $cp.name) { $nm = [string]$cp.name }
        elseif ($cp.PSObject.Properties.Name -contains 'property' -and $cp.property) {
          if ($cp.property.PSObject.Properties.Name -contains 'name' -and $cp.property.name) { $nm = [string]$cp.property.name }
          elseif ($cp.property.PSObject.Properties.Name -contains 'id' -and $cp.property.id -and $propNameMap.ContainsKey([string]$cp.property.id)) { $nm = [string]$propNameMap[[string]$cp.property.id] }
        }
        if (-not $nm -and ($cp.PSObject.Properties.Name -contains 'id') -and $cp.id -and $propNameMap.ContainsKey([string]$cp.id)) { $nm = [string]$propNameMap[[string]$cp.id] }
        $cpDetailed += [pscustomobject]@{ Id=$cp.id; Name=$nm; Value=$cp.value }
      }
    }

    function Get-CPVal { param([string[]]$Names) foreach ($n in $Names) { $hit = $cpDetailed | Where-Object { $_.Name -and ($_.Name -ieq $n) } | Select-Object -First 1; if ($hit) { return $hit.Value } } return $null }

    # Preferred extraction from custom properties by friendly names
    $bookFromCP           = Get-CPVal @('Enable Equipment Booking','Is this a bookable resource','Is this a bookable recource','Bookable','Bookable resource','IsBookable')
    $recurringFromCP      = Get-CPVal @('Allow Recurring Bookings','Allow Recurring Booking','AllowRecurringBooking','Allow recurring bookings','Allow recurring booking','AllowRecurringMeetings','Allow recurring meetings')
    $approversFromCP      = Get-CPVal @('Booking Approvers','Approvers','Approver Emails','Approver Email','ApproverEmail','ApproverEmail(s)','Approver(s)')
    $fleetManagersFromCP  = Get-CPVal @('Fleet Managers','FleetManagers','Fleet Manager','FleetManager')
    $allowConflictsFromCP = Get-CPVal @('Allow Double Booking','AllowDoubleBooking','Allow Conflicts','AllowConflicts','Allow double booking')
    $bookingWindowFromCP  = Get-CPVal @('Booking Window (Days)','BookingWindowInDays','Booking Window','BookingWindow','Booking window')
    $maxDurationFromCP    = Get-CPVal @('Maximum Booking Duration (Hours)','MaximumDurationInHours','Maximum Duration','MaxDuration','Max Duration')
    $mailboxLangFromCP    = Get-CPVal @('Mailbox Language','MailboxLanguage','Language')

    # Fallbacks from direct device fields if not present in custom properties
    $book  = $bookFromCP
    if ($null -eq $book) { $book  = Get-IfPresent -Obj $_ -Names @('bookable','isBookable','Bookable','IsBookable') }

    # Normalise Bookable to Boolean
    # IMPORTANT: Default to FALSE when null for safety (devices must explicitly opt-in to booking)
    if ($null -ne $book) {
      if ($book -is [bool]) { $book = [bool]$book }
      elseif ($book -is [int]) { $book = ($book -ne 0) }
      else { $s=[string]$book; $s=$s.Trim().ToLowerInvariant(); $book = ($s -in @('true','1','on','yes','y')) }
      Write-Output "Device '$($_.name)' - Bookable property set to: $book"
    } else {
      $book = $false  # Default to NOT bookable when property is not set
      Write-Output "Device '$($_.name)' - Bookable property not set, defaulting to: FALSE (not bookable)"
    }

    # Normalise Recurring to Boolean
    $recurring = $null
    if ($null -ne $recurringFromCP) {
      if ($recurringFromCP -is [bool]) { $recurring = [bool]$recurringFromCP }
      elseif ($recurringFromCP -is [int]) { $recurring = ($recurringFromCP -ne 0) }
      else { $rs=[string]$recurringFromCP; $rs=$rs.Trim().ToLowerInvariant(); $recurring = ($rs -in @('true','1','on','yes','y')) }
    }

    # Parse Approvers into an array of emails when present
    $approvers = @()
    if ($null -ne $approversFromCP) {
      if ($approversFromCP -is [string]) { $approvers = ($approversFromCP -split '[,;]') | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
      elseif ($approversFromCP -is [System.Collections.IEnumerable]) { $approvers = @(); foreach ($a in $approversFromCP) { if ($a) { $approvers += [string]$a } } }
      else { $approvers = @([string]$approversFromCP) }
    }

    # Parse Fleet Managers into an array of emails when present
    $fleetManagers = @()
    if ($null -ne $fleetManagersFromCP) {
      if ($fleetManagersFromCP -is [string]) { $fleetManagers = ($fleetManagersFromCP -split '[,;]') | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
      elseif ($fleetManagersFromCP -is [System.Collections.IEnumerable]) { $fleetManagers = @(); foreach ($fm in $fleetManagersFromCP) { if ($fm) { $fleetManagers += [string]$fm } } }
      else { $fleetManagers = @([string]$fleetManagersFromCP) }
    }

    # Normalise AllowConflicts to Boolean
    $allowConflicts = $false
    if ($null -ne $allowConflictsFromCP) {
      if ($allowConflictsFromCP -is [bool]) { $allowConflicts = [bool]$allowConflictsFromCP }
      elseif ($allowConflictsFromCP -is [int]) { $allowConflicts = ($allowConflictsFromCP -ne 0) }
      else { $acs=[string]$allowConflictsFromCP; $acs=$acs.Trim().ToLowerInvariant(); $allowConflicts = ($acs -in @('true','1','on','yes','y')) }
    }

    # Normalise BookingWindow to Integer with default 90 days (blank = use default)
    $bookingWindow = 90
    if ($null -ne $bookingWindowFromCP -and -not [string]::IsNullOrWhiteSpace($bookingWindowFromCP)) {
      if ($bookingWindowFromCP -is [int]) { $bookingWindow = [int]$bookingWindowFromCP }
      elseif ($bookingWindowFromCP -is [string]) {
        $bws = $bookingWindowFromCP.Trim()
        if ($bws -match '^\d+$') { $bookingWindow = [int]$bws }
      }
    }
    if ($bookingWindow -lt 1) { $bookingWindow = 90 }

    # Normalise MaximumDuration to Integer (hours) with default 24 hours (blank = use default)
    $maxDurationHours = 24
    if ($null -ne $maxDurationFromCP -and -not [string]::IsNullOrWhiteSpace($maxDurationFromCP)) {
      if ($maxDurationFromCP -is [int]) { $maxDurationHours = [int]$maxDurationFromCP }
      elseif ($maxDurationFromCP -is [string]) {
        $mds = $maxDurationFromCP.Trim()
        if ($mds -match '^\d+$') { $maxDurationHours = [int]$mds }
      }
    }
    if ($maxDurationHours -lt 1) { $maxDurationHours = 24 }
    $maxDurationMinutes = $maxDurationHours * 60

    # Mailbox Language with default en-AU
    $mailboxLanguage = if ($null -ne $mailboxLangFromCP -and -not [string]::IsNullOrWhiteSpace($mailboxLangFromCP)) { $mailboxLangFromCP } else { 'en-AU' }

    [pscustomobject]@{
      Id                      = $_.id
      Name                    = $_.name
      SerialNumber            = $_.serialNumber
      VIN                     = $_.vehicleIdentificationNumber
      LicensePlate            = $lic
      StateOrProvince         = $state
      AssetType               = $atype
      Bookable                = $book
      TimeZone                = $timeZone
      WorkHours               = $workHours
      RecurringAllowed        = $recurring
      Approvers               = $approvers
      FleetManagers           = $fleetManagers
      AllowConflicts          = $allowConflicts
      BookingWindowInDays     = $bookingWindow
      MaximumDurationInMinutes = $maxDurationMinutes
      MailboxLanguage         = $mailboxLanguage
    }
  }
}

function Test-MailboxExists {
  param([string]$Identity)
  $mbx = Get-EXOMailbox -Identity $Identity -ErrorAction SilentlyContinue
  if (-not $mbx -and (Has-Cmd 'Get-Mailbox')) { $mbx = Get-Mailbox -Identity $Identity -ErrorAction SilentlyContinue }
  return [bool]$mbx
}

function New-EquipmentMailboxIfMissing {
  param(
    [string]$Alias,
    [string]$PrimarySmtpAddress,
    [string]$DisplayName,
    [string]$VIN,
    [string]$LicensePlate,
    [string]$StateOrProvince,
    [string]$AssetType,
    [object]$Bookable,
    [string]$TimeZone,
    [object]$WorkHours,
    [object]$RecurringAllowed,
    [string[]]$Approvers,
    [string[]]$FleetManagers,
    [object]$AllowConflicts,
    [int]$BookingWindowInDays = 90,
    [int]$MaximumDurationInMinutes = 1440,
    [string]$MailboxLanguage = 'en-AU'
  )
  # Update-only: find an existing mailbox by Primary SMTP or Alias
  $mbx = Find-EquipmentMailbox -PrimarySmtpAddress $PrimarySmtpAddress -Alias $Alias
  if (-not $mbx) {
    Write-Output "Find-EquipmentMailbox: not found after attempts. primary=$PrimarySmtpAddress alias=$Alias"
    Write-Output "Mailbox not found for $PrimarySmtpAddress (alias: $Alias). Skipping (no creation)."
    return
  }
  Write-Output "Updating equipment mailbox: $DisplayName <$PrimarySmtpAddress>"

  # Keep visible in GAL
  try { Set-Mailbox -Identity $mbx.Identity -HiddenFromAddressListsEnabled:$false } catch { Write-Warning "Could not update GAL visibility: $($_.Exception.Message)" }

  # DisplayName and Alias
  if ($DisplayName) { try { Set-Mailbox -Identity $mbx.Identity -DisplayName $DisplayName } catch { Write-Warning "Could not set DisplayName: $($_.Exception.Message)" } }
  if ($Alias -and $mbx.Alias -ne $Alias) { try { Set-Mailbox -Identity $mbx.Identity -Alias $Alias } catch { Write-Warning "Could not set Alias: $($_.Exception.Message)" } }

  # Enforce primary SMTP = serial@domain
  if ($PrimarySmtpAddress -and ($mbx.PrimarySmtpAddress -ne $PrimarySmtpAddress)) {
    try { Set-Mailbox -Identity $mbx.Identity -PrimarySmtpAddress $PrimarySmtpAddress } catch { Write-Warning "Could not set PrimarySmtpAddress: $($_.Exception.Message)" }
  }

  # Time zone and regional settings
  $tzWin = if ($TimeZone) { Convert-ToWindowsTimeZone -TimeZone $TimeZone } else { $script:DefaultTimeZone }
  $lang = if ($MailboxLanguage) { $MailboxLanguage } else { 'en-AU' }
  try { Set-MailboxRegionalConfiguration -Identity $mbx.Identity -TimeZone $tzWin -Language $lang } catch { Write-Warning "Could not set regional configuration: $($_.Exception.Message)" }
  $workProfile = Resolve-WorkingHoursProfile -WorkHours $WorkHours
  $scheduleOnly = [bool]$workProfile

  # Recurring meetings and approvers
  $allowRecurring = $false
  if ($null -ne $RecurringAllowed) {
    if ($RecurringAllowed -is [bool]) { $allowRecurring = [bool]$RecurringAllowed }
    elseif ($RecurringAllowed -is [int]) { $allowRecurring = ($RecurringAllowed -ne 0) }
    else { $rs=[string]$RecurringAllowed; $rs=$rs.Trim().ToLowerInvariant(); $allowRecurring = ($rs -in @('true','1','on','yes','y')) }
  }
  $delegates = @()
  if ($Approvers) {
    if ($Approvers -is [string]) { $delegates = ($Approvers -split '[,;]') | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
    elseif ($Approvers -is [System.Collections.IEnumerable]) { foreach ($a in $Approvers) { if ($a) { $delegates += [string]$a } } }
  }


  # Normalise AllowConflicts to Boolean
  $allowConflictsBool = $false
  if ($null -ne $AllowConflicts) {
    if ($AllowConflicts -is [bool]) { $allowConflictsBool = [bool]$AllowConflicts }
    elseif ($AllowConflicts -is [int]) { $allowConflictsBool = ($AllowConflicts -ne 0) }
    else { $acs=[string]$AllowConflicts; $acs=$acs.Trim().ToLowerInvariant(); $allowConflictsBool = ($acs -in @('true','1','on','yes','y')) }
  }

  # Additional response message (applies to ALL responses: accepted, declined, tentative)
  # Keep it neutral since Exchange doesn't support different messages for different statuses
  $responseMessage = @"
IMPORTANT: Check the meeting status in your calendar:
- ACCEPTED = Equipment is reserved for you
- DECLINED = Equipment is NOT available - DELETE this calendar entry immediately
- TENTATIVE = Awaiting approval from fleet manager

Always cancel bookings you no longer need so others can use the equipment.
"@

  # Check Bookable flag FIRST: disable booking when Off/False/0
  $isBookable = $true  # Default to bookable if not specified
  if ($null -ne $Bookable) {
    $b = $Bookable
    if ($b -is [string]) {
      $s = $b.Trim().ToLowerInvariant()
      if ($s -eq 'true' -or $s -eq 'on' -or $s -eq '1') { $b = $true }
      elseif ($s -eq 'false' -or $s -eq 'off' -or $s -eq '0') { $b = $false }
    }
    $isBookable = [bool]$b
  }

  if (-not $isBookable) {
    # Asset is marked as NOT bookable - disable all booking functionality
    Write-Output "Bookable = Off: disabling booking for $PrimarySmtpAddress"
    try {
      Set-CalendarProcessing -Identity $mbx.Identity `
        -AutomateProcessing None `
        -AllBookInPolicy:$false `
        -AllRequestInPolicy:$false `
        -EnforceSchedulingHorizon:$true `
        -BookingWindowInDays 0
    } catch { Write-Warning "Could not disable bookings: $($_.Exception.Message)" }
  } else {
    # Asset is bookable - apply normal booking rules
    Write-Output "Bookable = On: enabling booking for $PrimarySmtpAddress"

    # Booking rules (using custom property values)
    try {
      Set-CalendarProcessing -Identity $mbx.Identity `
        -AutomateProcessing AutoAccept `
        -AllBookInPolicy:$true `
        -AllRequestInPolicy:$false `
        -AllowConflicts:$allowConflictsBool `
        -ConflictPercentageAllowed 0 `
        -MaximumConflictInstances 0 `
        -BookingWindowInDays $BookingWindowInDays `
        -MaximumDurationInMinutes $MaximumDurationInMinutes `
        -AllowRecurringMeetings:$allowRecurring `
        -AddAdditionalResponse:$true `
        -AdditionalResponse $responseMessage `
        -DeleteComments:$false `
        -DeleteSubject:$false `
        -RemovePrivateProperty:$true `
        -AddOrganizerToSubject:$true `
        -EnforceCapacity:$true `
        -EnforceSchedulingHorizon:$true `
        -ScheduleOnlyDuringWorkHours:$scheduleOnly
    } catch { Write-Warning "Could not apply booking defaults: $($_.Exception.Message)" }

    # Apply approvers as ResourceDelegates and require approval if provided; clear when none
    if ($delegates -and $delegates.Count -gt 0) {
      try {
        Set-CalendarProcessing -Identity $mbx.Identity -ResourceDelegates $delegates -AllRequestInPolicy:$true -AllBookInPolicy:$false
      } catch { Write-Warning "Could not set ResourceDelegates for ${PrimarySmtpAddress}: $($_.Exception.Message)" }
    } else {
      try {
        Set-CalendarProcessing -Identity $mbx.Identity -ResourceDelegates $null -AllRequestInPolicy:$false -AllBookInPolicy:$true
      } catch { Write-Warning "Could not clear ResourceDelegates for ${PrimarySmtpAddress}: $($_.Exception.Message)" }
    }
  }


  # Working hours: from MyGeotab if available; else sensible default
  if ($workProfile) {
    try { Set-MailboxCalendarConfiguration -Identity $mbx.Identity -WorkingHoursStartTime $workProfile.Start -WorkingHoursEndTime $workProfile.End -WorkingHoursTimeZone $tzWin -WorkDays $workProfile.Days } catch { Write-Warning "Could not set working hours (profile): $($_.Exception.Message)" }
  } else {
    try { Set-MailboxCalendarConfiguration -Identity $mbx.Identity -WorkingHoursStartTime '09:00:00' -WorkingHoursEndTime '17:00:00' -WorkingHoursTimeZone $tzWin -WorkDays @('Monday','Tuesday','Wednesday','Thursday','Friday') } catch { Write-Warning "Could not set working hours (default): $($_.Exception.Message)" }
  }

  # Directory standard properties
  if ($StateOrProvince) {
    try { Set-User -Identity $mbx.Identity -StateOrProvince $StateOrProvince } catch { Write-Warning "Could not set State/Province: $($_.Exception.Message)" }
  }

  # Custom attributes mapping
  $cust = @{}
  if ($VIN)                { $cust['CustomAttribute1'] = $VIN }
  if ($LicensePlate)       { $cust['CustomAttribute2'] = $LicensePlate }
  if ($AssetType)          { $cust['CustomAttribute3'] = $AssetType }
  if ($null -ne $Bookable) {
    $b = $Bookable
    if ($b -is [string]) { $s=$b.Trim().ToLowerInvariant(); if ($s -eq 'true' -or $s -eq 'on' -or $s -eq '1') { $b=$true } elseif ($s -eq 'false' -or $s -eq 'off' -or $s -eq '0') { $b=$false } }
    $cust['CustomAttribute6'] = ($(if($b){'On'}else{'Off'}))
  }
  if ($cust.Count -gt 0) {
    try { Set-Mailbox -Identity $mbx.Identity @cust | Out-Null } catch { Write-Warning "Could not set custom attributes: $($_.Exception.Message)" }
  }

  # Grant Fleet Managers calendar Editor access
  if ($FleetManagers -and $FleetManagers.Count -gt 0) {
    $psmtp = if ($PrimarySmtpAddress) { $PrimarySmtpAddress } else { [string]$mbx.PrimarySmtpAddress }
    $calendarPath = "${psmtp}:\Calendar"
    foreach ($fm in $FleetManagers) {
      if ([string]::IsNullOrWhiteSpace($fm)) { continue }
      try {
        $perm = Get-MailboxFolderPermission -Identity $calendarPath -User $fm -ErrorAction SilentlyContinue
        if (-not $perm) {
          Add-MailboxFolderPermission -Identity $calendarPath -User $fm -AccessRights Editor -ErrorAction Stop
          Write-Output "Granted calendar Editor rights to Fleet Manager: $fm"
        } else {
          Write-Output "Fleet Manager $fm already has calendar access."
        }
      } catch {
        Write-Warning "Could not grant calendar access to Fleet Manager ${fm}: $($_.Exception.Message)"
      }
    }
  }

  # Default calendar visibility = AvailabilityOnly
  $psmtp = if ($PrimarySmtpAddress) { $PrimarySmtpAddress } else { [string]$mbx.PrimarySmtpAddress }

  # Default calendar visibility = AvailabilityOnly via Microsoft Graph
  if (Has-Cmd 'Connect-MgGraph' -and (Has-Cmd 'Get-MgUserCalendarPermission') -and (Has-Cmd 'Update-MgUserCalendarPermission')) {
    $ok = Set-DefaultCalendarPermission-Graph -UserUpn $psmtp -Role 'freeBusyRead'
    if (-not $ok) { Write-Warning "Graph: Default calendar permission not updated for $psmtp" }
  } else {
    Write-Warning "Graph cmdlets not available; skipping Default calendar permission configuration for $psmtp."
  }

  Write-Output "Updated: $PrimarySmtpAddress"
}

# MAIN
Get-Config
Ensure-ExchangeOnline
try {
  $devices = Get-GeotabDevices
  if ($MaxDevices -gt 0) { $devices = $devices | Select-Object -First $MaxDevices }
  $count = 0
  foreach ($d in $devices) {
    if ([string]::IsNullOrWhiteSpace($d.SerialNumber)) { continue }
    $alias = $d.SerialNumber.ToLowerInvariant()
    $email = "$alias@$($script:EquipmentDomain)"
    $display = if ($d.Name) { $d.Name } else { "Equipment $alias" }
    New-EquipmentMailboxIfMissing -Alias $alias -PrimarySmtpAddress $email -DisplayName $display -VIN $d.VIN -LicensePlate $d.LicensePlate -StateOrProvince $d.StateOrProvince -AssetType $d.AssetType -Bookable $d.Bookable -AssetStoredLocation $d.AssetStoredLocation -PlantNo $d.PlantNo -YearPurchased $d.YearPurchased -TimeZone $d.TimeZone -WorkHours $d.WorkHours -RecurringAllowed $d.RecurringAllowed -Approvers $d.Approvers -FleetManagers $d.FleetManagers -AllowConflicts $d.AllowConflicts -BookingWindowInDays $d.BookingWindowInDays -MaximumDurationInMinutes $d.MaximumDurationInMinutes -EquipmentCategory $d.EquipmentCategory -MailboxLanguage $d.MailboxLanguage
    $count++
  }
  Write-Output "Processed $count device(s)."
} finally {
  Disconnect-ExchangeOnline -Confirm:$false
}

