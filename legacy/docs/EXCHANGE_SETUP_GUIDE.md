# FleetBridge Exchange Setup Guide

## Overview

FleetBridge uses Microsoft Graph API to manage equipment mailboxes, but requires special Exchange Online permissions to modify mailbox settings on resource/equipment mailboxes.

## Why Special Setup is Required

Microsoft Exchange Online has strict security restrictions on **equipment** and **resource** mailboxes. The Graph API `MailboxSettings.ReadWrite` permission alone is not sufficient - the application also needs the **ApplicationImpersonation** role in Exchange Online.

## One-Time Setup Required

Each client organization needs to grant FleetBridge the necessary Exchange permissions. This is a **one-time** configuration that takes ~3 minutes.

### Prerequisites

- Global Administrator or Exchange Administrator role
- PowerShell 7+ installed
- Exchange Online PowerShell module

### Step 1: Install Exchange Online PowerShell (if not already installed)

```powershell
Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser
```

### Step 2: Connect to Exchange Online

```powershell
Connect-ExchangeOnline -UserPrincipalName admin@yourdomain.com
```

Sign in with your admin account when prompted.

### Step 3: Assign ApplicationImpersonation Role

This role allows FleetBridge to update mailbox settings on behalf of equipment mailboxes:

```powershell
$appId = "7eeb2358-00de-4da9-a6b7-8522b5353ade"

New-ManagementRoleAssignment `
    -Name "FleetBridge ApplicationImpersonation" `
    -Role "ApplicationImpersonation" `
    -ServiceId $appId
```

**Optional - Scope to Equipment Mailboxes Only (Recommended for Security)**:

```powershell
# Create a scope for equipment mailboxes only
New-ManagementScope `
    -Name "Equipment Mailboxes Only" `
    -RecipientRestrictionFilter {RecipientTypeDetails -eq "EquipmentMailbox"}

# Assign the role with the scope
New-ManagementRoleAssignment `
    -Name "FleetBridge ApplicationImpersonation - Equipment Only" `
    -Role "ApplicationImpersonation" `
    -ServiceId $appId `
    -CustomRecipientWriteScope "Equipment Mailboxes Only"
```

### Step 4: Create Application Access Policy

Replace `yourdomain.com` with your organization's email domain:

```powershell
New-ApplicationAccessPolicy `
    -AppId '7eeb2358-00de-4da9-a6b7-8522b5353ade' `
    -PolicyScopeGroupId '*@yourdomain.com' `
    -AccessRight RestrictAccess `
    -Description 'FleetBridge SaaS - Equipment Mailbox Management'
```

**Example for Garage of Awesome:**
```powershell
New-ApplicationAccessPolicy `
    -AppId '7eeb2358-00de-4da9-a6b7-8522b5353ade' `
    -PolicyScopeGroupId '*@garageofawesome.com.au' `
    -AccessRight RestrictAccess `
    -Description 'FleetBridge SaaS - Equipment Mailbox Management'
```

### Step 5: Verify the Role Assignment

```powershell
# Check the ApplicationImpersonation role was assigned
Get-ManagementRoleAssignment | Where-Object {$_.RoleAssigneeName -like "*7eeb2358*"}
```

You should see:
```
Name                                   Role                       RoleAssigneeType
----                                   ----                       ----------------
FleetBridge ApplicationImpersonation   ApplicationImpersonation   ServicePrincipal
```

### Step 6: Test the Policy

Test against one of your equipment mailboxes:

```powershell
Test-ApplicationAccessPolicy `
    -Identity 'equipmentmailbox@yourdomain.com' `
    -AppId '7eeb2358-00de-4da9-a6b7-8522b5353ade'
```

You should see:
```
AccessCheckResult : Granted
```

### Step 7: Disconnect

```powershell
Disconnect-ExchangeOnline
```

## What Does This Grant?

The Application Access Policy grants FleetBridge permission to:
- ✅ Read and update mailbox settings (timezone, language, regional settings)
- ✅ Read and update calendar properties
- ✅ Access equipment/resource mailboxes in your organization
- ❌ **Does NOT** grant access to user mailboxes (only equipment mailboxes)
- ❌ **Does NOT** grant access to email content

## Security Considerations

1. **Scope**: The policy applies only to mailboxes matching `*@yourdomain.com`
2. **App Identity**: Only the FleetBridge app (ID: `7eeb2358-00de-4da9-a6b7-8522b5353ade`) can use this access
3. **Certificate Auth**: FleetBridge uses certificate-based authentication (more secure than passwords)
4. **Audit Trail**: All access is logged in your Exchange audit logs

## Verification

After setup, you can verify the policy exists:

```powershell
Connect-ExchangeOnline
Get-ApplicationAccessPolicy | Where-Object { $_.AppId -eq '7eeb2358-00de-4da9-a6b7-8522b5353ade' }
```

## Troubleshooting

### Policy Already Exists
If you see "A security object with the specified AppId already exists", the policy is already configured. You can view it:

```powershell
Get-ApplicationAccessPolicy -AppId '7eeb2358-00de-4da9-a6b7-8522b5353ade'
```

### Access Still Denied
1. Wait 5-10 minutes for the policy to propagate
2. Restart the FleetBridge sync
3. Check that the equipment mailbox email matches your domain pattern

### Remove the Policy (if needed)
```powershell
Get-ApplicationAccessPolicy -AppId '7eeb2358-00de-4da9-a6b7-8522b5353ade' | Remove-ApplicationAccessPolicy -Confirm:$false
```

## Support

If you encounter issues:
1. Check the mailbox email address matches your domain
2. Verify the policy exists and shows "Granted" in the test
3. Contact FleetBridge support with:
   - Your organization domain
   - The test command output
   - Any error messages from the sync

---

**Note**: This setup is only required once per organization. Future updates and syncs will work automatically without additional Exchange configuration.
