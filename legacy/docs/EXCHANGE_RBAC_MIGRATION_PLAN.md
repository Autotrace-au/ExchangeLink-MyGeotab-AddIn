# Exchange RBAC Migration Plan for FleetSync

## Current Status

**Discovered**: Exchange RBAC for Applications is the modern replacement for Application Access Policies, but the required cmdlets are not yet available in the current Exchange Online PowerShell module, even in preview version 3.9.1.

**Root Cause of 403 Errors**: Our application is using deprecated Application Access Policies which have been replaced by the new Exchange RBAC system.

## Required Migration Steps

### Phase 1: Enable Exchange RBAC Preview (PENDING)

The Exchange RBAC feature appears to still be in limited preview. Required actions:

1. **Contact Microsoft Preview Program**
   - Email: `exoapprbacpreview@microsoft.com`
   - Request access to Exchange RBAC for Applications preview
   - Mention FleetSync application for equipment mailbox management

2. **Verify Preview Requirements**
   - Confirm licensing requirements
   - Check if additional tenant configuration needed
   - Validate Exchange Administrator permissions

### Phase 2: Implement Modern RBAC (Once Available)

#### Current Application Details
- **Service Principal**: `7eeb2358-00de-4da9-a6b7-8522b5353ade` (AppId)
- **Object ID**: `0b13a01b-d82d-4f52-99f2-4fa5c9e3b25c`
- **Required Permission**: `Application MailboxSettings.ReadWrite`
- **Current Scope**: Equipment mailboxes (Room/Equipment type)

#### Migration Script (Ready for Execution)
```powershell
# Connect to Exchange Online with preview module
Connect-ExchangeOnline -UserPrincipalName admin@garageofawesome.com.au

# 1. Create Service Principal pointer in Exchange
New-ServicePrincipal -AppId "7eeb2358-00de-4da9-a6b7-8522b5353ade" -ObjectId "0b13a01b-d82d-4f52-99f2-4fa5c9e3b25c" -DisplayName "FleetSync-MyGeotab"

# 2. Create Management Scope for Equipment Mailboxes
New-ManagementScope -Name "FleetSync-EquipmentMailboxes" -RecipientRestrictionFilter "RecipientTypeDetails -eq 'EquipmentMailbox'"

# 3. Assign MailboxSettings.ReadWrite role with scope
New-ManagementRoleAssignment -Role "Application MailboxSettings.ReadWrite" -App "7eeb2358-00de-4da9-a6b7-8522b5353ade" -CustomResourceScope "FleetSync-EquipmentMailboxes" -Name "FleetSync-EquipmentAccess"

# 4. Test the assignment
Test-ServicePrincipalAuthorization -Identity "7eeb2358-00de-4da9-a6b7-8522b5353ade"
```

#### Legacy Policy Cleanup
```powershell
# Remove old Application Access Policy (once new RBAC is working)
Get-ApplicationAccessPolicy | Where-Object {$_.AppId -eq "7eeb2358-00de-4da9-a6b7-8522b5353ade"} | Remove-ApplicationAccessPolicy
```

### Phase 3: Multi-Tenant Deployment Template

#### Automated Onboarding Script
Create `Setup-FleetBridge-ModernRBAC.ps1` for new clients:

```powershell
param(
    [Parameter(Mandatory=$true)]
    [string]$ClientDomain,
    
    [Parameter(Mandatory=$false)]
    [switch]$TestOnly,
    
    [Parameter(Mandatory=$false)]
    [switch]$RemoveLegacyPolicy
)

# Modern Exchange RBAC setup for FleetSync
# This script will be updated once preview cmdlets are available
```

## Benefits of Modern RBAC vs Legacy Policies

| Aspect | Legacy App Access Policies | Modern Exchange RBAC |
|--------|---------------------------|----------------------|
| **Scope Granularity** | Group-based only | Filter-based, Admin Units, Groups |
| **Permission Model** | Tenant-wide with constraints | Resource-scoped assignments |
| **Multi-tenant** | Complex group management | Native scope support |
| **Maintenance** | Manual group membership | Automated filter criteria |
| **Auditability** | Limited | Full RBAC audit trail |
| **Future Support** | Deprecated | Modern, actively developed |

## Testing Plan

### Test Scenarios
1. **Equipment Mailbox Access**: Verify booking system can read/write equipment calendars
2. **Scope Validation**: Confirm access limited to equipment mailboxes only
3. **Multi-tenant**: Test with Garage of Awesome first, then expand

### Rollback Plan
- Legacy Application Access Policies remain active during testing
- Can revert to legacy system if issues arise
- Gradual migration per tenant

## Current Workaround

Until Exchange RBAC cmdlets are available:

1. **Continue using legacy Application Access Policies** for existing functionality
2. **Monitor Microsoft documentation** for cmdlet availability updates
3. **Prepare migration scripts** for immediate deployment once available

## Next Actions

1. **IMMEDIATE**: Contact Microsoft preview program (`exoapprbacpreview@microsoft.com`)
2. **SHORT-TERM**: Monitor Exchange Online PowerShell module updates
3. **MEDIUM-TERM**: Execute migration for Garage of Awesome once cmdlets available
4. **LONG-TERM**: Roll out to all clients with automated onboarding

## References

- [Exchange RBAC for Applications Documentation](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-rbac)
- [Migration Guide from App Access Policies](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-rbac#how-to-migrate-from-application-access-policies-to-rbac-for-applications)
- Microsoft Preview Feedback: `exoapprbacpreview@microsoft.com`

---

**Status**: Ready for implementation once Exchange RBAC cmdlets become available
**Last Updated**: December 2024
**Next Review**: Check for cmdlet availability monthly