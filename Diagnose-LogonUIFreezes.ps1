# Diagnose-LogonUIFreezes.ps1
# Script to diagnose random system freezes occurring at the Windows 11 Logon screen (LogonUI.exe)
# Specifically designed for IT technicians to troubleshoot Microsoft Account (MSA) login issues.
# Compatible with PowerShell 7 (PS7).

[CmdletBinding()]
param (
    [switch]$NoClear,

    [switch]$FailOnUnavailable
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

function Test-IsNoMatchingEventsError {
    param (
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    return $ErrorRecord.FullyQualifiedErrorId -like 'NoMatchingEventsFound,*'
}

function Write-UnavailableResult {
    param (
        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [string]$Reason
    )

    $script:UnavailableCheckCount++
    Write-Host "  [-] $Label unavailable: $Reason" -ForegroundColor Red
}

function Get-EventDataMap {
    param (
        [Parameter(Mandatory)]
        [System.Diagnostics.Eventing.Reader.EventRecord]$EventRecord
    )

    $eventData = @{}
    [xml]$eventXml = $EventRecord.ToXml()
    foreach ($dataNode in @($eventXml.Event.EventData.Data)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$dataNode.Name)) {
            $eventData[[string]$dataNode.Name] = [string]$dataNode.'#text'
        }
    }

    return $eventData
}

$script:UnavailableCheckCount = 0

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
$tpmCmdlet = $null
try {
    $tpmResult = Get-Tpm -ErrorAction Stop
    $expectedTpmProperties = @('TpmPresent', 'TpmReady', 'TpmEnabled', 'TpmActivated')
    $hasExpectedTpmProperties = @(
        $expectedTpmProperties | Where-Object { $tpmResult.PSObject.Properties.Name -contains $_ }
    ).Count -eq $expectedTpmProperties.Count

    if ($tpmResult -is [string] -or -not $hasExpectedTpmProperties) {
        $failureText = if ($tpmResult -is [string] -and -not [string]::IsNullOrWhiteSpace($tpmResult)) {
            $tpmResult
        } else {
            'Get-Tpm did not return the expected TPM status object.'
        }
        throw [InvalidOperationException]::new($failureText)
    }

    $tpmCmdlet = $tpmResult
} catch {
    Write-UnavailableResult -Label 'Get-Tpm status' -Reason $_.Exception.Message
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
}

# Query WMI/CIM for TPM details
Write-Host "`n[*] Querying CIM for TPM Hardware Specs..." -ForegroundColor Gray
$tpmCim = $null
$tpmCimQuerySucceeded = $false
try {
    $tpmCim = Get-CimInstance -Namespace "ROOT\CIMV2\Security\MicrosoftTpm" -ClassName "Win32_Tpm" -ErrorAction Stop
    $tpmCimQuerySucceeded = $true
} catch {
    Write-UnavailableResult -Label 'Win32_Tpm CIM query' -Reason $_.Exception.Message
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
        $statusText = "Unavailable: $($_.Exception.Message)"
        Write-UnavailableResult -Label 'Win32_Tpm operational methods' -Reason $_.Exception.Message
    }
    Write-Host "  - Operational Status  : $statusText" -ForegroundColor $statusColor
} elseif ($tpmCimQuerySucceeded) {
    Write-Host "  - Win32_Tpm CIM Class : No instance returned." -ForegroundColor Yellow
    Write-Host "    This result alone does not prove that TPM is disabled or missing." -ForegroundColor Gray
}

# Scan event logs for recent TPM/PSP/Intel ME errors/warnings (Last 7 days)
Write-Host "`n[*] Scanning event logs for TPM, AMD PSP, and Intel ME issues (Last 7 Days)..." -ForegroundColor Gray
$sevenDaysAgo = (Get-Date).AddDays(-7)

$hardwareEvents = [System.Collections.Generic.List[object]]::new()
$hardwareEventQueryUnavailableCount = 0

# Query System log for TPM/PSP/ME sources
try {
    $sysEvts = Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        StartTime = $sevenDaysAgo
        Level     = 1, 2, 3 # Critical, Error, Warning
    } -ErrorAction Stop | Where-Object {
        $_.ProviderName -match 'TPM|MEI|IntelME|PSP|AmdPsp' -or $_.Message -match 'TPM|PSP|Intel ME|AMD PSP|AMD-PSP'
    }
    foreach ($systemEvent in @($sysEvts)) {
        $hardwareEvents.Add($systemEvent)
    }
} catch {
    if (-not (Test-IsNoMatchingEventsError -ErrorRecord $_)) {
        $hardwareEventQueryUnavailableCount++
        Write-UnavailableResult -Label 'System security-hardware event query' -Reason $_.Exception.Message
    }
}

# Query TPM-WMI Operational log
try {
    $tpmWmiEvts = Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-TPM-WMI/Operational'
        StartTime = $sevenDaysAgo
        Level     = 1, 2, 3
    } -ErrorAction Stop
    foreach ($tpmWmiEvent in @($tpmWmiEvts)) {
        $hardwareEvents.Add($tpmWmiEvent)
    }
} catch {
    if (-not (Test-IsNoMatchingEventsError -ErrorRecord $_)) {
        $hardwareEventQueryUnavailableCount++
        Write-UnavailableResult -Label 'TPM-WMI Operational event query' -Reason $_.Exception.Message
    }
}

if ($hardwareEvents.Count -gt 0) {
    Write-Host "  [!] Found $($hardwareEvents.Count) warnings/errors related to Security Hardware:" -ForegroundColor Yellow
    $hardwareEvents | Sort-Object TimeCreated -Descending | Select-Object -First 10 | ForEach-Object {
        Write-Host "    [$($_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))] [$($_.ProviderName)] (Event ID: $($_.Id))" -ForegroundColor Yellow
        Write-Host "    Message: $(Get-EventMessagePreview -Message $_.Message)" -ForegroundColor Gray
    }
} elseif ($hardwareEventQueryUnavailableCount -eq 0) {
    Write-Host "  [+] No recent TPM, AMD PSP, or Intel ME errors found in the last 7 days." -ForegroundColor Green
} else {
    Write-Host "  [?] No matching events were found in the sources that were available." -ForegroundColor Yellow
    Write-Host "      The security-hardware event result is partial, not a clean finding." -ForegroundColor Yellow
}

# ------------------------------------------------------------------------------
# 2. NGC Folder & Windows Hello Integrity
# ------------------------------------------------------------------------------
Write-SectionHeader "2. NGC Folder & Windows Hello Integrity"

$ngcPath = "C:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc"
Write-Host "[*] Verifying NGC Folder Path: $ngcPath" -ForegroundColor Gray

$ngcState = 'Unknown'
try {
    $ngcState = if (Test-Path -LiteralPath $ngcPath -ErrorAction Stop) { 'Exists' } else { 'Missing' }
} catch {
    Write-UnavailableResult -Label 'NGC folder existence check' -Reason $_.Exception.Message
}

if ($ngcState -eq 'Missing') {
    Write-Host "  [!] WARNING: NGC folder does NOT exist at the default path." -ForegroundColor Red
    Write-Host "      This may mean Windows Hello is not configured; absence alone does not prove corruption." -ForegroundColor Yellow
} elseif ($ngcState -eq 'Unknown') {
    Write-Host "  [?] NGC folder state could not be verified." -ForegroundColor Yellow
    Write-Host "      Protected-path access failure is not evidence of Windows Hello corruption." -ForegroundColor Yellow
} else {
    Write-Host "  [+] NGC Folder exists." -ForegroundColor Green

    # Check permissions & accessibility
    try {
        $ngcAcl = Get-Acl -LiteralPath $ngcPath -ErrorAction Stop
        Write-Host "  [+] NGC folder is accessible. Reading permissions..." -ForegroundColor Green

        $aclOwner = $ngcAcl.Owner
        Write-Host "  - Owner: $aclOwner" -ForegroundColor Gray
    } catch {
        Write-UnavailableResult -Label 'NGC permissions' -Reason $_.Exception.Message
        Write-Host "      Protected-path access failure is not evidence of Windows Hello corruption." -ForegroundColor Yellow
    }

    if ($null -ne $ngcAcl) {
        # Non-destructive file modification scan
        Write-Host "  [*] Scanning NGC folder structure (no modifications will be made)..." -ForegroundColor Gray
        try {
            $ngcFiles = @(Get-ChildItem -LiteralPath $ngcPath -File -Recurse -ErrorAction Stop)

            if ($ngcFiles.Count -eq 0) {
                Write-Host "  [!] NGC folder contains no files. Windows Hello may be unconfigured." -ForegroundColor Yellow
                Write-Host "      Empty content alone does not prove corruption." -ForegroundColor Gray
            } else {
                Write-Host "  [+] Found $($ngcFiles.Count) files/metadata blocks in NGC." -ForegroundColor Green
                Write-Host "  - Last modified file in NGC: $(($ngcFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime)" -ForegroundColor Gray

                Write-Host "  - Recent file structures inside NGC:" -ForegroundColor Gray
                $ngcFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 5 | ForEach-Object {
                    Write-Host "    * Name: $($_.Name) | Size: $($_.Length) bytes | Modified: $($_.LastWriteTime)" -ForegroundColor Gray
                }
            }
        } catch {
            Write-UnavailableResult -Label 'NGC content scan' -Reason $_.Exception.Message
            Write-Host "      A protected-path read failure is not a Windows Hello health verdict." -ForegroundColor Yellow
        }
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
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName   = $LogName
            StartTime = $sevenDaysAgo
            Level     = 1, 2, 3
        } -ErrorAction Stop)

        if ($FilterPattern) {
            $events = @(
                $events | Where-Object {
                    $_.ProviderName -match $FilterPattern -or $_.Message -match $FilterPattern
                }
            )
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
        if (Test-IsNoMatchingEventsError -ErrorRecord $_) {
            Write-Host "  [+] No errors or warnings found in $DisplayName." -ForegroundColor Green
        } else {
            Write-UnavailableResult -Label "$DisplayName event query" -Reason $_.Exception.Message
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
$hiberbootQuerySucceeded = $false

try {
    $hiberbootVal = (Get-ItemProperty -Path $powerRegPath -Name "HiberbootEnabled" -ErrorAction Stop).HiberbootEnabled
    $hiberbootQuerySucceeded = $true
} catch {
    Write-UnavailableResult -Label 'HiberbootEnabled registry preference' -Reason $_.Exception.Message
}

if ($hiberbootQuerySucceeded) {
    if ($hiberbootVal -eq 0) {
        Write-Host "  - Registry preference : DISABLED" -ForegroundColor Gray
    } elseif ($hiberbootVal -eq 1) {
        Write-Host "  - Registry preference : ENABLED" -ForegroundColor Yellow
    } else {
        Write-Host "  - Registry preference : UNKNOWN (unexpected value: $hiberbootVal)" -ForegroundColor Yellow
    }
    Write-Host "    This preference alone does not prove Fast Startup availability, use, health, or incident causation." -ForegroundColor Gray
}

# Last 5 unexpected shutdowns or critical kernel-power events
Write-Host "`n[*] Retrieving last 5 unexpected shutdowns or critical Kernel-Power events..." -ForegroundColor Gray
try {
    $powerEvents = @(Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        Id        = 41, 6008
    } -MaxEvents 5 -ErrorAction Stop)

    Write-Host "  [!] Recent restart/shutdown evidence (ID 41 and ID 6008):" -ForegroundColor Yellow
    foreach ($evt in $powerEvents) {
        $eventLabel = if ($evt.Id -eq 41) { "Kernel-Power (ID 41: restart without a recorded clean shutdown)" } else { "EventLog (ID 6008: previous shutdown was unexpected)" }
        $color = if ($evt.Id -eq 41) { "Red" } else { "Yellow" }
        Write-Host "    - [$($evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))] $eventLabel" -ForegroundColor $color
        if ($evt.Id -eq 41) {
            try {
                $eventData = Get-EventDataMap -EventRecord $evt
                $bugcheckCode = $eventData['BugcheckCode']
                $powerButtonTimestamp = $eventData['PowerButtonTimestamp']
                Write-Host "      BugcheckCode: $bugcheckCode | PowerButtonTimestamp: $powerButtonTimestamp" -ForegroundColor Gray
                Write-Host "      Event 41 records an unclean restart; it does not identify the root cause by itself." -ForegroundColor Gray
            } catch {
                Write-UnavailableResult -Label "Kernel-Power Event 41 detail decoding ($($evt.TimeCreated))" -Reason $_.Exception.Message
            }
        }
    }
} catch {
    if (Test-IsNoMatchingEventsError -ErrorRecord $_) {
        Write-Host "  [+] No unexpected shutdown (6008) or Kernel-Power (41) events found." -ForegroundColor Green
    } else {
        Write-UnavailableResult -Label 'System shutdown event query' -Reason $_.Exception.Message
    }
}

Write-Host "`n================================================================================" -ForegroundColor Cyan
if ($script:UnavailableCheckCount -eq 0) {
    Write-Host "                   Diagnostic Scan Complete (full query coverage)" -ForegroundColor Cyan
} else {
    Write-Host "               Diagnostic Scan Complete (partial query coverage)" -ForegroundColor Yellow
    Write-Host "  Unavailable checks: $script:UnavailableCheckCount. Findings from successful queries remain valid." -ForegroundColor Yellow
}
Write-Host "================================================================================" -ForegroundColor Cyan

if ($FailOnUnavailable -and $script:UnavailableCheckCount -gt 0) {
    exit 2
}
