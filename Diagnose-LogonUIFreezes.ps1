# Diagnose-LogonUIFreezes.ps1
# Script to diagnose random system freezes occurring at the Windows 11 Logon screen (LogonUI.exe)
# Specifically designed for IT technicians to troubleshoot Microsoft Account (MSA) login issues.
# Compatible with PowerShell 7 (PS7).

[CmdletBinding()]
param (
    [switch]$NoClear
)

# Ensure output encoding is set correctly for Greek characters and symbols (handled gracefully if no console handle exists)
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    Write-Verbose "Console output encoding is unavailable in this host."
}

# Helper to write section headers
function Write-SectionHeader {
    param ([string]$Title)
    Write-Host "`n================================================================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "================================================================================" -ForegroundColor Cyan
}

function Get-EventMessagePreview {
    param (
        [AllowNull()]
        [string]$Message,

        [ValidateRange(1, 1000)]
        [int]$MaximumLength = 120
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return '[No event message available]'
    }

    $singleLineMessage = $Message.Trim() -replace "`r?`n", ' '
    if ($singleLineMessage.Length -le $MaximumLength) {
        return $singleLineMessage
    }

    return $singleLineMessage.Substring(0, $MaximumLength) + '...'
}

# Helper to check if current session is elevated
function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Clear terminal screen (gracefully handle non-interactive shells)
if (-not $NoClear) {
    try {
        Clear-Host
    } catch {
        Write-Verbose "The current host does not support Clear-Host."
    }
}

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "         LogonUI (Logon Screen) & Microsoft Account Diagnostic Tool" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "Target Host : $env:COMPUTERNAME" -ForegroundColor Gray
Write-Host "Local Time  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
$operatingSystem = try {
    Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
} catch {
    $null
}
$operatingSystemText = if ($operatingSystem) {
    "$($operatingSystem.Caption) (Build $($operatingSystem.BuildNumber))"
} else {
    'Unavailable'
}
Write-Host "OS Version  : $operatingSystemText" -ForegroundColor Gray

# Check Administrator privileges
$isAdmin = Test-IsAdministrator
if (-not $isAdmin) {
    Write-Host "`n[!] WARNING: Script is NOT running as Administrator." -ForegroundColor Red
    Write-Host "    Some tasks (like NGC folder permission checks, System logs, and Registry audits)" -ForegroundColor Yellow
    Write-Host "    may fail or return incomplete results due to Access Denied restrictions." -ForegroundColor Yellow
    Write-Host "    Please run PowerShell as Administrator or elevate using 'gsudo'.`n" -ForegroundColor Yellow
} else {
    Write-Host "`n[+] RUNNING WITH ADMINISTRATOR PRIVILEGES" -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# 1. TPM & Hardware Security Verification
# ------------------------------------------------------------------------------
Write-SectionHeader "1. TPM & Hardware Security Verification"

# Query TPM status using Get-Tpm cmdlet
Write-Host "[*] Checking TPM via Get-Tpm..." -ForegroundColor Gray
$tpmCmdlet = try {
    Get-Tpm -ErrorAction Stop
} catch {
    $null
}

if ($tpmCmdlet) {
    $tpmPresentText = if ($null -ne $tpmCmdlet.TpmPresent) { [string]$tpmCmdlet.TpmPresent } else { 'Unavailable' }
    $tpmReadyText = if ($null -ne $tpmCmdlet.TpmReady) { [string]$tpmCmdlet.TpmReady } else { 'Unavailable' }
    $tpmEnabledText = if ($null -ne $tpmCmdlet.TpmEnabled) { [string]$tpmCmdlet.TpmEnabled } else { 'Unavailable' }
    $tpmActivatedText = if ($null -ne $tpmCmdlet.TpmActivated) { [string]$tpmCmdlet.TpmActivated } else { 'Unavailable' }
    $tpmReadyColor = if ($tpmCmdlet.TpmReady) { 'Green' } else { 'Yellow' }
    $tpmPresentColor = if ($tpmCmdlet.TpmPresent) { 'Green' } else { 'Yellow' }

    Write-Host "  - TpmPresent          : $tpmPresentText" -ForegroundColor $tpmPresentColor
    Write-Host "  - TpmReady            : $tpmReadyText" -ForegroundColor $tpmReadyColor
    Write-Host "  - TpmEnabled          : $tpmEnabledText" -ForegroundColor Gray
    Write-Host "  - TpmActivated        : $tpmActivatedText" -ForegroundColor Gray
} else {
    Write-Host "  - Get-Tpm Cmdlet      : FAILED or NOT SUPPORTED on this system" -ForegroundColor Red
}

# Query WMI/CIM for TPM details
Write-Host "`n[*] Querying CIM for TPM Hardware Specs..." -ForegroundColor Gray
$tpmCim = try {
    Get-CimInstance -Namespace "ROOT\CIMV2\Security\MicrosoftTpm" -ClassName "Win32_Tpm" -ErrorAction Stop
} catch {
    $null
}

if ($tpmCim) {
    Write-Host "  - Manufacturer Name   : $($tpmCim.ManufacturerIdTxt)" -ForegroundColor Green
    Write-Host "  - Spec Version        : $($tpmCim.SpecVersion)" -ForegroundColor Green
    Write-Host "  - Manufacturer Version: $($tpmCim.ManufacturerVersion)" -ForegroundColor Gray

    # Operational Status
    $statusText = "Unknown"
    $statusColor = "Yellow"
    try {
        $isEnabled = Invoke-CimMethod -InputObject $tpmCim -MethodName IsEnabled -ErrorAction Stop
        $isActive = Invoke-CimMethod -InputObject $tpmCim -MethodName IsActivated -ErrorAction Stop
        $isOwned = Invoke-CimMethod -InputObject $tpmCim -MethodName IsOwned -ErrorAction Stop

        $statusText = "Enabled: $($isEnabled.IsEnabled), Active: $($isActive.IsActivated), Owned: $($isOwned.IsOwned)"
        $statusColor = if ($isEnabled.IsEnabled -and $isActive.IsActivated) { "Green" } else { "Yellow" }
    } catch {
        $statusText = "Failed to query detailed operational sub-status"
    }
    Write-Host "  - Operational Status  : $statusText" -ForegroundColor $statusColor
} else {
    Write-Host "  - Win32_Tpm CIM Class : NOT FOUND (TPM may be disabled in BIOS or missing)" -ForegroundColor Red
}

# Scan event logs for recent TPM/PSP/Intel ME errors/warnings (Last 7 days)
Write-Host "`n[*] Scanning event logs for TPM, AMD PSP, and Intel ME issues (Last 7 Days)..." -ForegroundColor Gray
$sevenDaysAgo = (Get-Date).AddDays(-7)

$hardwareEvents = [System.Collections.Generic.List[object]]::new()

# Query System log for TPM/PSP/ME sources
try {
    $sysEvts = Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        StartTime = $sevenDaysAgo
        Level     = 1, 2, 3 # Critical, Error, Warning
    } -ErrorAction SilentlyContinue | Where-Object {
        $_.ProviderName -match 'TPM|MEI|IntelME|PSP|AmdPsp' -or $_.Message -match 'TPM|PSP|Intel ME|AMD PSP|AMD-PSP'
    }
    foreach ($systemEvent in @($sysEvts)) {
        $hardwareEvents.Add($systemEvent)
    }
} catch {
    Write-Verbose "The System log security-hardware query failed: $($_.Exception.Message)"
}

# Query TPM-WMI Operational log
try {
    $tpmWmiEvts = Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-TPM-WMI/Operational'
        StartTime = $sevenDaysAgo
        Level     = 1, 2, 3
    } -ErrorAction SilentlyContinue
    foreach ($tpmWmiEvent in @($tpmWmiEvts)) {
        $hardwareEvents.Add($tpmWmiEvent)
    }
} catch {
    Write-Verbose "The TPM-WMI Operational log query failed: $($_.Exception.Message)"
}

if ($hardwareEvents.Count -gt 0) {
    Write-Host "  [!] Found $($hardwareEvents.Count) warnings/errors related to Security Hardware:" -ForegroundColor Yellow
    $hardwareEvents | Sort-Object TimeCreated -Descending | Select-Object -First 10 | ForEach-Object {
        Write-Host "    [$($_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))] [$($_.ProviderName)] (Event ID: $($_.Id))" -ForegroundColor Yellow
        Write-Host "    Message: $(Get-EventMessagePreview -Message $_.Message)" -ForegroundColor Gray
    }
} else {
    Write-Host "  [+] No recent TPM, AMD PSP, or Intel ME errors found in the last 7 days." -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# 2. NGC Folder & Windows Hello Integrity
# ------------------------------------------------------------------------------
Write-SectionHeader "2. NGC Folder & Windows Hello Integrity"

$ngcPath = "C:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc"
Write-Host "[*] Verifying NGC Folder Path: $ngcPath" -ForegroundColor Gray

$ngcExists = $false
try {
    if (Test-Path $ngcPath -ErrorAction Stop) {
        $ngcExists = $true
    }
} catch [System.UnauthorizedAccessException] {
    $ngcExists = $true
} catch {
    $ngcExists = $false
}

if (-not $ngcExists) {
    Write-Host "  [!] WARNING: NGC folder does NOT exist at the default path." -ForegroundColor Red
    Write-Host "      Windows Hello PIN or biometric data is either unconfigured or corrupt." -ForegroundColor Yellow
} else {
    Write-Host "  [+] NGC Folder exists." -ForegroundColor Green

    # Check permissions & accessibility
    try {
        $ngcAcl = Get-Acl -Path $ngcPath -ErrorAction Stop
        Write-Host "  [+] NGC folder is accessible. Reading permissions..." -ForegroundColor Green

        $aclOwner = $ngcAcl.Owner
        Write-Host "  - Owner: $aclOwner" -ForegroundColor Gray

        # Non-destructive file modification scan
        Write-Host "  [*] Scanning NGC folder structure (no modifications will be made)..." -ForegroundColor Gray
        $ngcFiles = Get-ChildItem -Path $ngcPath -File -Recurse -ErrorAction Stop

        if ($ngcFiles.Count -eq 0) {
            Write-Host "  [!] NGC folder is empty. (Windows Hello PIN is likely not configured)." -ForegroundColor Yellow
        } else {
            Write-Host "  [+] Found $($ngcFiles.Count) files/metadata blocks in NGC." -ForegroundColor Green
            Write-Host "  - Last modified file in NGC: $(($ngcFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime)" -ForegroundColor Gray

            Write-Host "  - Recent file structures inside NGC:" -ForegroundColor Gray
            $ngcFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 5 | ForEach-Object {
                Write-Host "    * Name: $($_.Name) | Size: $($_.Length) bytes | Modified: $($_.LastWriteTime)" -ForegroundColor Gray
            }
        }
    } catch [UnauthorizedAccessException] {
        Write-Host "  [!] ACCESS DENIED: Cannot read permissions or content of NGC folder." -ForegroundColor Red
        Write-Host "      This is expected behavior for non-SYSTEM/non-TrustedInstaller accounts." -ForegroundColor Yellow
        Write-Host "      Tip: Verify Windows Hello status using Settings app or elevated diagnostics." -ForegroundColor Yellow
    } catch {
        Write-Host "  [!] Error checking NGC folder: $_" -ForegroundColor Red
    }
}

# ------------------------------------------------------------------------------
# 3. Authentication & Token Broker Logging
# ------------------------------------------------------------------------------
Write-SectionHeader "3. Authentication & Token Broker Logging (Last 7 Days)"

# Function to fetch and display events from specific logs
function Get-DiagnosticEvent {
    param (
        [string]$LogName,
        [string]$DisplayName,
        [string]$FilterPattern = $null
    )

    Write-Host "[*] Querying log: $DisplayName..." -ForegroundColor Gray
    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = $LogName
            StartTime = $sevenDaysAgo
            Level     = 1, 2, 3
        } -ErrorAction Stop

        if ($FilterPattern) {
            $events = $events | Where-Object { $_.ProviderName -match $FilterPattern -or $_.Message -match $FilterPattern }
        }

        if ($events.Count -gt 0) {
            Write-Host "  [!] Found $($events.Count) critical/warning events in $($DisplayName):" -ForegroundColor Yellow
            $events | Sort-Object TimeCreated -Descending | Select-Object -First 5 | ForEach-Object {
                Write-Host "    [$($_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))] (Event ID: $($_.Id))" -ForegroundColor Yellow
                Write-Host "    Message: $(Get-EventMessagePreview -Message $_.Message)" -ForegroundColor Gray
            }
        } else {
            Write-Host "  [+] No errors or warnings found in $DisplayName." -ForegroundColor Green
        }
    } catch {
        if ($_.Exception.Message -match "No events were found") {
            Write-Host "  [+] No errors or warnings found in $DisplayName." -ForegroundColor Green
        } else {
            Write-Host "  [-] Failed to query log $($DisplayName) : $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# 3.1. User Device Registration/Admin
Get-DiagnosticEvent -LogName "Microsoft-Windows-User Device Registration/Admin" -DisplayName "User Device Registration (Admin)"

# 3.2. AAD/Operational
Get-DiagnosticEvent -LogName "Microsoft-Windows-AAD/Operational" -DisplayName "Azure Active Directory (AAD) Operational"

# 3.3. Application Log filtering for LogonUI.exe, Winlogon, WAM
Get-DiagnosticEvent -LogName "Application" -DisplayName "Application Log (Filtered: LogonUI / Winlogon / WAM)" -FilterPattern "LogonUI|Winlogon|TokenBroker|WAM|Web Account Manager"

# ------------------------------------------------------------------------------
# 4. System Configuration Audit
# ------------------------------------------------------------------------------
Write-SectionHeader "4. System Configuration Audit"

# Fast Startup check
Write-Host "[*] Checking Fast Startup status in Registry..." -ForegroundColor Gray
$powerRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
$hiberbootVal = $null

if (Test-Path $powerRegPath) {
    try {
        $hiberbootVal = (Get-ItemProperty -Path $powerRegPath -Name "HiberbootEnabled" -ErrorAction Stop).HiberbootEnabled
    } catch {
        Write-Host "  - HiberbootEnabled Registry value not found." -ForegroundColor Yellow
    }
}

if ($hiberbootVal -eq 0) {
    Write-Host "  - Fast Startup        : DISABLED (Healthy - avoids dirty volumes and kernel states)" -ForegroundColor Green
} elseif ($hiberbootVal -eq 1) {
    Write-Host "  - Fast Startup        : ENABLED (review when diagnosing resume, shutdown, or driver-state issues)" -ForegroundColor Yellow
} else {
    Write-Host "  - Fast Startup        : Unknown status ($hiberbootVal)" -ForegroundColor Yellow
}

# Last 5 unexpected shutdowns or critical kernel-power events
Write-Host "`n[*] Retrieving last 5 unexpected shutdowns or critical Kernel-Power events..." -ForegroundColor Gray
try {
    $powerEvents = Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        Id        = 41, 6008
    } -MaxEvents 5 -ErrorAction Stop

    Write-Host "  [!] Last 5 Events (ID 41 = Dirty Shutdown / ID 6008 = Unexpected Shutdown):" -ForegroundColor Yellow
    foreach ($evt in $powerEvents) {
        $eventLabel = if ($evt.Id -eq 41) { "Kernel-Power (ID 41)" } else { "Unexpected Shutdown (ID 6008)" }
        $color = if ($evt.Id -eq 41) { "Red" } else { "Yellow" }
        Write-Host "    - [$($evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))] $eventLabel" -ForegroundColor $color
        # Get details from event properties if ID 41
        if ($evt.Id -eq 41 -and $evt.Properties.Count -ge 3) {
            # Extract bugcheck code details if present
            $bcCode = $evt.Properties[1].Value
            $bcPara1 = $evt.Properties[2].Value
            Write-Host "      BugcheckCode: $bcCode | Parameters: $bcPara1" -ForegroundColor Gray
        }
    }
} catch {
    if ($_.Exception.Message -match "No events were found") {
        Write-Host "  [+] No unexpected shutdown (6008) or Kernel-Power (41) events found." -ForegroundColor Green
    } else {
        Write-Host "  [-] Failed to query System shutdown events: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`n================================================================================" -ForegroundColor Cyan
Write-Host "                             Diagnostic Scan Complete" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
