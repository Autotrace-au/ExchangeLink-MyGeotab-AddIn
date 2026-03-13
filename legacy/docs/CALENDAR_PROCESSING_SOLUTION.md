# Equipment Mailbox Calendar Processing Solution

## Problem Identified

The Azure Function app was failing with **403 ErrorAccessDenied** when trying to update equipment mailbox settings because:

1. **Graph API Limitation**: Microsoft Graph API does **NOT** support calendar processing settings (`Set-CalendarProcessing` functionality)
2. **Missing Core Settings**: Equipment mailbox booking functionality requires Exchange-specific settings that only work via PowerShell cmdlets
3. **Permission Scope**: The application needs Exchange administrator permissions, not just Graph API permissions

## Root Cause Analysis

### What Works in PowerShell Script ✅
The `FleetSync-Orchestrator.ps1` script successfully updates equipment mailboxes because it uses:
- **Exchange Online PowerShell cmdlets**: `Set-CalendarProcessing`, `Set-MailboxRegionalConfiguration`, etc.
- **Certificate-based authentication**: Direct to Exchange Online with app-only permissions
- **Native Exchange features**: Calendar processing, booking policies, delegate management

### What Fails in Function App ❌
The Python function app fails because it only uses:
- **Graph API**: Limited to basic mailbox settings only
- **Missing calendar processing**: Cannot configure `AutomateProcessing`, `AllBookInPolicy`, `ResourceDelegates`, etc.
- **Equipment mailbox restrictions**: Graph API has reduced functionality for resource mailboxes

## Complete Solution Architecture

### Phase 1: Hybrid Approach (Immediate Fix)
**Combine Graph API + PowerShell execution within the Function App**

```python
# Updated function flow:
async def update_equipment_mailbox(graph_client, device, equipment_domain, access_token, app_id, cert_thumbprint):
    # 1. Use Graph API for basic settings (what works)
    await graph_client.users.by_user_id(mailbox.id).mailbox_settings.patch(mailbox_settings)
    
    # 2. Use PowerShell for calendar processing (what's missing)
    ps_result = await update_equipment_mailbox_calendar_processing(
        primary_smtp, device, app_id, cert_thumbprint, equipment_domain
    )
    
    return combined_result
```

### Phase 2: PowerShell Core Integration
**Execute Exchange cmdlets from within Python function**

Key components:
- `exchange_powershell.py`: PowerShell execution wrapper
- Certificate-based authentication to Exchange Online
- Async execution with proper error handling
- Same credentials as Graph API (shared app registration)

## Implementation Details

### Required Calendar Processing Settings

The PowerShell script configures these critical settings that Graph API cannot handle:

```powershell
Set-CalendarProcessing -Identity $mailbox `
    -AutomateProcessing AutoAccept `          # Enable auto-booking
    -AllBookInPolicy:$true `                  # Allow all users to book
    -AllRequestInPolicy:$false `              # Don't require approval
    -AllowConflicts:$false `                  # Prevent double booking
    -BookingWindowInDays 90 `                 # Advance booking limit
    -MaximumDurationInMinutes 1440 `          # Max booking duration
    -AllowRecurringMeetings:$true `           # Allow recurring meetings
    -ResourceDelegates @("approver@domain") ` # Booking approvers
    -AdditionalResponse "Booking instructions" # Custom message
```

### Authentication Flow

```
Function App → Key Vault → Certificate → Exchange Online PowerShell
     ↓              ↓           ↓               ↓
   API Key    →  App Cert  →  Thumbprint  →  Connect-ExchangeOnline
```

### Error Handling Strategy

1. **Graph API First**: Always attempt Graph API updates (these work reliably)
2. **PowerShell Fallback**: Execute calendar processing via PowerShell
3. **Graceful Degradation**: Continue if PowerShell fails (partial functionality better than none)
4. **Detailed Logging**: Track which updates succeed/fail for troubleshooting

## Testing Approach

### Test Script: `Test-CalendarProcessing.ps1`
```powershell
# Test with your existing credentials
.\Test-CalendarProcessing.ps1 -MailboxEmail "vehicle123@garageofawesome.com.au" -TestOnly

# Apply booking settings
.\Test-CalendarProcessing.ps1 -MailboxEmail "vehicle123@garageofawesome.com.au" -EnableBooking

# With approvers
.\Test-CalendarProcessing.ps1 -MailboxEmail "vehicle123@garageofawesome.com.au" -EnableBooking -Approvers @("manager@garageofawesome.com.au")
```

### Function App Testing
1. **Existing equipment mailbox**: Use one from your working PowerShell script
2. **Test Graph API**: Verify basic settings still update
3. **Test PowerShell integration**: Verify calendar processing works
4. **End-to-end test**: MyGeotab → Function App → Exchange mailbox

## Deployment Requirements

### Azure Function App Updates
1. **Install PowerShell Core**: Ensure `pwsh` is available in the runtime
2. **Certificate access**: Function app needs access to certificate for PowerShell auth
3. **Module dependencies**: `ExchangeOnlineManagement` PowerShell module
4. **Extended timeout**: PowerShell execution may take longer than Graph API calls

### Permissions (No Changes Needed)
- **Graph API**: Keep existing `MailboxSettings.ReadWrite` permissions
- **Exchange Online**: Already configured via certificate for PowerShell script
- **Key Vault**: Already configured for certificate access

## Expected Results

### Before (Current State)
- ❌ 403 ErrorAccessDenied on equipment mailbox updates
- ❌ No calendar processing configuration
- ❌ Equipment mailboxes not properly configured for booking

### After (With Solution)
- ✅ Graph API updates basic mailbox settings (timezone, language, display name)
- ✅ PowerShell configures calendar processing (booking policies, delegates, etc.)
- ✅ Equipment mailboxes fully functional for fleet booking
- ✅ Automatic equipment availability and booking confirmation

## Migration Strategy

### Step 1: Test PowerShell Integration
- Use `Test-CalendarProcessing.ps1` with existing mailboxes
- Verify certificate authentication works
- Confirm calendar processing settings apply correctly

### Step 2: Deploy Hybrid Function
- Add `exchange_powershell.py` module to function app
- Update `update_equipment_mailbox()` to include PowerShell execution
- Test with single equipment mailbox

### Step 3: Full Rollout
- Deploy to production function app
- Monitor logs for Graph API + PowerShell execution
- Verify equipment mailbox booking functionality

## Monitoring & Troubleshooting

### Success Indicators
- Graph API calls: 200 OK responses
- PowerShell execution: "SUCCESS: Calendar processing updated"
- Equipment booking: Test calendar invites auto-accepted

### Common Issues
- **PowerShell timeout**: Increase function timeout, optimize scripts
- **Certificate access**: Verify Key Vault permissions and certificate format
- **Module loading**: Ensure ExchangeOnlineManagement module available

## Alternative Solutions (Future)

### Option 1: Exchange REST API
- Use Exchange Online REST API directly (bypassing Graph limitations)
- More complex authentication but native Exchange functionality

### Option 2: Azure Logic Apps
- Separate Logic App for PowerShell execution
- Function App calls Logic App for calendar processing
- Better separation of concerns

### Option 3: Wait for Graph API Enhancement
- Microsoft may add calendar processing to Graph API eventually
- Monitor Microsoft roadmap for equipment mailbox features

---

## Immediate Next Steps

1. **Test the PowerShell script**: Run `Test-CalendarProcessing.ps1` with your existing equipment mailboxes
2. **Verify calendar processing**: Confirm the settings apply and booking works
3. **Deploy hybrid solution**: Add PowerShell execution to the function app
4. **Monitor results**: Track 403 errors disappearing and booking functionality working

This solution directly addresses the root cause while leveraging your existing, working PowerShell approach within the modern Function App architecture.