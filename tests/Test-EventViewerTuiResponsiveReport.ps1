[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$mainPath = Join-Path $repoRoot 'Analyze-EventViewer.ps1'
$blueprintCandidates = @(
    (Join-Path $env:USERPROFILE '.agent-shared\templates\PS_UI_Blueprint.psm1')
    'C:\Users\joty79\.agent-shared\templates\PS_UI_Blueprint.psm1'
    'D:\Users\joty79\.agent-shared\templates\PS_UI_Blueprint.psm1'
) | Select-Object -Unique
$blueprintPath = @(
    $blueprintCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
) | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($blueprintPath)) {
    throw 'Canonical PS_UI_Blueprint.psm1 was not found.'
}

Invoke-Expression (Get-Content -LiteralPath $blueprintPath -Raw)

$tokens = $null
$parseErrors = $null
$mainAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $mainPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if (@($parseErrors).Count -gt 0) {
    throw "Analyze-EventViewer.ps1 parser errors: $($parseErrors.Message -join '; ')"
}

function Get-EventViewerFunctionAst {
    param([Parameter(Mandatory)][string]$Name)

    $functionAst = $mainAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $Name
        }, $true)
    if ($null -eq $functionAst) {
        throw "Required function not found: $Name"
    }
    return $functionAst
}

. ([ScriptBlock]::Create((Get-EventViewerFunctionAst -Name 'Get-EventViewerDiagReportFrame').Extent.Text))

$directionalMark = [string][char]0x200E
$script:FixtureLines = @(
    '======================================================================'
    '            EVENTVIEWER SYSTEM DIAGNOSTICS REPORT'
    ''
    '  This diagnostic observation must reflow at word boundaries without losing any evidence when the terminal becomes narrow.'
    '  BIOS Version: LCCN27WW (Release: 09/23/2025 03:00:00)'
    '  LONG-TOKEN-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    '  Fast Startup (Hiberboot): REGISTRY PREFERENCE DISABLED'
    "  EventLog 6008 time ${directionalMark}3:14:29${directionalMark} PM on ${directionalMark}7/26/2026"
    '  E export, F disable preference, and Esc back must stay discoverable.'
)

function Get-FormattedDiagLines {
    param($diagData)
    return @($script:FixtureLines)
}

function Remove-Ansi {
    param([AllowEmptyString()][string]$Text = '')
    return $Text -replace "\x1B\[[0-9;?]*[ -/]*[@-~]", ''
}

function Get-PlainFrameLines {
    param([Parameter(Mandatory)][string]$Frame)

    $lines = @(($Frame -replace "`r", '').Split("`n"))
    if ($lines.Count -gt 0 -and $lines[-1] -eq '') {
        if ($lines.Count -eq 1) { return @() }
        $lines = $lines[0..($lines.Count - 2)]
    }
    return @($lines | ForEach-Object { Remove-Ansi -Text $_ })
}

function Get-ReportBoxRows {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)

    $topLeft = Get-UiGlyph -Name BoxTopLeft
    $bottomLeft = Get-UiGlyph -Name BoxBottomLeft
    $vertical = Get-UiGlyph -Name BoxV
    $topIndex = -1
    $bottomIndex = -1

    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index].StartsWith($topLeft)) { $topIndex = $index }
        if ($Lines[$index].StartsWith($bottomLeft)) { $bottomIndex = $index }
    }
    if ($topIndex -lt 0 -or $bottomIndex -le $topIndex) {
        throw 'Diagnostic report box was not found in the rendered frame.'
    }

    $rows = [System.Collections.Generic.List[string]]::new()
    $rows.Add($Lines[$topIndex])
    for ($index = $topIndex + 1; $index -lt $bottomIndex; $index++) {
        if ($Lines[$index].StartsWith($vertical)) { $rows.Add($Lines[$index]) }
    }
    $rows.Add($Lines[$bottomIndex])
    return @($rows)
}

function Get-WhitespaceFreeText {
    param([AllowEmptyString()][string]$Text = '')
    return $Text -replace '\s+', ''
}

$fixture = [pscustomobject]@{}
$widths = @(120, 101, 100, 99, 98, 80, 60, 50, 35)
$displayCounts = @{}
foreach ($width in $widths) {
    $view = Get-EventViewerDiagReportFrame `
        -Title 'Responsive resize test' `
        -diagData $fixture `
        -Width $width `
        -Height 24 `
        -ScrollOffset 0
    $plainLines = @(Get-PlainFrameLines -Frame $view.Frame.ToString())
    $displayCounts[$width] = $view.DisplayLines.Count

    if ($plainLines.Count -gt 23) {
        throw "Frame used $($plainLines.Count) rows at width $width; expected at most 23."
    }
    foreach ($line in $plainLines) {
        if ($line.Length -gt $width) {
            throw "Frame row width $($line.Length) exceeded $width columns: '$line'"
        }
    }
    foreach ($displayLine in $view.DisplayLines) {
        if ($displayLine.Length -gt ($width - 4)) {
            throw "Responsive report line exceeded its $($width - 4)-column content width: '$displayLine'"
        }
        if ($displayLine -match '\p{Cf}|\p{Cc}') {
            throw "A zero-column Unicode format/control character survived display normalization: '$displayLine'"
        }
    }

    $boxRows = @(Get-ReportBoxRows -Lines $plainLines)
    $boxWidths = @($boxRows | ForEach-Object Length | Select-Object -Unique)
    if ($boxWidths.Count -ne 1 -or $boxWidths[0] -ne $width) {
        throw "Report box rows were not uniformly $width columns: $($boxWidths -join ', ')."
    }

    $footer = $plainLines[-1]
    foreach ($requiredKey in @('E', 'F', 'Esc')) {
        if ($footer -cnotmatch "\b$([regex]::Escape($requiredKey))\b") {
            throw "Footer key '$requiredKey' was not discoverable at width ${width}: '$footer'"
        }
    }

    $renderedText = $plainLines -join "`n"
    if ($renderedText -match 'diagnostic pan|columns|Left/Right') {
        throw "Wrappable prose produced a false horizontal-pan affordance at width $width."
    }

    $expectedSeparator = '=' * ($width - 4)
    if ($view.DisplayLines -cnotcontains $expectedSeparator) {
        throw "The report separator did not resize to the $($width - 4)-column content width."
    }

    $allDisplayText = Get-WhitespaceFreeText -Text ($view.DisplayLines -join '')
    foreach ($sourceLine in $script:FixtureLines | Where-Object { $_ -notmatch '^\s*=+\s*$' }) {
        $sourceText = Get-WhitespaceFreeText -Text (ConvertTo-UiSafeSingleLineText -Text $sourceLine)
        if ($sourceText.Length -gt 0 -and -not $allDisplayText.Contains($sourceText)) {
            throw "Responsive wrapping lost source data at width ${width}: '$sourceLine'"
        }
    }
}

if ($displayCounts[35] -le $displayCounts[120]) {
    throw 'Narrowing the viewport did not reflow prose onto additional display lines.'
}

$resizeWidths = @(120, 101, 100, 99, 98, 80, 60, 120)
$scrollOffset = 999
foreach ($width in $resizeWidths) {
    $view = Get-EventViewerDiagReportFrame `
        -Title 'Responsive state test' `
        -diagData $fixture `
        -Width $width `
        -Height 24 `
        -ScrollOffset $scrollOffset
    $scrollOffset = $view.ScrollOffset
    if ($scrollOffset -lt 0 -or $scrollOffset -gt $view.MaximumScrollOffset) {
        throw "Vertical offset escaped its reflowed bounds at width $width."
    }
}

Write-Host 'PASS: EventViewer production renderer reflows prose, preserves evidence, and exposes no false column bar.' -ForegroundColor Green
