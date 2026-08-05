[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$mainPath = Join-Path $repoRoot 'Analyze-EventViewer.ps1'
$source = Get-Content -LiteralPath $mainPath -Raw
$tokens = $null
$parseErrors = $null
$mainAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $mainPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if (@($parseErrors).Count -gt 0) {
    throw "Analyze-EventViewer.ps1 has parser errors: $($parseErrors.Message -join '; ')"
}

function Get-EventViewerFunctionAst {
    param([Parameter(Mandatory)][string]$Name)

    $functionAst = $mainAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $Name
        }, $true)
    if ($null -eq $functionAst) {
        throw "Required EventViewer function was not found: $Name"
    }
    return $functionAst
}

$verifiedMutationAst = Get-EventViewerFunctionAst -Name 'Invoke-VerifiedFastStartupDisable'
. ([ScriptBlock]::Create($verifiedMutationAst.Extent.Text))

$mutablePreference = [pscustomobject]@{
    Value  = 1
    Writes = 0
}
$changedResult = Invoke-VerifiedFastStartupDisable `
    -ReadPreference { $mutablePreference.Value } `
    -WriteDisabledPreference {
        $mutablePreference.Writes++
        $mutablePreference.Value = 0
    }
if (-not $changedResult.Verified -or -not $changedResult.Changed) {
    throw 'Fast Startup test mutation was not verified as a changed 1 -> 0 result.'
}
if ($changedResult.BeforeValue -ne 1 -or $changedResult.AfterValue -ne 0 -or $mutablePreference.Writes -ne 1) {
    throw 'Fast Startup before/write/readback evidence was incorrect.'
}

$alreadyDisabledPreference = [pscustomobject]@{
    Value  = 0
    Writes = 0
}
$unchangedResult = Invoke-VerifiedFastStartupDisable `
    -ReadPreference { $alreadyDisabledPreference.Value } `
    -WriteDisabledPreference {
        $alreadyDisabledPreference.Writes++
        $alreadyDisabledPreference.Value = 0
    }
if (-not $unchangedResult.Verified -or $unchangedResult.Changed) {
    throw 'Already-disabled Fast Startup state was not verified as unchanged.'
}
if ($alreadyDisabledPreference.Writes -ne 0) {
    throw 'Already-disabled Fast Startup state was rewritten unnecessarily.'
}

$failedReadbackPreference = [pscustomobject]@{
    Value = 1
}
$failedReadbackResult = Invoke-VerifiedFastStartupDisable `
    -ReadPreference { $failedReadbackPreference.Value } `
    -WriteDisabledPreference { }
if ($failedReadbackResult.Verified -or $failedReadbackResult.Success) {
    throw 'Failed Fast Startup readback was incorrectly reported as success.'
}

$disableActionSource = (Get-EventViewerFunctionAst -Name 'Disable-FastStartupAction').Extent.Text
foreach ($requiredPattern in @(
        '\$LASTEXITCODE',
        'EVENTVIEWER_FASTSTARTUP_RESULT',
        'TargetBlankPassword',
        'RemoteAuthenticatedSession',
        'New-FastStartupFailureResult'
    )) {
    if ($disableActionSource -notmatch $requiredPattern) {
        throw "Fast Startup action is missing required verification behavior: $requiredPattern"
    }
}
if ($disableActionSource -match 'return\s+\$true') {
    throw 'Fast Startup action still contains an unverified unconditional success return.'
}

$elevatedBodyAst = $mainAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $node.Value -match 'EVENTVIEWER_FASTSTARTUP_RESULT'
    }, $true)
if ($null -eq $elevatedBodyAst) {
    throw 'The exact elevated Fast Startup command body was not found.'
}
$inlineTokens = $null
$inlineParseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput(
    $elevatedBodyAst.Value,
    [ref]$inlineTokens,
    [ref]$inlineParseErrors
)
if (@($inlineParseErrors).Count -gt 0) {
    throw "The exact elevated Fast Startup command body has parser errors: $($inlineParseErrors.Message -join '; ')"
}

$tuiContractPatterns = [ordered]@{
    'explicit Fast Startup confirmation' = 'Confirm-FastStartupDisableAction'
    'before/after user-facing evidence' = 'Registry change verified: HiberbootEnabled'
    'blank-password TUI choice' = 'B\s+= intentionally blank password'
    'credential/profile TUI choice' = 'saved DPAPI credential or secure credential prompt'
    'blank-password state preserved for action' = 'WinRMBlankPassword'
    'height-bounded diagnostic rows' = '\$maxVisibleLines = \[Math\]::Max\(1, \$Height - 11\)'
    'height-bounded discovery rows' = '\$maxVisible = \[Math\]::Max\(1, \$height - 10\)'
    'height-bounded main-menu rows' = '\$maxVisibleMenuItems = \[Math\]::Max\(1, \$height - 10\)'
    'actual Ctrl+L character handling' = '\$key\.KeyChar -eq \[char\]12'
}
foreach ($contractItem in $tuiContractPatterns.GetEnumerator()) {
    if ($source -notmatch $contractItem.Value) {
        throw "Missing EventViewer TUI contract: $($contractItem.Key)."
    }
}

if ($source -match 'DefaultUser\s+"cbx_t"') {
    throw 'A target-specific cbx_t account default remains in the TUI flow.'
}
if ($source -match 'Successfully disabled Fast Startup!') {
    throw 'The TUI still contains an unverified generic Fast Startup success claim.'
}
if ($source -match '= fix FastStartup') {
    throw 'The TUI still labels the Fast Startup registry preference as a proven fix.'
}

Write-Host 'PASS: EventViewer TUI credential, mutation-readback, and viewport contracts passed.' -ForegroundColor Green
