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
    CrashControl     = [pscustomobject]@{
        CrashDumpEnabled = 7
        DumpFile         = 'C:\WINDOWS\MEMORY.DMP'
        MinidumpDir      = 'C:\WINDOWS\Minidump'
    }
    MemoryDmp       = $emptyRemoteObject
    Minidumps       = $emptyRemoteObject
    PnpErrors       = @()
    Disks           = @()
    Wear            = @()
    CrashEvents     = @()
    WheaEvents      = @()
    SystemWheaEvents = @()
}

$lines = @(Get-FormattedDiagLines -diagData $fixture)
if (-not ($lines -contains 'MEMORY.DMP: NOT FOUND')) {
    throw 'Empty remoted MEMORY.DMP object was not treated as absent.'
}
if (-not ($lines -contains 'Minidumps: None found in C:\WINDOWS\Minidump')) {
    throw 'Empty remoted minidump object was not treated as absent.'
}

Write-Host 'PASS: EventViewer formatting handles empty deserialized dump objects.' -ForegroundColor Green
