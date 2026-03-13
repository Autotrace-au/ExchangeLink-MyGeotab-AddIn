# Exchange ApplicationImpersonation Setup for FleetBridge

## Problem
Even with Application Access Policy and Graph API permissions, updating mailbox settings (timezone, language) on equipment/resource mailboxes returns `ErrorAccessDenied`.

## Root Cause
Resource mailboxes require **ApplicationImpersonation** RBAC role in Exchange Online to modify settings, which is separate from Graph API permissions.

## Solution
Assign the ApplicationImpersonation role to the FleetBridge app's service principal in Exchange Online.

## Step 1: Connect to Exchange Online PowerShell

```powershell
# Install module if not already installed
Install-Module -Name ExchangeOnlineManagement -Force

# Connect to your Exchange Online tenant
Connect-ExchangeOnline -Organization garageofawesome.com.au
```

## Step 2: Find the Service Principal

```powershell
# The app ID for FleetBridge SaaS
$appId = "7eeb2358-00de-4da9-a6b7-8522b5353ade"

# In Exchange Online, service principals are referenced by their app ID
# We'll create a role assignment using the app ID as the assignee
```

## Step 3: Assign ApplicationImpersonation Role

```powershell
# Create a new management role assignment for the application
New-ManagementRoleAssignment `
    -Name "FleetBridge ApplicationImpersonation" `
    -Role "ApplicationImpersonation" `
    -ServiceId $appId

# Note: -ServiceId is used for service principals/applications
# For a specific user, you would use -User instead
```

## Step 4: Verify the Assignment

```powershell
# Check if the role was assigned
Get-ManagementRoleAssignment | Where-Object {
    $_.RoleAssigneeName -like "*$appId*" -or 
    $_.RoleAssigneeType -eq "ServicePrincipal"
}

# Should show:
# Name: FleetBridge ApplicationImpersonation
# Role: ApplicationImpersonation
# RoleAssigneeType: ServicePrincipal
```

## Step 5: Test Access (After Assignment)

```powershell
# Test that the app can access equipment mailboxes
Test-ApplicationAccessPolicy `
    -Identity "cy1b215b5229@garageofawesome.com.au" `
    -AppId $appId

# Should show: AccessCheckResult: Granted
```

## What This Enables

The ApplicationImpersonation role allows the FleetBridge application to:

1. **Read mailbox settings** for equipment mailboxes
2. **Update mailbox settings** (timezone, language, etc.)
3. **Access calendar events** on behalf of the mailbox
4. **Manage mailbox properties** that regular Graph API permissions can't modify

## Alternative: Scope to Specific Mailboxes

If you want to limit impersonation to only equipment mailboxes (recommended for security):

```powershell
# Create a management scope for equipment mailboxes
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

## Security Considerations

1. **Broad Access**: ApplicationImpersonation is a powerful role that grants access to ALL mailboxes (unless scoped)
2. **Recommended**: Use the scoped version (Equipment Mailboxes Only) to limit exposure
3. **Audit**: Monitor the app's usage through Exchange audit logs
4. **Certificate Auth**: The app already uses certificate-based authentication, which is more secure than client secrets

## Propagation Time

- Role assignments are typically effective immediately
- In some cases, it may take 5-15 minutes to propagate
- If access is still denied after 15 minutes, check the role assignment is correct

## Troubleshooting

### Still Getting ErrorAccessDenied After Assignment

1. **Verify the assignment exists**:
   ```powershell
   Get-ManagementRoleAssignment "FleetBridge ApplicationImpersonation"
   ```

2. **Check the service ID is correct**:
   ```powershell
   Get-MsolServicePrincipal -AppPrincipalId "7eeb2358-00de-4da9-a6b7-8522b5353ade"
   ```

3. **Ensure the app has been consented**:
   - Check in Entra ID → Enterprise Applications → FleetBridge SaaS
   - Admin consent should show: User.Read.All, Calendars.ReadWrite, MailboxSettings.ReadWrite

### Exchange Online Cmdlet Not Found

If `New-ManagementRoleAssignment -ServiceId` fails:

```powershell
# Alternative: Use the app's service principal name
$sp = Get-MsolServicePrincipal -AppPrincipalId $appId
New-ManagementRoleAssignment `
    -Name "FleetBridge ApplicationImpersonation" `
    -Role "ApplicationImpersonation" `
    -User $sp.DisplayName
```

## References

- [ApplicationImpersonation Role](https://learn.microsoft.com/en-us/exchange/client-developer/exchange-web-services/impersonation-and-ews-in-exchange)
- [Management Role Assignments](https://learn.microsoft.com/en-us/exchange/permissions-exo/permissions-exo)
- [Service Principal in Exchange Online](https://learn.microsoft.com/en-us/powershell/module/exchange/new-managementroleassignment)
