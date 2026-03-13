# Modern Exchange RBAC Setup for FleetBridge SaaS

## Overview

FleetBridge SaaS now uses Microsoft's modern **Role Based Access Control (RBAC) for Applications in Exchange Online**. This replaces the legacy Application Access Policies and provides better security and tenant isolation.

## Important Changes

- **Legacy Application Access Policies are deprecated** and will be removed by Microsoft
- **New setup required** for all client tenants using modern RBAC
- **Better security** with granular equipment mailbox permissions
- **No changes** to your existing MyGeotab Add-In interface

## Benefits

- **Enhanced Security**: Granular permissions scoped to equipment mailboxes only
- **Better Isolation**: Each tenant manages their own permissions independently
- **Future-Proof**: Uses Microsoft's latest recommended approach
- **Improved Performance**: Faster permission resolution

## 📋 Prerequisites

**Exchange Administrator Role Required**
- The person performing this setup must have **Exchange Administrator** role in your Microsoft 365 tenant
- **Organization Management** role group membership is also sufficient

**Equipment Mailboxes**
- Equipment mailboxes must already exist in your tenant
- They should follow the naming pattern: `{serial}@{yourdomain}.com`

## Setup Instructions

### Step 1: Connect to Exchange Online PowerShell

```powershell
# Install the module (one-time)
Install-Module -Name ExchangeOnlineManagement -Force

# Connect to your Exchange Online
Connect-ExchangeOnline -UserPrincipalName your-admin@yourdomain.com
```

### Step 2: Create Service Principal

```powershell
# Create the FleetBridge service principal in your tenant
New-ServicePrincipal -AppId 7eeb2358-00de-4da9-a6b7-8522b5353ade -ObjectId 0b13a01b-d82d-4f52-99f2-4fa5c9e3b25c -DisplayName "FleetBridge SaaS"
```

**Expected Output:**
```
DisplayName     ObjectId                              AppId
-----------     --------                              -----
FleetBridge SaaS 0b13a01b-d82d-4f52-99f2-4fa5c9e3b25c 7eeb2358-00de-4da9-a6b7-8522b5353ade
```

### Step 3: Create Management Scope

```powershell
# Replace 'yourdomain.com' with your actual domain
New-ManagementScope -Name "FleetBridge Equipment Mailboxes" -RecipientRestrictionFilter "EmailAddresses -like '*@yourdomain.com' -and RecipientTypeDetails -eq 'EquipmentMailbox'"
```

### Step 4: Assign Application Role

```powershell
# Grant MailboxSettings.ReadWrite permission to FleetBridge
New-ManagementRoleAssignment -App 0b13a01b-d82d-4f52-99f2-4fa5c9e3b25c -Role "Application MailboxSettings.ReadWrite" -CustomResourceScope "FleetBridge Equipment Mailboxes"
```

### Step 5: Test the Setup

```powershell
# Test with one of your equipment mailboxes
Test-ServicePrincipalAuthorization -Identity "FleetBridge SaaS" -Resource "cy1b215b5229@yourdomain.com"
```

**Expected Output:**
```
RoleName                      GrantedPermissions          AllowedResourceScope        InScope 
--------                      ------------------          --------------------        -------
Application MailboxSettings.ReadWrite  MailboxSettings.ReadWrite   FleetBridge Equipment...    True
```

## Verification

### Verify Service Principal
```powershell
Get-ServicePrincipal "FleetBridge SaaS"
```

### Verify Management Scope
```powershell
Get-ManagementScope "FleetBridge Equipment Mailboxes"
```

### Verify Role Assignment
```powershell
Get-ManagementRoleAssignment -App "FleetBridge SaaS"
```

## Troubleshooting

### Common Issues

**"Service principal already exists"**
- This is normal if FleetBridge was previously configured
- Continue with Step 3

**"Management scope name already exists"**
- Use a different name: `"FleetBridge Equipment Mailboxes v2"`
- Or remove the existing scope: `Remove-ManagementScope "FleetBridge Equipment Mailboxes"`

**"No equipment mailboxes found"**
- Verify your domain name in the filter
- Check that equipment mailboxes exist: `Get-Mailbox -RecipientTypeDetails EquipmentMailbox`

### Getting Help

If you encounter issues:
1. Check the troubleshooting section above
2. Contact FleetBridge support with the error message
3. Include the output of: `Test-ServicePrincipalAuthorization -Identity "FleetBridge SaaS"`

## Migration from Legacy Setup

If you previously used Application Access Policies:

### Remove Legacy Policy
```powershell
# Find existing policies
Get-ApplicationAccessPolicy | Where-Object {$_.AppID -eq "7eeb2358-00de-4da9-a6b7-8522b5353ade"}

# Remove legacy policy (replace PolicyName with actual name)
Remove-ApplicationAccessPolicy -Identity "PolicyName"
```

### Clean Up Legacy Groups
```powershell
# Optional: Remove mail-enabled security groups created for old setup
# Get-DistributionGroup "FleetBridge-Equipment" | Remove-DistributionGroup
```

## What This Setup Provides

- **Mailbox Settings Access**: FleetBridge can update auto-accept settings
- **Calendar Access**: FleetBridge can manage booking windows
- **Equipment Mailbox Scope**: Only equipment mailboxes, not user mailboxes
- **Tenant Isolation**: Permissions limited to your tenant only

## Next Steps

1. **Complete this setup** with your Exchange Administrator
2. **Test equipment synchronization** in MyGeotab Add-In
3. **Verify booking functionality** works as expected
4. **Contact support** if you encounter any issues

---

**Support Contact**: support@fleetbridge.com  
**Documentation**: [FleetBridge Setup Guide](../README.md)