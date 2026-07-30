[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$mainScriptPath = Join-Path $repoRoot 'Analyze-EventViewer.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($mainScriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw $parseErrors[0].Message
}

$formatFunction = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-FormattedDiagLines'
    }, $true)
if ($null -eq $formatFunction) {
    throw 'Get-FormattedDiagLines was not found.'
}
. ([ScriptBlock]::Create($formatFunction.Extent.Text))

$emptyRemoteObject = [pscustomobject]@{}
$fixture = [pscustomobject]@{
    ComputerName     = 'REMOTE-FIXTURE'
    Manufacturer     = 'Fixture Manufacturer'
    Model            = 'Fixture Model'
    Motherboard      = 'Fixture Board'
    MotherboardSerial = 'FIXTURE-SERIAL'
    Cpu              = 'Fixture CPU'
    BiosVersion      = '1.0'
    BiosReleaseDate  = '2026-01-01'
    OSCaption        = 'Microsoft Windows 11 Pro'
    OSVersion        = '10.0.26200'
    OSArchitecture   = '64-bit'
    LastBootUpTime   = [datetime]'2026-01-01'
    SafeBootStatus   = 'Normal Boot'
    FastStartup      = 0
    HiberbootPreference = 0
    HibernateEnabled = 0
    HiberFileExists  = $false
    PowerCfgAvailableStates = @('Fixture powercfg evidence')
    PowerCfgQuerySucceeded = $true
    CrashControl     = [pscustomobject]@{
        CrashDumpEnabled = 7
        DumpFile         = 'C:\WINDOWS\MEMORY.DMP'
        MinidumpDir      = 'C:\WINDOWS\Minidump'
    }
    MemoryDmp       = $emptyRemoteObject
    Minidumps       = $emptyRemoteObject
    PnpErrors       = @()
    PnpQuerySucceeded = $true
    Disks           = @()
    DiskQuerySucceeded = $true
    Wear            = @()
    WearQuerySucceeded = $true
    CrashEvents     = @()
    CrashEventQuerySucceeded = $true
    WheaEvents      = @()
    WheaOperationalQuerySucceeded = $true
    SystemWheaEvents = @()
    SystemWheaQuerySucceeded = $true
}

$lines = @(Get-FormattedDiagLines -diagData $fixture)
if (-not ($lines -contains 'MEMORY.DMP: NOT FOUND')) {
    throw 'Empty remoted MEMORY.DMP object was not treated as absent.'
}
if (-not ($lines -contains 'Minidumps: None found in C:\WINDOWS\Minidump')) {
    throw 'Empty remoted minidump object was not treated as absent.'
}
if (-not ($lines -contains 'Fast Startup (Hiberboot): REGISTRY PREFERENCE DISABLED')) {
    throw 'Disabled Fast Startup preference was not labelled as a preference.'
}
if (@($lines | Where-Object { $_ -match 'Fast Startup.*\bOK\b' }).Count -gt 0) {
    throw 'Fast Startup preference was incorrectly presented as a universal OK verdict.'
}

$fixture.FastStartup = $null
$fixture.HiberbootPreference = $null
$fixture.PowerCfgQuerySucceeded = $false
$fixture.PnpErrors = @(
    [pscustomobject]@{
        Name = 'AMD PSP Fixture'
        ConfigManagerErrorCode = 22
        Manufacturer = 'Fixture'
        DeviceID = 'FIXTURE\PSP'
    },
    [pscustomobject]@{
        Name = 'Driver Failure Fixture'
        ConfigManagerErrorCode = 31
        Manufacturer = 'Fixture'
        DeviceID = 'FIXTURE\DRIVER'
    }
)
$fixture.CrashEvents = @(
    [pscustomobject]@{
        TimeCreated = [datetime]'2026-01-02'
        Id = 161
        ProviderName = 'volmgr'
        Message = 'Dump file creation failed.'
        Analysis = ''
    }
)
$fixture.SystemWheaQuerySucceeded = $false
$honestyLines = @(Get-FormattedDiagLines -diagData $fixture)

if (-not ($honestyLines -contains 'Fast Startup (Hiberboot): UNKNOWN (η registry preference δεν ήταν διαθέσιμη)')) {
    throw 'Unavailable Fast Startup evidence was not reported as unknown.'
}
$disabledPspLine = $honestyLines | Where-Object { $_ -match 'AMD PSP Fixture' } | Select-Object -First 1
if ($disabledPspLine -notmatch '^ℹ️ ' -or $disabledPspLine -notmatch 'may be intentional') {
    throw 'PnP Code 22 was not presented as an intentional-state possibility.'
}
if (@($honestyLines | Where-Object { $_ -match 'Συνιστάται ενεργοποίηση|SSD.*χάθηκε ακαριαία' }).Count -gt 0) {
    throw 'A historical remediation or SSD-disconnect conclusion was still asserted without evidence.'
}
if (@($honestyLines | Where-Object { $_ -match 'δεν αποδεικνύει από μόνο του' }).Count -eq 0) {
    throw 'volmgr 161 was not bounded to dump-failure evidence.'
}
if (-not ($honestyLines -contains '  Microsoft-Windows-WHEA-Logger query unavailable; no absence claim can be made.')) {
    throw 'Failed WHEA query was incorrectly rendered as no events.'
}

$fixture.CrashEvents[0].Analysis = 'STATUS_DEVICE_PROTOCOL_ERROR'
$decodedLines = @(Get-FormattedDiagLines -diagData $fixture)
if (@($decodedLines | Where-Object { $_ -match 'υποστηρίζει πρόβλημα στο storage I/O path' }).Count -eq 0) {
    throw 'Decoded storage status was not distinguished from an undecoded volmgr 161 event.'
}

Write-Host 'PASS: EventViewer formatting preserves unknown state and bounds diagnostic conclusions.' -ForegroundColor Green
