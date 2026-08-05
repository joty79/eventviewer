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

$script:FixtureLines = @(
    ('0123456789' * 14)
    'SHORT-LINE'
    'EVIDENCE: a medium diagnostic line that is intentionally wider than a narrow viewport.'
    'F disable preference must stay discoverable'
    'Esc back must stay discoverable'
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

$fixture = [pscustomobject]@{}
$widths = @(120, 101, 100, 99, 98, 80, 60, 50, 35)
foreach ($width in $widths) {
    $view = Get-EventViewerDiagReportFrame `
        -Title 'Gold resize test' `
        -diagData $fixture `
        -Width $width `
        -Height 24 `
        -ScrollOffset 0 `
        -HorizontalOffset 0
    $plainLines = @(Get-PlainFrameLines -Frame $view.Frame.ToString())

    if ($plainLines.Count -gt 23) {
        throw "Frame used $($plainLines.Count) rows at width $width; expected at most 23."
    }
    foreach ($line in $plainLines) {
        if ($line.Length -gt $width) {
            throw "Frame row width $($line.Length) exceeded $width columns: '$line'"
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
}

$narrowView = Get-EventViewerDiagReportFrame `
    -Title 'Gold pan test' `
    -diagData $fixture `
    -Width 50 `
    -Height 24 `
    -ScrollOffset 0 `
    -HorizontalOffset ([int]::MaxValue)
if ($narrowView.HorizontalOffset -ne $narrowView.MaximumHorizontalOffset) {
    throw 'Horizontal offset was not clamped to the current maximum after resize/pan.'
}

$narrowLines = @(Get-PlainFrameLines -Frame $narrowView.Frame.ToString())
$narrowBoxRows = @(Get-ReportBoxRows -Lines $narrowLines)
if ($narrowBoxRows[2] -match 'SHORT-LINE') {
    throw 'Short lines used an independent clamped offset instead of the shared horizontal viewport.'
}

$resizeWidths = @(120, 101, 100, 99, 98, 80, 60, 120)
$horizontalOffset = 25
$scrollOffset = 999
foreach ($width in $resizeWidths) {
    $view = Get-EventViewerDiagReportFrame `
        -Title 'Gold resize state test' `
        -diagData $fixture `
        -Width $width `
        -Height 24 `
        -ScrollOffset $scrollOffset `
        -HorizontalOffset $horizontalOffset
    $horizontalOffset = $view.HorizontalOffset
    $scrollOffset = $view.ScrollOffset

    if ($horizontalOffset -lt 0 -or $horizontalOffset -gt $view.MaximumHorizontalOffset) {
        throw "Horizontal offset escaped its bounds at width $width."
    }
    if ($scrollOffset -lt 0 -or $scrollOffset -gt $view.MaximumScrollOffset) {
        throw "Scroll offset escaped its bounds at width $width."
    }
}

$wideView = Get-EventViewerDiagReportFrame `
    -Title 'Gold no-pan test' `
    -diagData $fixture `
    -Width 200 `
    -Height 24 `
    -ScrollOffset 0 `
    -HorizontalOffset 999
if ($wideView.MaximumHorizontalOffset -ne 0 -or $wideView.HorizontalOffset -ne 0) {
    throw 'Pan state was not removed when the report fit the wider viewport.'
}
$wideLines = @(Get-PlainFrameLines -Frame $wideView.Frame.ToString())
if (($wideLines -join "`n") -match 'diagnostic pan') {
    throw 'Pan indicator remained visible without horizontal overflow.'
}
if ($wideLines.Count -gt 23) {
    throw 'Frame height exceeded its budget when the pan indicator disappeared.'
}

Write-Host 'PASS: EventViewer production renderer preserves width, actions, shared pan state, and resize bounds.' -ForegroundColor Green
