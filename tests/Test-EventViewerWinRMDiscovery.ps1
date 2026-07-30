[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$mainPath = Join-Path -Path $repoRoot -ChildPath 'Analyze-EventViewer.ps1'
$source = Get-Content -LiteralPath $mainPath -Raw

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $mainPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "Analyze-EventViewer.ps1 has $($parseErrors.Count) parser error(s)."
}

$functionNames = @(
    $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true) |
        ForEach-Object { $_.Name }
)

$forbiddenFunctions = @(
    'Get-CurrentNetworkIdentity',
    'Get-ConnectionHistory',
    'Add-ConnectionHistoryEntry',
    'Get-NetDiscoveredHosts'
)
foreach ($forbiddenFunction in $forbiddenFunctions) {
    if ($functionNames -contains $forbiddenFunction) {
        throw "Legacy discovery/history helper remains: $forbiddenFunction"
    }
}

$requiredCommands = @(
    'Find-WinRMComputer',
    'Get-WinRMNetworkIdentity',
    'Get-WinRMConnectionHistory',
    'Add-WinRMConnectionHistoryEntry',
    'Resolve-WinRMHistoryTargetAddress'
)
$commandNames = @(
    $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true) |
        ForEach-Object { $_.GetCommandName() }
)
foreach ($requiredCommand in $requiredCommands) {
    if ($commandNames -notcontains $requiredCommand) {
        throw "Canonical WinRMDiscovery API is not used: $requiredCommand"
    }
}

if ($source -match 'history\.json') {
    throw 'The EventViewer runtime still references the legacy repo-local history.json store.'
}
if ($source -match 'System\.Net\.Sockets\.TcpClient|ConnectAsync') {
    throw 'Ad-hoc TCP discovery code remains in the EventViewer consumer.'
}
if ($source -notmatch 'Find-WinRMComputer\s+-IncludeDiagnostics\s+-DiagnosticsInMemoryOnly') {
    throw 'Discovery must retain in-memory diagnostics while suppressing module-local scan logs.'
}
if ($source -notmatch 'Resolve-WinRMHistoryTargetAddress') {
    throw 'Saved history targets must be re-resolved before connection.'
}

Write-Output 'PASS: EventViewer discovery and history are routed through canonical WinRMDiscovery APIs.'
