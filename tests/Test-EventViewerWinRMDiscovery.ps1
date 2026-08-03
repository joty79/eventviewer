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

function Get-EventViewerFunctionAst {
    param([Parameter(Mandatory)][string]$Name)

    $functionAst = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $Name
        }, $true)
    if ($null -eq $functionAst) {
        throw "Required EventViewer function was not found: $Name"
    }
    return $functionAst
}

function Get-FunctionCommandNames {
    param([Parameter(Mandatory)]$FunctionAst)

    return @(
        $FunctionAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst]
            }, $true) |
            ForEach-Object { $_.GetCommandName() }
    )
}

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
    'Add-WinRMConnectionHistoryEntry',
    'Get-WinRMTargetCatalog',
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
if ($source -notmatch 'Find-WinRMComputer[\s\S]{0,160}-IncludeDiagnostics\s+-DiagnosticsInMemoryOnly') {
    throw 'Discovery must retain in-memory diagnostics while suppressing module-local scan logs.'
}
if ($source -notmatch 'Resolve-WinRMHistoryTargetAddress') {
    throw 'Saved history targets must be re-resolved before connection.'
}
if ($source -notmatch 'Get-WinRMTargetCatalog\s+-NetworkId\s+\$networkId') {
    throw 'The TUI does not rebuild its immediate local-only target catalog.'
}
if ($source -notmatch 'Find-WinRMComputer\s+-NetworkId\s+\$NetworkId') {
    throw 'Explicit discovery does not update the correct network-scoped snapshot.'
}

$mainTuiCommands = @(Get-FunctionCommandNames -FunctionAst (Get-EventViewerFunctionAst -Name 'Invoke-EventViewerTui'))
if ($mainTuiCommands -notcontains 'Get-WinRMTargetCatalog') {
    throw 'The main TUI does not load the local-only target catalog.'
}
if ($mainTuiCommands -contains 'Resolve-WinRMHistoryTargetAddress') {
    throw 'The main TUI bulk-validates catalog rows before the user selects one.'
}

$presentationFunction = Get-EventViewerFunctionAst -Name 'Get-EventViewerCatalogTargetState'
Invoke-Expression $presentationFunction.Extent.Text
$savedFixture = [PSCustomObject]@{
    HasSavedHistory       = $true
    HasDiscoverySnapshot = $false
    WinRMHttpOpen         = $false
    SMBOpen               = $false
    DetectedOnly          = $false
}
$onlineFixture = [PSCustomObject]@{
    HasSavedHistory       = $true
    HasDiscoverySnapshot = $true
    WinRMHttpOpen         = $true
    SMBOpen               = $true
    DetectedOnly          = $false
}
if ((Get-EventViewerCatalogTargetState -Entry $savedFixture -HasFreshSnapshot $false) -ne 'not checked') {
    throw 'A saved EventViewer target without a fresh scan does not remain not checked.'
}
if ((Get-EventViewerCatalogTargetState -Entry $savedFixture -HasFreshSnapshot $true) -ne 'offline (fresh scan)') {
    throw 'A saved EventViewer target absent from a completed fresh scan is not shown offline.'
}
if ((Get-EventViewerCatalogTargetState -Entry $onlineFixture -HasFreshSnapshot $true) -ne 'online (fresh scan)') {
    throw 'A freshly discovered saved EventViewer target does not retain its online evidence.'
}

$selectedTargetFlow = Get-EventViewerFunctionAst -Name 'Run-HistoryRemoteDiagFlow'
$selectedTargetCommands = @(Get-FunctionCommandNames -FunctionAst $selectedTargetFlow)
if (@($selectedTargetCommands | Where-Object { $_ -eq 'Resolve-WinRMHistoryTargetAddress' }).Count -ne 1) {
    throw 'The selected catalog row must be resolved exactly once before authentication.'
}
if ($selectedTargetFlow.Extent.Text -notmatch 'UserName\s+-eq\s+''Unknown''[\s\S]{0,180}\$UserName') {
    throw 'Snapshot-only catalog rows do not fall back from the Unknown account marker to the normal TUI account default.'
}

Write-Output 'PASS: EventViewer discovery and history are routed through canonical WinRMDiscovery APIs.'
