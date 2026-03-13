# FleetBridge Modern RBAC Setup Script
# This script sets up Exchange Online RBAC permissions for FleetBridge SaaS
# Run this as an Exchange Administrator in the client tenant
#
# STATUS: WAITING FOR EXCHANGE RBAC CMDLETS AVAILABILITY
# The required Exchange RBAC cmdlets (New-ServicePrincipal, New-ManagementRoleAssignment, etc.)
# are not yet available in Exchange Online PowerShell module v3.9.1 (including preview).
# Contact exoapprbacpreview@microsoft.com for preview access.
#
# This script is ready for execution once the cmdlets become available.

param(
    [Parameter(Mandatory=$true)]
    [string]$ClientDomain,
    
    [Parameter(Mandatory=$false)]
    [string]$EquipmentDomainFilter = $null,
    
    [Parameter(Mandatory=$false)]
    [switch]$RemoveLegacyPolicy,
    
    [Parameter(Mandatory=$false)]
    [switch]$TestOnly
)

# FleetBridge SaaS Application Details
$FleetBridgeAppId = "7eeb2358-00de-4da9-a6b7-8522b5353ade"
$FleetBridgeObjectId = "0b13a01b-d82d-4f52-99f2-4fa5c9e3b25c"
$FleetBridgeDisplayName = "FleetBridge SaaS"

Write-Host "🚀 FleetBridge Modern RBAC Setup" -ForegroundColor Green
Write-Host "=================================" -ForegroundColor Green
Write-Host "Client Domain: $ClientDomain" -ForegroundColor Yellow
Write-Host ""

# Check if connected to Exchange Online
try {
    $session = Get-ConnectionInformation -ErrorAction Stop
    if ($session.Count -eq 0) {
        throw "Not connected"
    }
    Write-Host "✅ Connected to Exchange Online" -ForegroundColor Green
} catch {
    Write-Host "❌ Not connected to Exchange Online" -ForegroundColor Red
    Write-Host "Please run: Connect-ExchangeOnline -UserPrincipalName admin@$ClientDomain" -ForegroundColor Yellow
    exit 1
}

# Determine equipment domain filter
if (-not $EquipmentDomainFilter) {
    $EquipmentDomainFilter = "*@$ClientDomain"
}

Write-Host "Equipment Filter: $EquipmentDomainFilter" -ForegroundColor Yellow
Write-Host ""

# Test mode - just show what would be done
if ($TestOnly) {
    Write-Host "🧪 TEST MODE - No changes will be made" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host "Would execute:"
    Write-Host "1. New-ServicePrincipal -AppId $FleetBridgeAppId -ObjectId $FleetBridgeObjectId -DisplayName '$FleetBridgeDisplayName'"
    Write-Host "2. New-ManagementScope -Name 'FleetBridge Equipment Mailboxes' -RecipientRestrictionFilter 'EmailAddresses -like `'$EquipmentDomainFilter`' -and RecipientTypeDetails -eq `'EquipmentMailbox`''"
    Write-Host "3. New-ManagementRoleAssignment -App $FleetBridgeObjectId -Role 'Application MailboxSettings.ReadWrite' -CustomResourceScope 'FleetBridge Equipment Mailboxes'"
    
    if ($RemoveLegacyPolicy) {
        Write-Host "4. Remove legacy Application Access Policies"
    }
    
    exit 0
}

Write-Host "🔧 Starting FleetBridge RBAC Setup..." -ForegroundColor Cyan
Write-Host ""

# Step 1: Create Service Principal
Write-Host "Step 1: Creating Service Principal..." -ForegroundColor Blue
try {
    $existingSP = Get-ServicePrincipal -Identity $FleetBridgeAppId -ErrorAction SilentlyContinue
    if ($existingSP) {
        Write-Host "✅ Service Principal already exists: $($existingSP.DisplayName)" -ForegroundColor Green
    } else {
        $sp = New-ServicePrincipal -AppId $FleetBridgeAppId -ObjectId $FleetBridgeObjectId -DisplayName $FleetBridgeDisplayName
        Write-Host "✅ Created Service Principal: $($sp.DisplayName)" -ForegroundColor Green
    }
} catch {
    Write-Host "❌ Failed to create Service Principal: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Step 2: Create Management Scope
Write-Host ""
Write-Host "Step 2: Creating Management Scope..." -ForegroundColor Blue
$scopeName = "FleetBridge Equipment Mailboxes"
$scopeFilter = "EmailAddresses -like '$EquipmentDomainFilter' -and RecipientTypeDetails -eq 'EquipmentMailbox'"

try {
    $existingScope = Get-ManagementScope -Identity $scopeName -ErrorAction SilentlyContinue
    if ($existingScope) {
        Write-Host "✅ Management Scope already exists: $scopeName" -ForegroundColor Green
        Write-Host "   Filter: $($existingScope.RecipientFilter)" -ForegroundColor Gray
    } else {
        $scope = New-ManagementScope -Name $scopeName -RecipientRestrictionFilter $scopeFilter
        Write-Host "✅ Created Management Scope: $scopeName" -ForegroundColor Green
        Write-Host "   Filter: $scopeFilter" -ForegroundColor Gray
    }
} catch {
    Write-Host "❌ Failed to create Management Scope: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Step 3: Create Role Assignment
Write-Host ""
Write-Host "Step 3: Creating Role Assignment..." -ForegroundColor Blue
try {
    $existingAssignment = Get-ManagementRoleAssignment -App $FleetBridgeAppId -ErrorAction SilentlyContinue | Where-Object {$_.Role -eq "Application MailboxSettings.ReadWrite"}
    if ($existingAssignment) {
        Write-Host "✅ Role Assignment already exists" -ForegroundColor Green
        Write-Host "   Role: $($existingAssignment.Role)" -ForegroundColor Gray
        Write-Host "   Scope: $($existingAssignment.CustomResourceScope)" -ForegroundColor Gray
    } else {
        $assignment = New-ManagementRoleAssignment -App $FleetBridgeObjectId -Role "Application MailboxSettings.ReadWrite" -CustomResourceScope $scopeName
        Write-Host "✅ Created Role Assignment" -ForegroundColor Green
        Write-Host "   Role: Application MailboxSettings.ReadWrite" -ForegroundColor Gray
        Write-Host "   Scope: $scopeName" -ForegroundColor Gray
    }
} catch {
    Write-Host "❌ Failed to create Role Assignment: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Step 4: Remove Legacy Policy (if requested)
if ($RemoveLegacyPolicy) {
    Write-Host ""
    Write-Host "Step 4: Removing Legacy Application Access Policy..." -ForegroundColor Blue
    try {
        $legacyPolicies = Get-ApplicationAccessPolicy | Where-Object {$_.AppID -eq $FleetBridgeAppId}
        if ($legacyPolicies) {
            foreach ($policy in $legacyPolicies) {
                Remove-ApplicationAccessPolicy -Identity $policy.Identity -Confirm:$false
                Write-Host "✅ Removed legacy policy: $($policy.Identity)" -ForegroundColor Green
            }
        } else {
            Write-Host "ℹ️  No legacy Application Access Policies found" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "⚠️  Failed to remove legacy policy: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "   This is not critical - you can remove it manually later" -ForegroundColor Gray
    }
}

# Step 5: Test the Setup
Write-Host ""
Write-Host "Step 5: Testing Configuration..." -ForegroundColor Blue

# Find equipment mailboxes to test with
try {
    $equipmentMailboxes = Get-Mailbox -RecipientTypeDetails EquipmentMailbox -ResultSize 5 | Where-Object {$_.EmailAddresses -like $EquipmentDomainFilter}
    
    if ($equipmentMailboxes.Count -eq 0) {
        Write-Host "⚠️  No equipment mailboxes found matching filter: $EquipmentDomainFilter" -ForegroundColor Yellow
        Write-Host "   Please verify equipment mailboxes exist and the domain is correct" -ForegroundColor Gray
    } else {
        Write-Host "✅ Found $($equipmentMailboxes.Count) equipment mailboxes" -ForegroundColor Green
        
        # Test with first mailbox
        $testMailbox = $equipmentMailboxes[0].PrimarySmtpAddress
        Write-Host "   Testing with: $testMailbox" -ForegroundColor Gray
        
        $testResult = Test-ServicePrincipalAuthorization -Identity $FleetBridgeDisplayName -Resource $testMailbox
        $mailboxPermission = $testResult | Where-Object {$_.RoleName -eq "Application MailboxSettings.ReadWrite"}
        
        if ($mailboxPermission -and $mailboxPermission.InScope -eq $true) {
            Write-Host "✅ Permissions test PASSED" -ForegroundColor Green
            Write-Host "   FleetBridge can access equipment mailbox settings" -ForegroundColor Gray
        } else {
            Write-Host "❌ Permissions test FAILED" -ForegroundColor Red
            Write-Host "   Check the configuration and try again" -ForegroundColor Gray
        }
    }
} catch {
    Write-Host "⚠️  Could not test configuration: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "🎉 FleetBridge RBAC Setup Complete!" -ForegroundColor Green
Write-Host "====================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "1. Test equipment synchronization in MyGeotab Add-In" -ForegroundColor White
Write-Host "2. Verify booking functionality works as expected" -ForegroundColor White
Write-Host "3. Contact FleetBridge support if you encounter issues" -ForegroundColor White
Write-Host ""
Write-Host "Support: support@fleetbridge.com" -ForegroundColor Cyan