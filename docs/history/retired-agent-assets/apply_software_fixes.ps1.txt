[CmdletBinding()]
param(
    [string]$ComputerName = '192.168.1.47',
    [string]$UserName = 'cbx_t',
    [PSCredential]$Credential,
    [switch]$BlankPassword
)

. (Join-Path $PSScriptRoot 'internal\EventViewer\Connect-EventViewerTarget.ps1')
$session = Connect-EventViewerTarget `
    -ComputerName $ComputerName `
    -UserName $UserName `
    -Credential $Credential `
    -BlankPassword:$BlankPassword

try {
    Invoke-Command -Session $session -ScriptBlock {
        Write-Output "=== QUERYING ACTIVE STORAGE DRIVERS ==="
        Get-CimInstance Win32_PnPSignedDriver |
            Where-Object { $_.DeviceName -like "*AHCI*" -or $_.DeviceName -like "*SATA*" -or $_.DeviceClass -eq "SCSIAdapter" } |
            Select-Object DeviceName, Manufacturer, DriverVersion, InfName, DeviceClass |
            Format-Table -AutoSize

        Write-Output "=== DISABLING FAST STARTUP (HIBERBOOT) ==="
        try {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0 -Force -ErrorAction Stop
            Write-Output "  ✅ Successfully disabled Fast Startup in Registry."
        } catch {
            Write-Output "  ❌ Failed to disable Fast Startup: $_"
        }

        Write-Output "=== DISABLING PCIE LINK STATE POWER MANAGEMENT (ASPM) ==="
        try {
            # Disable ASPM on AC power
            & powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0
            # Disable ASPM on DC power
            & powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_PCIEXPRESS ASPM 0
            # Apply the current scheme
            & powercfg /SETACTIVE SCHEME_CURRENT
            Write-Output "  ✅ Successfully disabled PCIe Link State Power Management (ASPM) via powercfg."
        } catch {
            Write-Output "  ❌ Failed to disable PCIe ASPM: $_"
        }

        Write-Output "=== VERIFYING POWER PLAN SETTINGS ==="
        # Query power plan to confirm
        & powercfg /query SCHEME_CURRENT SUB_PCIEXPRESS
    }
} finally {
    Remove-PSSession -Session $session
}
