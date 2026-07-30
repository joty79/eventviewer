[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$mainPath = Join-Path $repoRoot 'Analyze-EventViewer.ps1'
$runbookPath = Join-Path $repoRoot 'docs\AGENT_RUNBOOK.md'
$agentsPath = Join-Path $repoRoot 'AGENTS.md'
$archiveRoot = Join-Path $repoRoot 'docs\history\retired-agent-assets'

foreach ($requiredPath in @($mainPath, $runbookPath, $agentsPath, $archiveRoot)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required agent-contract path is missing: $requiredPath"
    }
}

$retiredActivePaths = @(
    'test_diag_remote.ps1',
    'apply_software_fixes.ps1',
    'Verify-DiagnosticsFixes.ps1',
    'NEOS\Apply-NeosFixes.ps1',
    'doc\SUMMON_CODEX_DIAGNOSTIC.md'
)
foreach ($relativePath in $retiredActivePaths) {
    if (Test-Path -LiteralPath (Join-Path $repoRoot $relativePath)) {
        throw "Retired agent asset remains active: $relativePath"
    }
}

$expectedHashes = @{
    'test_diag_remote.ps1.txt'        = '1B321F417644E4E946B9535AD4A0E003B7F067F190870D3C503384E9B70BF64E'
    'apply_software_fixes.ps1.txt'    = '3059A21136C079231CFF48DFFC5A3748C8CDB5F54B96FBD13664FC6CCE910E90'
    'Verify-DiagnosticsFixes.ps1.txt' = 'E0BF2889333ED2E2F602829A75650A72BB19B8A6100CC17AD47027CA5F4AB1F0'
    'Apply-NeosFixes.ps1.txt'         = '766B8A3EB42E12FD8E9902CB41FA0DD1C8D69500561CB8892DA89FB08344D5FA'
    'SUMMON_CODEX_DIAGNOSTIC.md'      = '0FEB6EC4C6E59B82E100D6C001DE4A2CB9A4861B159822065E15905CC2E615B9'
}
foreach ($entry in $expectedHashes.GetEnumerator()) {
    $archivePath = Join-Path $archiveRoot $entry.Key
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        throw "Retired asset archive is missing: $($entry.Key)"
    }
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    if ($actualHash -ne $entry.Value) {
        throw "Retired asset hash mismatch: $($entry.Key)"
    }
}

$tokens = $null
$parseErrors = $null
$mainAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $mainPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "Analyze-EventViewer.ps1 has $($parseErrors.Count) parser error(s)."
}

$parameterNames = @($mainAst.ParamBlock.Parameters | ForEach-Object {
        $_.Name.VariablePath.UserPath
    })
foreach ($requiredParameter in @('ComputerName', 'Credential', 'UserName', 'BlankPassword')) {
    if ($parameterNames -notcontains $requiredParameter) {
        throw "Canonical agent CLI parameter is missing: $requiredParameter"
    }
}

$activePowerShellFiles = @(
    Get-ChildItem -LiteralPath $repoRoot -Filter '*.ps1' -File |
        Where-Object { $_.Name -notlike 'scratch*' }
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'internal') -Filter '*.ps1' -File -Recurse
    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'NEOS') -Filter '*.ps1' -File -Recurse
)
foreach ($activeFile in $activePowerShellFiles) {
    $source = Get-Content -LiteralPath $activeFile.FullName -Raw
    if ($source -match '\bNew-PSSession\b') {
        throw "Ad-hoc New-PSSession remains in active project code: $($activeFile.FullName)"
    }
}

$agentsText = Get-Content -LiteralPath $agentsPath -Raw
if ($agentsText -notmatch 'docs/AGENT_RUNBOOK\.md') {
    throw 'AGENTS.md does not route agent operations to docs/AGENT_RUNBOOK.md.'
}

$gitIgnoreText = Get-Content -LiteralPath (Join-Path $repoRoot '.gitignore') -Raw
if ($gitIgnoreText -notmatch '(?m)^scratch\*\s*$') {
    throw 'Ignored scratch assets are not separated from the project contract.'
}

Write-Output 'PASS: EventViewer has one canonical agent CLI and lossless retired-helper guards.'
