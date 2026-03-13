param(
    [Parameter(Mandatory=$true)]
    [string]$MailboxEmail,
    
    [Parameter(Mandatory=$true)]
    [string]$DeviceName,
    
    [Parameter(Mandatory=$true)]
    [string]$TenantId,
    
    [Parameter(Mandatory=$true)]
    [string]$ClientId,
    
    [Parameter(Mandatory=$true)]
    [string]$CertificateData
)

function Process-EquipmentMailbox {
    param($MailboxEmail, $DeviceName, $TenantId, $ClientId, $CertificateData)
    
    try {
        Write-Host "Processing equipment mailbox: $MailboxEmail for device: $DeviceName"
        
        # Decode certificate from base64
        $certBytes = [Convert]::FromBase64String($CertificateData)
        $tempCertPath = "/tmp/temp-cert-$(Get-Random).pfx"
        [System.IO.File]::WriteAllBytes($tempCertPath, $certBytes)
        
        try {
            # Connect to Exchange Online using certificate
            Write-Host "Connecting to Exchange Online..."
            Connect-ExchangeOnline -CertificateFilePath $tempCertPath -AppId $ClientId -Organization $TenantId -ShowBanner:$false
            
            # Configure calendar processing for the equipment mailbox
            Write-Host "Configuring calendar processing for $MailboxEmail..."
            Set-CalendarProcessing -Identity $MailboxEmail `
                -AutomateProcessing AutoAccept `
                -AllBookInPolicy $true `
                -DeleteComments $false `
                -DeleteSubject $false `
                -RemovePrivateProperty $false
            
            Write-Host "Successfully configured calendar processing for $MailboxEmail"
            
            # Disconnect from Exchange Online
            Disconnect-ExchangeOnline -Confirm:$false
            
            return @{
                success = $true
                mailbox = $MailboxEmail
                device = $DeviceName
                message = "Calendar processing configured successfully"
                timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
        }
        finally {
            # Clean up temporary certificate file
            if (Test-Path $tempCertPath) {
                Remove-Item $tempCertPath -Force
            }
        }
    }
    catch {
        Write-Error "Error processing mailbox $MailboxEmail`: $($_.Exception.Message)"
        return @{
            success = $false
            mailbox = $MailboxEmail
            device = $DeviceName
            error = $_.Exception.Message
            timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
    }
}

# Execute if called directly
if ($MailboxEmail -and $DeviceName -and $TenantId -and $ClientId -and $CertificateData) {
    $result = Process-EquipmentMailbox -MailboxEmail $MailboxEmail -DeviceName $DeviceName -TenantId $TenantId -ClientId $ClientId -CertificateData $CertificateData
    Write-Output ($result | ConvertTo-Json -Compress)
}