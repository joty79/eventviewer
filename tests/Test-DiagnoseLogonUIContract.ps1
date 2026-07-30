$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'Diagnose-LogonUIFreezes.ps1'
$source = Get-Content -LiteralPath $scriptPath -Raw
$runbookPath = Join-Path $repoRoot 'docs\AGENT_RUNBOOK.md'
$runbookSource = Get-Content -LiteralPath $runbookPath -Raw

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if (@($parseErrors).Count -gt 0) {
    throw "Diagnose-LogonUIFreezes.ps1 has parser errors: $($parseErrors.Message -join '; ')"
}

$requiredPatterns = [ordered]@{
    'strict partial-result switch' = '\[switch\]\$FailOnUnavailable'
    'central unavailable counter' = '\$script:UnavailableCheckCount'
    'locale-independent empty-event classification' = 'FullyQualifiedErrorId\s+-like\s+''NoMatchingEventsFound,\*'''
    'structured Event 41 decoding' = 'Get-EventDataMap'
    'partial automation exit code' = 'exit\s+2'
    'Fast Startup evidence boundary' = 'preference alone does not prove Fast Startup availability'
    'Event 41 evidence boundary' = 'does not identify the root cause by itself'
}

foreach ($contractItem in $requiredPatterns.GetEnumerator()) {
    if ($source -notmatch $contractItem.Value) {
        throw "Missing Diagnose-LogonUI contract: $($contractItem.Key)."
    }
}

$forbiddenPatterns = [ordered]@{
    'silent event-query failure' = '-ErrorAction\s+SilentlyContinue'
    'NGC missing-equals-corrupt claim' = 'either unconfigured or corrupt'
    'TPM query-failure hardware claim' = 'TPM may be disabled in BIOS or missing'
    'universal disabled-Fast-Startup health verdict' = 'DISABLED \(Healthy'
    'Event 41 dirty-volume label' = 'ID 41 = Dirty Shutdown'
    'positional Event 41 property decoding' = '\.Properties\['
    'Registry mutation' = '(?im)^\s*(?:Set|New|Remove)-ItemProperty\b'
    'NGC content mutation' = '(?im)^\s*(?:Remove|Move|Rename)-Item\b'
    'TPM mutation' = '(?im)^\s*(?:Clear|Initialize)-Tpm\b'
}

foreach ($contractItem in $forbiddenPatterns.GetEnumerator()) {
    if ($source -match $contractItem.Value) {
        throw "Forbidden Diagnose-LogonUI behavior found: $($contractItem.Key)."
    }
}

$runbookPatterns = [ordered]@{
    'local-only scope' = 'separate local-only focused collector'
    'canonical remote CLI remains Analyze-EventViewer' = 'does not replace the canonical `Analyze-EventViewer\.ps1` flow'
    'strict automation invocation' = '-FailOnUnavailable'
    'partial exit meaning' = 'Exit code `2` means the diagnostic completed'
    'admin evidence boundary' = 'Non-admin and elevated runs are different evidence'
}

foreach ($contractItem in $runbookPatterns.GetEnumerator()) {
    if ($runbookSource -notmatch $contractItem.Value) {
        throw "Missing LogonUI agent-runbook contract: $($contractItem.Key)."
    }
}

Write-Host 'PASS: Diagnose-LogonUI evidence and read-only contract checks passed.' -ForegroundColor Green
