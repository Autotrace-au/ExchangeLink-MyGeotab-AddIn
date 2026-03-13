# Assign ApplicationImpersonation Role to FleetBridge SaaS
# Run this script with Exchange Online Administrator permissions

param(
    [Parameter(Mandatory=$false)]
    [string]$OrganizationDomain = "garageofawesome.com.au"
)

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " FleetBridge ApplicationImpersonation Role Assignment" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host ""

# FleetBridge SaaS App ID
$appId = "7eeb2358-00de-4da9-a6b7-8522b5353ade"

Write-Host "This script will:" -ForegroundColor Yellow
Write-Host "  1. Connect to Exchange Online for $OrganizationDomain" -ForegroundColor Yellow
Write-Host "  2. Assign ApplicationImpersonation role to FleetBridge" -ForegroundColor Yellow
Write-Host "  3. Optionally scope the role to equipment mailboxes only" -ForegroundColor Yellow
Write-Host "  4. Test the configuration" -ForegroundColor Yellow
Write-Host ""

# Check if ExchangeOnlineManagement module is installed
if (!(Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Host "ExchangeOnlineManagement module not found. Installing..." -ForegroundColor Yellow
    Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser -Force
}

# Connect to Exchange Online
Write-Host "Step 1: Connecting to Exchange Online..." -ForegroundColor Green
Write-Host "Please sign in with an Exchange Administrator account" -ForegroundColor Gray
Connect-ExchangeOnline -Organization $OrganizationDomain -ShowBanner:$false

Write-Host "✓ Connected to Exchange Online" -ForegroundColor Green
Write-Host ""

# Check if role assignment already exists
Write-Host "Checking for existing role assignments..." -ForegroundColor Gray
$existingAssignment = Get-ManagementRoleAssignment -ErrorAction SilentlyContinue | Where-Object {
    $_.RoleAssigneeName -like "*$appId*" -and $_.Role -eq "ApplicationImpersonation"
}

if ($existingAssignment) {
    Write-Host "⚠ ApplicationImpersonation role already assigned:" -ForegroundColor Yellow
    $existingAssignment | Format-Table Name, Role, RoleAssigneeType -AutoSize
    
    $continue = Read-Host "Do you want to continue anyway? (y/N)"
    if ($continue -ne "y" -and $continue -ne "Y") {
        Write-Host "Exiting..." -ForegroundColor Gray
        Disconnect-ExchangeOnline -Confirm:$false
        exit
    }
}

Write-Host ""
Write-Host "Step 2: Assigning ApplicationImpersonation Role..." -ForegroundColor Green

# Ask if they want to scope to equipment mailboxes only
Write-Host ""
Write-Host "Security Options:" -ForegroundColor Cyan
Write-Host "  1. Scope to equipment mailboxes ONLY (Recommended - most secure)" -ForegroundColor White
Write-Host "  2. Grant access to ALL mailboxes (Less secure, but simpler)" -ForegroundColor White
Write-Host ""
$scopeChoice = Read-Host "Enter choice (1 or 2)"

if ($scopeChoice -eq "1") {
    Write-Host "Creating management scope for equipment mailboxes..." -ForegroundColor Gray
    
    # Check if scope already exists
    $existingScope = Get-ManagementScope -Identity "Equipment Mailboxes Only" -ErrorAction SilentlyContinue
    if (!$existingScope) {
        New-ManagementScope `
            -Name "Equipment Mailboxes Only" `
            -RecipientRestrictionFilter {RecipientTypeDetails -eq "EquipmentMailbox"}
        Write-Host "✓ Created management scope" -ForegroundColor Green
    } else {
        Write-Host "✓ Management scope already exists" -ForegroundColor Green
    }
    
    Write-Host "Assigning role with equipment mailbox scope..." -ForegroundColor Gray
    
    # Try using -App parameter (newer) or fall back to app ID directly
    try {
        New-ManagementRoleAssignment `
            -Name "FleetBridge ApplicationImpersonation - Equipment Only" `
            -Role "ApplicationImpersonation" `
            -App $appId `
            -CustomRecipientWriteScope "Equipment Mailboxes Only" `
            -ErrorAction Stop
        Write-Host "✓ ApplicationImpersonation role assigned (Equipment mailboxes only)" -ForegroundColor Green
    } catch {
        Write-Host "Trying alternative method..." -ForegroundColor Yellow
        # Alternative: Create with app ID in the name
        New-ManagementRoleAssignment `
            -Name "FleetBridge ApplicationImpersonation - Equipment Only" `
            -Role "ApplicationImpersonation" `
            -User $appId `
            -CustomRecipientWriteScope "Equipment Mailboxes Only"
        Write-Host "✓ ApplicationImpersonation role assigned (Equipment mailboxes only)" -ForegroundColor Green
    }
} else {
    Write-Host "Assigning role for all mailboxes..." -ForegroundColor Gray
    
    # Try using -App parameter (newer) or fall back to app ID directly
    try {
        New-ManagementRoleAssignment `
            -Name "FleetBridge ApplicationImpersonation" `
            -Role "ApplicationImpersonation" `
            -App $appId `
            -ErrorAction Stop
        Write-Host "✓ ApplicationImpersonation role assigned (All mailboxes)" -ForegroundColor Green
    } catch {
        Write-Host "Trying alternative method..." -ForegroundColor Yellow
        # Alternative: Create with app ID in the name
        New-ManagementRoleAssignment `
            -Name "FleetBridge ApplicationImpersonation" `
            -Role "ApplicationImpersonation" `
            -User $appId
        Write-Host "✓ ApplicationImpersonation role assigned (All mailboxes)" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Step 3: Verifying Role Assignment..." -ForegroundColor Green
$assignments = Get-ManagementRoleAssignment | Where-Object {
    $_.Name -like "FleetBridge*" -and $_.Role -eq "ApplicationImpersonation"
}

if ($assignments) {
    Write-Host "✓ Role assignment verified:" -ForegroundColor Green
    $assignments | Format-Table Name, Role, RoleAssigneeType, EffectiveUserName -AutoSize
} else {
    Write-Host "⚠ Checking all ApplicationImpersonation assignments..." -ForegroundColor Yellow
    $allAssignments = Get-ManagementRoleAssignment -Role "ApplicationImpersonation"
    if ($allAssignments) {
        $allAssignments | Format-Table Name, Role, RoleAssigneeType, EffectiveUserName -AutoSize
    } else {
        Write-Host "✗ No ApplicationImpersonation role assignments found!" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "Step 4: Testing Access (Optional)..." -ForegroundColor Green
$testMailbox = Read-Host "Enter an equipment mailbox email to test (or press Enter to skip)"

if ($testMailbox) {
    Write-Host "Testing access to $testMailbox..." -ForegroundColor Gray
    $testResult = Test-ApplicationAccessPolicy -Identity $testMailbox -AppId $appId
    
    if ($testResult.AccessCheckResult -eq "Granted") {
        Write-Host "✓ Access Test: GRANTED" -ForegroundColor Green
    } else {
        Write-Host "✗ Access Test: $($testResult.AccessCheckResult)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " Setup Complete!" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "FleetBridge can now update equipment mailbox settings." -ForegroundColor White
Write-Host "The application will use this permission to set:" -ForegroundColor White
Write-Host "  • Mailbox timezone" -ForegroundColor Gray
Write-Host "  • Mailbox language/locale" -ForegroundColor Gray
Write-Host "  • Display names" -ForegroundColor Gray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Test the sync in MyGeotab" -ForegroundColor White
Write-Host "  2. Monitor the first sync for any errors" -ForegroundColor White
Write-Host "  3. Verify timezone is correctly set on equipment mailboxes" -ForegroundColor White
Write-Host ""

# Disconnect
Write-Host "Disconnecting from Exchange Online..." -ForegroundColor Gray
Disconnect-ExchangeOnline -Confirm:$false
Write-Host "✓ Disconnected" -ForegroundColor Green
