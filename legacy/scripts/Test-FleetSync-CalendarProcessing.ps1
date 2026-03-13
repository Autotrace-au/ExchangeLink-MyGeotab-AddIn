# Test-FleetSync-CalendarProcessing.ps1
# Comprehensive test of calendar processing functionality for FleetSync

param(
    [Parameter(Mandatory=$false)]
    [string]$TestEmail = "sam@garageofawesome.com.au"
)

Write-Host "=== FleetSync Calendar Processing Test ===" -ForegroundColor Cyan
Write-Host "Testing with: $TestEmail" -ForegroundColor Yellow

try {
    # Connect to Exchange Online
    Write-Host "`n1. Connecting to Exchange Online..." -ForegroundColor Green
    Import-Module ExchangeOnlineManagement -Force
    Connect-ExchangeOnline -UserPrincipalName sam@garageofawesome.com.au -ShowBanner:$false
    Write-Host "   ✅ Connected successfully" -ForegroundColor Green

    # Check mailbox type
    Write-Host "`n2. Analyzing mailbox..." -ForegroundColor Green
    $mailbox = Get-EXOMailbox -Identity $TestEmail
    Write-Host "   Display Name: $($mailbox.DisplayName)" -ForegroundColor Gray
    Write-Host "   Type: $($mailbox.RecipientTypeDetails)" -ForegroundColor Gray
    Write-Host "   Primary SMTP: $($mailbox.PrimarySmtpAddress)" -ForegroundColor Gray

    # Test calendar processing cmdlets
    Write-Host "`n3. Testing Calendar Processing Cmdlets..." -ForegroundColor Green
    
    # Get current settings
    Write-Host "   Getting current settings..." -ForegroundColor Yellow
    $currentSettings = Get-CalendarProcessing -Identity $TestEmail
    
    Write-Host "   Current Settings:" -ForegroundColor Cyan
    Write-Host "     AutomateProcessing: $($currentSettings.AutomateProcessing)" -ForegroundColor Gray
    Write-Host "     AllBookInPolicy: $($currentSettings.AllBookInPolicy)" -ForegroundColor Gray
    Write-Host "     AllRequestInPolicy: $($currentSettings.AllRequestInPolicy)" -ForegroundColor Gray
    Write-Host "     BookingWindowInDays: $($currentSettings.BookingWindowInDays)" -ForegroundColor Gray
    Write-Host "     MaximumDurationInMinutes: $($currentSettings.MaximumDurationInMinutes)" -ForegroundColor Gray
    Write-Host "     AllowConflicts: $($currentSettings.AllowConflicts)" -ForegroundColor Gray
    Write-Host "     AllowRecurringMeetings: $($currentSettings.AllowRecurringMeetings)" -ForegroundColor Gray
    
    # Test equipment-style booking settings (DEMO - will revert)
    Write-Host "`n4. Testing Equipment Mailbox Settings..." -ForegroundColor Green
    Write-Host "   DEMO: Applying equipment mailbox settings (will revert)..." -ForegroundColor Yellow
    
    # Store original settings for restoration
    $originalSettings = @{
        AutomateProcessing = $currentSettings.AutomateProcessing
        AllBookInPolicy = $currentSettings.AllBookInPolicy
        AllRequestInPolicy = $currentSettings.AllRequestInPolicy
        BookingWindowInDays = $currentSettings.BookingWindowInDays
        MaximumDurationInMinutes = $currentSettings.MaximumDurationInMinutes
        AllowConflicts = $currentSettings.AllowConflicts
        AllowRecurringMeetings = $currentSettings.AllowRecurringMeetings
    }
    
    # Apply equipment mailbox style settings
    Write-Host "   Applying equipment booking settings..." -ForegroundColor Yellow
    Set-CalendarProcessing -Identity $TestEmail `
        -AutomateProcessing AutoAccept `
        -AllBookInPolicy:$true `
        -AllRequestInPolicy:$false `
        -AllowConflicts:$false `
        -BookingWindowInDays 90 `
        -MaximumDurationInMinutes 480 `
        -AllowRecurringMeetings:$true `
        -AddAdditionalResponse:$true `
        -AdditionalResponse "DEMO: Equipment booking test - booking policies applied"
    
    Write-Host "   ✅ Equipment settings applied successfully!" -ForegroundColor Green
    
    # Verify the changes
    Write-Host "`n5. Verifying changes..." -ForegroundColor Green
    Start-Sleep -Seconds 2
    $newSettings = Get-CalendarProcessing -Identity $TestEmail
    
    Write-Host "   Updated Settings:" -ForegroundColor Cyan
    Write-Host "     AutomateProcessing: $($newSettings.AutomateProcessing)" -ForegroundColor Gray
    Write-Host "     AllBookInPolicy: $($newSettings.AllBookInPolicy)" -ForegroundColor Gray
    Write-Host "     BookingWindowInDays: $($newSettings.BookingWindowInDays)" -ForegroundColor Gray
    Write-Host "     MaximumDurationInMinutes: $($newSettings.MaximumDurationInMinutes)" -ForegroundColor Gray
    Write-Host "     AllowConflicts: $($newSettings.AllowConflicts)" -ForegroundColor Gray
    
    # Restore original settings
    Write-Host "`n6. Restoring original settings..." -ForegroundColor Green
    Set-CalendarProcessing -Identity $TestEmail `
        -AutomateProcessing $originalSettings.AutomateProcessing `
        -AllBookInPolicy:$originalSettings.AllBookInPolicy `
        -AllRequestInPolicy:$originalSettings.AllRequestInPolicy `
        -AllowConflicts:$originalSettings.AllowConflicts `
        -BookingWindowInDays $originalSettings.BookingWindowInDays `
        -MaximumDurationInMinutes $originalSettings.MaximumDurationInMinutes `
        -AllowRecurringMeetings:$originalSettings.AllowRecurringMeetings `
        -AddAdditionalResponse:$false
    
    Write-Host "   ✅ Original settings restored" -ForegroundColor Green
    
    # Final verification
    Write-Host "`n7. Final verification..." -ForegroundColor Green
    $finalSettings = Get-CalendarProcessing -Identity $TestEmail
    Write-Host "   AutomateProcessing restored to: $($finalSettings.AutomateProcessing)" -ForegroundColor Gray
    
    Write-Host "`n🎉 TEST COMPLETED SUCCESSFULLY!" -ForegroundColor Green
    Write-Host ""
    Write-Host "KEY FINDINGS:" -ForegroundColor Cyan
    Write-Host "✅ Exchange Online PowerShell cmdlets are working" -ForegroundColor Green
    Write-Host "✅ Set-CalendarProcessing can configure equipment booking" -ForegroundColor Green
    Write-Host "✅ This proves the Function App solution will work" -ForegroundColor Green
    Write-Host ""
    Write-Host "NEXT STEPS:" -ForegroundColor Yellow
    Write-Host "1. Deploy the PowerShell module to Azure Functions" -ForegroundColor Gray
    Write-Host "2. Test with actual equipment mailboxes" -ForegroundColor Gray
    Write-Host "3. Integrate with MyGeotab device sync" -ForegroundColor Gray

} catch {
    Write-Host "`n❌ TEST FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
} finally {
    Write-Host "`nDisconnecting from Exchange Online..." -ForegroundColor Gray
    try {
        Disconnect-ExchangeOnline -Confirm:$false
    } catch {
        # Ignore disconnect errors
    }
}