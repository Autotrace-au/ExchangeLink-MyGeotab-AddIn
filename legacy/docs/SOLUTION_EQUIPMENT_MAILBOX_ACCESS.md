# Equipment Mailbox Access - Complete Solution

## The Problem

When trying to update equipment/resource mailboxes in Exchange Online using Microsoft Graph API with the `MailboxSettings.ReadWrite` application permission, the API returns:

```
ErrorAccessDenied: Access is denied. Check credentials and try again.
```

This occurs even when:
- Application permissions are granted and admin consented
- Graph API can successfully find the mailbox
- An Application Access Policy exists in Exchange Online
- Certificate-based authentication is working

## Root Cause

**Equipment and resource mailboxes require the ApplicationImpersonation role in Exchange Online to modify mailbox settings**, which is a separate permission system from Microsoft Graph API.

### Why Graph API Alone Doesn't Work

1. **Graph API Permissions** (User.Read.All, MailboxSettings.ReadWrite, Calendars.ReadWrite) grant API-level access
2. **ApplicationImpersonation Role** grants Exchange-level access to impersonate mailboxes
3. Both are required for resource mailboxes - Graph API alone is insufficient

### Why EWS Doesn't Help

- Exchange Web Services (EWS) doesn't have an API for mailbox settings (timezone, language)
- Those settings are Outlook/OWA preferences, not EWS properties
- `account.default_timezone` in exchangelib is READ-ONLY (used by calendar items)
- The Graph API MailboxSettings endpoint is the ONLY way to modify these settings

## The Solution

Assign the **ApplicationImpersonation** role to the FleetBridge service principal in Exchange Online.

### Quick Setup (3 minutes)

```powershell
# 1. Connect to Exchange Online
Connect-ExchangeOnline -Organization yourdomain.com

# 2. Assign ApplicationImpersonation role
$appId = "7eeb2358-00de-4da9-a6b7-8522b5353ade"
New-ManagementRoleAssignment `
    -Name "FleetBridge ApplicationImpersonation" `
    -Role "ApplicationImpersonation" `
    -ServiceId $appId

# 3. Verify
Get-ManagementRoleAssignment | Where-Object {$_.RoleAssigneeName -like "*$appId*"}

# 4. Test (optional)
Test-ApplicationAccessPolicy `
    -Identity 'equipment@yourdomain.com' `
    -AppId $appId
```

### Automated Setup Script

Run the provided PowerShell script:

```powershell
./assign-impersonation-role.ps1 -OrganizationDomain garageofawesome.com.au
```

This script will:
1. Install Exchange Online Management module if needed
2. Connect to Exchange Online
3. Check for existing role assignments
4. Assign the ApplicationImpersonation role
5. Optionally scope to equipment mailboxes only (recommended)
6. Verify and test the configuration

## Security Considerations

### Option 1: Scoped to Equipment Mailboxes Only (Recommended)

Limits FleetBridge to only access equipment mailboxes:

```powershell
# Create scope
New-ManagementScope `
    -Name "Equipment Mailboxes Only" `
    -RecipientRestrictionFilter {RecipientTypeDetails -eq "EquipmentMailbox"}

# Assign with scope
New-ManagementRoleAssignment `
    -Name "FleetBridge ApplicationImpersonation - Equipment Only" `
    -Role "ApplicationImpersonation" `
    -ServiceId $appId `
    -CustomRecipientWriteScope "Equipment Mailboxes Only"
```

### Option 2: All Mailboxes

Grants access to all mailboxes (simpler but less secure):

```powershell
New-ManagementRoleAssignment `
    -Name "FleetBridge ApplicationImpersonation" `
    -Role "ApplicationImpersonation" `
    -ServiceId $appId
```

## What This Enables

With the ApplicationImpersonation role, FleetBridge can:

1. ✅ Update mailbox timezone
2. ✅ Update mailbox language/locale  
3. ✅ Update display names
4. ✅ Access calendar events
5. ✅ Manage equipment mailbox properties

## Propagation Time

- Role assignments are typically effective **immediately**
- In rare cases, may take 5-15 minutes
- If access denied after 15 minutes, verify the role assignment

## Testing

After assigning the role, test the endpoint:

```bash
curl "https://fleetbridge-mygeotab.azurewebsites.net/api/test-app-token?api_key=YOUR_API_KEY"
```

Expected result:
```json
{
  "success": true,
  "mailbox_found": true,
  "update_success": true,
  "mailbox_display_name": "2022 Race Trailer - Solar"
}
```

If `update_success` is still `false`, check:
1. Role assignment exists: `Get-ManagementRoleAssignment -Name "FleetBridge ApplicationImpersonation"`
2. Service ID matches: `7eeb2358-00de-4da9-a6b7-8522b5353ade`
3. Wait 15 minutes for propagation
4. Check Exchange audit logs for access denial details

## Technical Details

### Permission Layers Required

| Layer | Permission | Purpose |
|-------|-----------|---------|
| **Entra ID** | User.Read.All | Find mailboxes by email |
| **Entra ID** | MailboxSettings.ReadWrite | Graph API endpoint access |
| **Entra ID** | Calendars.ReadWrite | Calendar event management |
| **Exchange Online** | ApplicationImpersonation | Impersonate mailboxes to modify settings |
| **Exchange Online** | Application Access Policy | Scope access to specific domain |

All layers must be configured for mailbox updates to succeed on resource mailboxes.

### Why Resource Mailboxes Are Different

Microsoft Exchange treats equipment/resource mailboxes differently from user mailboxes:

| Mailbox Type | Graph API Only | Graph API + Impersonation |
|--------------|----------------|---------------------------|
| **User Mailbox** | ✅ Works | ✅ Works |
| **Equipment Mailbox** | ❌ ErrorAccessDenied | ✅ Works |
| **Resource Mailbox** | ❌ ErrorAccessDenied | ✅ Works |

This is by design - resource mailboxes represent shared resources (conference rooms, vehicles) rather than individual users, so they require administrative-level permissions.

## Client Onboarding Checklist

For each new FleetBridge client:

- [ ] Global/Exchange Admin access
- [ ] Install ExchangeOnlineManagement PowerShell module
- [ ] Run `assign-impersonation-role.ps1` script
- [ ] Choose scoped (equipment only) or full access
- [ ] Verify role assignment
- [ ] Test with sample equipment mailbox
- [ ] Complete OAuth consent in MyGeotab
- [ ] Test first sync
- [ ] Verify timezone/language updated correctly

## Troubleshooting

### "ServiceId parameter not recognized"

Some Exchange Online PowerShell versions don't support `-ServiceId`. Use:

```powershell
# Alternative method
$sp = Get-MsolServicePrincipal -AppPrincipalId $appId
New-ManagementRoleAssignment `
    -Name "FleetBridge ApplicationImpersonation" `
    -Role "ApplicationImpersonation" `
    -User $sp.DisplayName
```

### "Role assignment already exists"

Check existing assignments:

```powershell
Get-ManagementRoleAssignment | Where-Object {$_.Role -eq "ApplicationImpersonation"}
```

Remove old assignment if needed:

```powershell
Remove-ManagementRoleAssignment -Identity "FleetBridge ApplicationImpersonation" -Confirm:$false
```

### Still Getting ErrorAccessDenied

1. **Wait 15 minutes** for propagation
2. **Verify the role**:
   ```powershell
   Get-ManagementRoleAssignment -Name "FleetBridge ApplicationImpersonation" | Format-List
   ```
3. **Check service principal exists**:
   ```powershell
   Get-MsolServicePrincipal -AppPrincipalId "7eeb2358-00de-4da9-a6b7-8522b5353ade"
   ```
4. **Review Exchange audit logs**:
   ```powershell
   Search-UnifiedAuditLog -StartDate (Get-Date).AddHours(-2) -EndDate (Get-Date) -Operations "ApplicationAccessDenied"
   ```

## References

- [ApplicationImpersonation Role Documentation](https://learn.microsoft.com/en-us/exchange/client-developer/exchange-web-services/impersonation-and-ews-in-exchange)
- [Management Role Assignments](https://learn.microsoft.com/en-us/exchange/permissions-exo/permissions-exo)
- [Graph API MailboxSettings](https://learn.microsoft.com/en-us/graph/api/resources/mailboxsettings)
- [Service Principals in Exchange Online](https://learn.microsoft.com/en-us/powershell/module/exchange/new-managementroleassignment)
