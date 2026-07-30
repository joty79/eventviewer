[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '', Justification = 'Reserved documentation targets are offline fixtures.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Synthetic fixture credential is never persisted or sent over a network.')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Assert-ThrowsBeforeConnection {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message
    )
    $beforeAttempts = $connectionState.TcpAttempts
    $threw = $false
    try {
        & $Action
    } catch {
        $threw = $true
    }
    Assert-True -Condition $threw -Message $Message
    Assert-True -Condition ($connectionState.TcpAttempts -eq $beforeAttempts) -Message 'Connection preflight ran after workshop preparation failed.'
}

function Write-EventViewerWinRMConnectionStatus { param($Status) $null = $Status }
function Write-EventViewerWinRMWorkshopStatus { param($Status) $null = $Status }

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'internal\EventViewer\Connect-EventViewerTarget.ps1')

$workshopModulePath = (Resolve-Path -LiteralPath (Join-Path $repoRoot '.assets\WinRMWorkshop\WinRMWorkshop.psm1')).Path
$connectionModulePath = (Resolve-Path -LiteralPath (Join-Path $repoRoot '.assets\WinRMConnection\WinRMConnection.psm1')).Path
$workshopModule = Get-Module WinRMWorkshop -All | Where-Object Path -eq $workshopModulePath | Select-Object -First 1
$connectionModule = Get-Module WinRMConnection -All | Where-Object Path -eq $connectionModulePath | Select-Object -First 1
$workshopState = [pscustomobject]@{
    Value          = ''
    SetCalls       = 0
    ElevationCalls = 0
    ApplyMutation  = $true
    IsAdmin        = $true
}
$connectionState = [pscustomobject]@{ TcpAttempts = 0; SessionAttempts = 0 }

$getHook = { return $workshopState.Value }.GetNewClosure()
$setHook = {
    param($value)
    $workshopState.SetCalls++
    if ($workshopState.ApplyMutation) { $workshopState.Value = [string]$value }
}.GetNewClosure()
$adminHook = { return $workshopState.IsAdmin }.GetNewClosure()
$elevationHook = {
    param($value)
    $workshopState.ElevationCalls++
    if ($workshopState.ApplyMutation) { $workshopState.Value = [string]$value }
    return 0
}.GetNewClosure()
$tcpHook = {
    param($targetName, $targetPort, $timeoutMs)
    $null = $targetName, $targetPort, $timeoutMs
    $connectionState.TcpAttempts++
    return [pscustomobject]@{ Open = $true; Category = ''; ErrorMessage = '' }
}.GetNewClosure()
$sessionHook = {
    param($sessionParameters)
    $null = $sessionParameters
    $connectionState.SessionAttempts++
    return [pscustomobject]@{ State = 'Opened' }
}.GetNewClosure()

$password = ConvertTo-SecureString 'offline-fixture' -AsPlainText -Force
$credential = [PSCredential]::new('LAB\Technician', $password)

try {
    & $workshopModule {
        param($get, $set, $admin, $elevate)
        $script:WinRMWorkshopGetTrustedHostsOverride = $get
        $script:WinRMWorkshopSetTrustedHostsOverride = $set
        $script:WinRMWorkshopAdministratorOverride = $admin
        $script:WinRMWorkshopElevationRunnerOverride = $elevate
    } $getHook $setHook $adminHook $elevationHook
    & $connectionModule {
        param($tcp, $session)
        $script:WinRMConnectionTcpProbeOverride = $tcp
        $script:WinRMConnectionSessionFactoryOverride = $session
    } $tcpHook $sessionHook

    $workshopState.Value = 'existing-pc,192.0.2.10'
    $workshopState.SetCalls = 0
    $session = Connect-EventViewerTarget -ComputerName '192.0.2.10' -Credential $credential
    Assert-True -Condition (-not $session.EventViewerWorkshopPreparation.Changed) -Message 'Existing exact target unexpectedly mutated TrustedHosts.'
    Assert-True -Condition ($workshopState.SetCalls -eq 0) -Message 'Existing exact target invoked the TrustedHosts setter.'

    $workshopState.Value = 'existing-pc'
    $workshopState.SetCalls = 0
    $session = Connect-EventViewerTarget -ComputerName '192.0.2.11' -Credential $credential
    Assert-True -Condition ($workshopState.Value -eq 'existing-pc,192.0.2.11') -Message 'Exact-target add did not preserve the existing entry.'
    Assert-True -Condition $session.EventViewerWorkshopPreparation.Verified -Message 'Exact-target add was not reported as verified.'

    $workshopState.Value = '*'
    $session = Connect-EventViewerTarget -ComputerName '192.0.2.12' -Credential $credential
    Assert-True -Condition ($workshopState.Value -eq '192.0.2.12') -Message 'Legacy wildcard was not narrowed to the selected exact target.'
    Assert-True -Condition $session.EventViewerWorkshopPreparation.NarrowedWildcard -Message 'Wildcard narrowing was not exposed to the consumer.'

    foreach ($invalidTarget in @('*', 'pc1,pc2', 'pc?')) {
        Assert-ThrowsBeforeConnection -Action {
            Connect-EventViewerTarget -ComputerName $invalidTarget -Credential $credential
        } -Message "Invalid target '$invalidTarget' was accepted."
    }

    $workshopState.Value = 'existing-pc'
    $workshopState.IsAdmin = $false
    $workshopState.ApplyMutation = $false
    Assert-ThrowsBeforeConnection -Action {
        Connect-EventViewerTarget -ComputerName '192.0.2.13' -Credential $credential
    } -Message 'Failed elevated readback did not stop the connection workflow.'
} finally {
    & $workshopModule {
        $script:WinRMWorkshopGetTrustedHostsOverride = $null
        $script:WinRMWorkshopSetTrustedHostsOverride = $null
        $script:WinRMWorkshopAdministratorOverride = $null
        $script:WinRMWorkshopElevationRunnerOverride = $null
    }
    & $connectionModule {
        $script:WinRMConnectionTcpProbeOverride = $null
        $script:WinRMConnectionSessionFactoryOverride = $null
    }
}

Write-Host 'PASS: EventViewer exact-target workshop preparation, wildcard narrowing, and failure-before-connection.' -ForegroundColor Green
