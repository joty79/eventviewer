[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '', Justification = 'Reserved target names are offline mocked fixtures.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Synthetic fixture values validate DPAPI round-trip behavior and are not real secrets.')]
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

function Write-EventViewerWinRMConnectionStatus {
    param($Status)
    $null = $Status
}

function Write-EventViewerWinRMWorkshopStatus {
    param($Status)
    $null = $Status
}

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'internal\EventViewer\Connect-EventViewerTarget.ps1')

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "EventViewerCredentialTest-$PID-$([guid]::NewGuid().ToString('N'))"
$connectionModulePath = (Resolve-Path -LiteralPath (Join-Path $repoRoot '.assets\WinRMConnection\WinRMConnection.psm1')).Path
$workshopModulePath = (Resolve-Path -LiteralPath (Join-Path $repoRoot '.assets\WinRMWorkshop\WinRMWorkshop.psm1')).Path
$module = Get-Module WinRMConnection -All | Where-Object Path -eq $connectionModulePath | Select-Object -First 1
$workshopModule = Get-Module WinRMWorkshop -All | Where-Object Path -eq $workshopModulePath | Select-Object -First 1
try {
    $workshopState = [pscustomobject]@{ Value = '192.0.2.55' }
    $workshopGetHook = { return $workshopState.Value }.GetNewClosure()
    $workshopSetHook = { param($value) $workshopState.Value = [string]$value }.GetNewClosure()
    & $workshopModule {
        param($get, $set)
        $script:WinRMWorkshopGetTrustedHostsOverride = $get
        $script:WinRMWorkshopSetTrustedHostsOverride = $set
        $script:WinRMWorkshopAdministratorOverride = { $true }
    } $workshopGetHook $workshopSetHook

    $oldPassword = ConvertTo-SecureString 'old-fixture' -AsPlainText -Force
    $oldCredential = [PSCredential]::new('LAB\OldUser', $oldPassword)
    Save-WinRMCredentialProfile -ComputerName 'test-target-name' -Credential $oldCredential -StateRoot $temporaryRoot

    $state = [pscustomobject]@{ UserNames = [System.Collections.Generic.List[string]]::new() }
    $tcpHook = {
        param($targetName, $targetPort, $timeoutMs)
        $null = $targetName, $targetPort, $timeoutMs
        [pscustomobject]@{ Open = $true; Category = ''; ErrorMessage = '' }
    }
    $sessionHook = {
        param($sessionParameters)
        $state.UserNames.Add($sessionParameters.Credential.UserName)
        if ($sessionParameters.Credential.UserName -eq 'LAB\OldUser') {
            throw [System.UnauthorizedAccessException]::new('Access is denied.')
        }
        [pscustomobject]@{ State = 'Opened' }
    }.GetNewClosure()
    & $module {
        param($tcpOverride, $sessionOverride)
        $script:WinRMConnectionTcpProbeOverride = $tcpOverride
        $script:WinRMConnectionSessionFactoryOverride = $sessionOverride
    } $tcpHook $sessionHook

    $newPassword = ConvertTo-SecureString 'new-fixture' -AsPlainText -Force
    $newCredential = [PSCredential]::new('LAB\NewUser', $newPassword)
    function global:Get-Credential {
        param([string]$UserName, [string]$Message)
        $null = $UserName, $Message
        return $newCredential
    }

    $session = Connect-EventViewerTarget `
        -ComputerName '192.0.2.55' `
        -ComputerAlias 'test-target-name' `
        -UserName 'LAB\NewUser' `
        -ProfileStateRoot $temporaryRoot

    Assert-True -Condition ([string]$session.State -eq 'Opened') -Message 'Replacement credential did not open the mocked session.'
    Assert-True -Condition ($state.UserNames.Count -eq 2) -Message 'Expected one cached attempt and one prompted replacement attempt.'
    Assert-True -Condition ($state.UserNames[0] -eq 'LAB\OldUser') -Message 'Saved DPAPI credential alias was not tried first.'
    Assert-True -Condition ($state.UserNames[1] -eq 'LAB\NewUser') -Message 'Replacement credential was not used after rejection.'
    Assert-True -Condition ($session.EventViewerCredentialSource -eq 'Prompted') -Message 'Credential source metadata is incorrect.'
    Assert-True -Condition $session.EventViewerWorkshopPreparation.Verified -Message 'Exact-target workshop preparation was not attached to the session.'

    $savedByIp = Get-WinRMCredentialProfile -ComputerName '192.0.2.55' -StateRoot $temporaryRoot
    $savedByName = Get-WinRMCredentialProfile -ComputerName 'test-target-name' -StateRoot $temporaryRoot
    foreach ($savedCredential in @($savedByIp, $savedByName)) {
        Assert-True -Condition ($savedCredential.UserName -eq 'LAB\NewUser') -Message 'Successful replacement credential was not saved for every target alias.'
        Assert-True -Condition ($savedCredential.GetNetworkCredential().Password -eq 'new-fixture') -Message 'Persisted replacement credential did not round-trip.'
    }
} finally {
    & $module {
        $script:WinRMConnectionTcpProbeOverride = $null
        $script:WinRMConnectionSessionFactoryOverride = $null
    }
    & $workshopModule {
        $script:WinRMWorkshopGetTrustedHostsOverride = $null
        $script:WinRMWorkshopSetTrustedHostsOverride = $null
        $script:WinRMWorkshopAdministratorOverride = $null
        $script:WinRMWorkshopElevationRunnerOverride = $null
    }
    Remove-Item Function:\global:Get-Credential -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

Write-Host 'PASS: EventViewer DPAPI credential reuse, alias lookup, and stale replacement.' -ForegroundColor Green
