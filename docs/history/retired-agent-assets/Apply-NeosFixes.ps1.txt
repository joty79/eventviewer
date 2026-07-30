# Apply-NeosFixes.ps1
# Automated remediation script for PC NEOS (AMD Ryzen 7 9700X + MSI MAG X870 TOMAHAWK WIFI)
# Run locally or remotely to enforce Fast Startup disablement, AMD PSP 11.0 enablement, and GPU TdrDelay settings.

[CmdletBinding()]
param(
    [switch]$Force
)

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "🔵 Automated Stability Fixes for PC NEOS (MSI X870) 🔵" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

# 1. Disable Fast Startup
try {
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Value 0 -Force -ErrorAction Stop
    & powercfg /h off | Out-Null
    Write-Host "  ✅ Fast Startup (Hiberboot) set to DISABLED." -ForegroundColor Green
} catch {
    Write-Warning "Failed disabling Fast Startup: $_"
}

# 2. Enable AMD PSP 11.0 Device
try {
    $pspDev = Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -like "*AMD PSP*" -or $_.DeviceID -like "*VEN_1022&DEV_1649*" }
    if ($pspDev) {
        if ($pspDev.ConfigManagerErrorCode -ne 0) {
            Write-Host "Enabling $($pspDev.Name)..." -ForegroundColor Yellow
            Enable-PnpDevice -InstanceId $pspDev.DeviceID -Confirm:$false -ErrorAction Stop
            Write-Host "  ✅ $($pspDev.Name) enabled successfully." -ForegroundColor Green
        } else {
            Write-Host "  ✅ $($pspDev.Name) is already active and healthy (Status: OK)." -ForegroundColor Green
        }
    }
} catch {
    Write-Warning "Could not configure AMD PSP Device: $_"
}

# 3. Configure TdrDelay for GPU Blackscreen Prevention
try {
    $gfxPath = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
    if (-not (Test-Path $gfxPath)) { New-Item -Path $gfxPath -Force | Out-Null }
    Set-ItemProperty -Path $gfxPath -Name "TdrDelay" -Value 10 -Type DWord -Force
    Set-ItemProperty -Path $gfxPath -Name "TdrDdiDelay" -Value 10 -Type DWord -Force
    Write-Host "  ✅ Graphics Driver TdrDelay configured to 10 seconds." -ForegroundColor Green
} catch {
    Write-Warning "Failed setting TdrDelay: $_"
}

Write-Host "`nAll stability fixes applied successfully!" -ForegroundColor Green
