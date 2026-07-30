Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:WinRMWorkshopGetTrustedHostsOverride = $null
$script:WinRMWorkshopSetTrustedHostsOverride = $null
$script:WinRMWorkshopIsAdministratorOverride = $null
$script:WinRMWorkshopElevationRunnerOverride = $null

function Write-WinRMWorkshopStatus {
    param(
        [AllowNull()][scriptblock]$OnStatus,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$Message
    )

    if ($null -ne $OnStatus) {
        & $OnStatus ([pscustomobject]@{
            PSTypeName   = 'WinRMWorkshop.Status'
            State        = $State
            ComputerName = $ComputerName
            Message      = $Message
        })
    }
}

function Assert-WinRMWorkshopComputerName {
    param([Parameter(Mandatory)][string]$ComputerName)

    $normalized = $ComputerName.Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw 'ComputerName cannot be empty.'
    }
    if ($normalized.IndexOf(',') -ge 0 -or $normalized.IndexOf('*') -ge 0 -or $normalized.IndexOf('?') -ge 0) {
        throw "ComputerName must be one exact host or IP without commas or wildcards: '$ComputerName'."
    }
    return $normalized
}

function Get-WinRMWorkshopTrustedHostsValue {
    if ($null -ne $script:WinRMWorkshopGetTrustedHostsOverride) {
        return [string](& $script:WinRMWorkshopGetTrustedHostsOverride)
    }

    $item = Get-Item -Path 'WSMan:\localhost\Client\TrustedHosts' -ErrorAction Stop
    return [string]$item.Value
}

function ConvertFrom-WinRMWorkshopTrustedHostsValue {
    param([AllowEmptyString()][string]$Value = '')

    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @(
        $Value -split ',' |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Test-WinRMWorkshopAdministrator {
    if ($null -ne $script:WinRMWorkshopIsAdministratorOverride) {
        return [bool](& $script:WinRMWorkshopIsAdministratorOverride)
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-WinRMWorkshopTrustedHostsValue {
    param([AllowEmptyString()][string]$Value)

    if ($null -ne $script:WinRMWorkshopSetTrustedHostsOverride) {
        & $script:WinRMWorkshopSetTrustedHostsOverride $Value
        return
    }

    Set-Item -Path 'WSMan:\localhost\Client\TrustedHosts' -Value $Value -Force -ErrorAction Stop
}

function New-WinRMWorkshopEncodedMutation {
    param([AllowEmptyString()][string]$DesiredValue)

    $desiredBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($DesiredValue))
    $body = @"
`$ErrorActionPreference = 'Stop'
`$desiredBytes = [Convert]::FromBase64String('$desiredBase64')
`$desiredValue = [Text.Encoding]::UTF8.GetString(`$desiredBytes)
Set-Item -Path 'WSMan:\localhost\Client\TrustedHosts' -Value `$desiredValue -Force -ErrorAction Stop
`$actualValue = [string](Get-Item -Path 'WSMan:\localhost\Client\TrustedHosts' -ErrorAction Stop).Value
if (`$actualValue -ne `$desiredValue) {
    throw "TrustedHosts readback mismatch. Expected '`$desiredValue', found '`$actualValue'."
}
"@
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
}

function Invoke-WinRMWorkshopElevatedMutation {
    param(
        [AllowEmptyString()][string]$DesiredValue,
        [bool]$AllowUacFallback
    )

    if ($null -ne $script:WinRMWorkshopElevationRunnerOverride) {
        $overrideExitCode = & $script:WinRMWorkshopElevationRunnerOverride $DesiredValue
        if ([int]$overrideExitCode -ne 0) {
            throw "Test elevation runner failed with exit code $overrideExitCode."
        }
        return 'TestOverride'
    }

    $encodedCommand = New-WinRMWorkshopEncodedMutation -DesiredValue $DesiredValue
    $hostExecutable = (Get-Process -Id $PID -ErrorAction Stop).Path
    $hostCommandName = [IO.Path]::GetFileName($hostExecutable)
    $gsudoCommand = Get-Command -Name 'gsudo.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($null -ne $gsudoCommand) {
        & $gsudoCommand.Source $hostCommandName -NoProfile -EncodedCommand $encodedCommand
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "gsudo.exe TrustedHosts mutation failed with exit code $exitCode."
        }
        return 'gsudo.exe'
    }

    if (-not $AllowUacFallback) {
        throw 'TrustedHosts requires elevation and direct gsudo.exe is unavailable. UAC fallback is disabled.'
    }

    $process = Start-Process `
        -FilePath $hostExecutable `
        -ArgumentList @('-NoProfile', '-EncodedCommand', $encodedCommand) `
        -Verb RunAs `
        -Wait `
        -PassThru `
        -ErrorAction Stop
    if ($process.ExitCode -ne 0) {
        throw "Elevated UAC TrustedHosts mutation failed with exit code $($process.ExitCode)."
    }
    return 'UAC'
}

function Set-WinRMWorkshopTrustedHostsVerified {
    param(
        [AllowEmptyString()][string]$DesiredValue,
        [ValidateSet('Auto', 'None')][string]$ElevationMode,
        [bool]$AllowUacFallback
    )

    if (Test-WinRMWorkshopAdministrator) {
        Set-WinRMWorkshopTrustedHostsValue -Value $DesiredValue
        return 'CurrentProcess'
    }
    if ($ElevationMode -eq 'None') {
        throw 'TrustedHosts requires elevation, but ElevationMode is None.'
    }
    return Invoke-WinRMWorkshopElevatedMutation -DesiredValue $DesiredValue -AllowUacFallback $AllowUacFallback
}

function Get-WinRMWorkshopTrustedHost {
    [CmdletBinding()]
    param()

    $value = Get-WinRMWorkshopTrustedHostsValue
    foreach ($entry in @(ConvertFrom-WinRMWorkshopTrustedHostsValue -Value $value)) {
        $entry
    }
}

function Add-WinRMWorkshopTrustedHost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [ValidateSet('Auto', 'None')][string]$ElevationMode = 'Auto',
        [bool]$AllowUacFallback = [Environment]::UserInteractive,
        [AllowNull()][scriptblock]$OnStatus
    )

    $target = Assert-WinRMWorkshopComputerName -ComputerName $ComputerName
    Write-WinRMWorkshopStatus -OnStatus $OnStatus -State 'Checking' -ComputerName $target -Message "Checking exact-target TrustedHosts entry for $target."

    $beforeValue = Get-WinRMWorkshopTrustedHostsValue
    $beforeEntries = @(ConvertFrom-WinRMWorkshopTrustedHostsValue -Value $beforeValue)
    $hasWildcard = $beforeEntries -contains '*'
    if (-not $hasWildcard -and $beforeEntries -contains $target) {
        Write-WinRMWorkshopStatus -OnStatus $OnStatus -State 'Ready' -ComputerName $target -Message "$target is already present as an exact TrustedHosts entry."
        return [pscustomobject]@{
            PSTypeName    = 'WinRMWorkshop.PreparationResult'
            ComputerName  = $target
            Changed       = $false
            Verified      = $true
            NarrowedWildcard = $false
            ElevationPath = 'NotRequired'
            BeforeValue   = $beforeValue
            AfterValue    = $beforeValue
        }
    }

    $desiredEntries = if ($hasWildcard) {
        @($target)
    } else {
        @($beforeEntries + $target | Select-Object -Unique)
    }
    $desiredValue = $desiredEntries -join ','
    $statusState = if ($hasWildcard) { 'Narrowing' } else { 'Elevating' }
    $statusMessage = if ($hasWildcard) {
        "Replacing legacy wildcard TrustedHosts with exact target $target."
    } else {
        "Adding only $target to TrustedHosts with verified elevation."
    }
    Write-WinRMWorkshopStatus -OnStatus $OnStatus -State $statusState -ComputerName $target -Message $statusMessage
    $elevationPath = Set-WinRMWorkshopTrustedHostsVerified `
        -DesiredValue $desiredValue `
        -ElevationMode $ElevationMode `
        -AllowUacFallback $AllowUacFallback

    $afterValue = Get-WinRMWorkshopTrustedHostsValue
    $afterEntries = @(ConvertFrom-WinRMWorkshopTrustedHostsValue -Value $afterValue)
    if ($afterEntries -contains '*' -or -not ($afterEntries -contains $target)) {
        throw "TrustedHosts verification failed after adding exact target '$target'."
    }

    Write-WinRMWorkshopStatus -OnStatus $OnStatus -State 'Ready' -ComputerName $target -Message "$target was added and verified in TrustedHosts."
    return [pscustomobject]@{
        PSTypeName    = 'WinRMWorkshop.PreparationResult'
        ComputerName  = $target
        Changed       = $true
        Verified      = $true
        NarrowedWildcard = $hasWildcard
        ElevationPath = $elevationPath
        BeforeValue   = $beforeValue
        AfterValue    = $afterValue
    }
}

function Remove-WinRMWorkshopTrustedHost {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [ValidateSet('Auto', 'None')][string]$ElevationMode = 'Auto',
        [bool]$AllowUacFallback = [Environment]::UserInteractive,
        [AllowNull()][scriptblock]$OnStatus
    )

    $target = Assert-WinRMWorkshopComputerName -ComputerName $ComputerName
    $beforeValue = Get-WinRMWorkshopTrustedHostsValue
    $beforeEntries = @(ConvertFrom-WinRMWorkshopTrustedHostsValue -Value $beforeValue)
    if ($beforeEntries -contains '*') {
        throw 'TrustedHosts currently contains wildcard *. Exact-target removal cannot safely narrow an unknown broad policy.'
    }
    if (-not ($beforeEntries -contains $target)) {
        return [pscustomobject]@{
            PSTypeName    = 'WinRMWorkshop.PreparationResult'
            ComputerName  = $target
            Changed       = $false
            Verified      = $true
            NarrowedWildcard = $false
            ElevationPath = 'NotRequired'
            BeforeValue   = $beforeValue
            AfterValue    = $beforeValue
        }
    }
    if (-not $PSCmdlet.ShouldProcess($target, 'Remove exact WinRM TrustedHosts entry')) { return }

    $desiredEntries = @($beforeEntries | Where-Object { $_ -ine $target })
    $desiredValue = $desiredEntries -join ','
    Write-WinRMWorkshopStatus -OnStatus $OnStatus -State 'Elevating' -ComputerName $target -Message "Removing only $target from TrustedHosts with verified elevation."
    $elevationPath = Set-WinRMWorkshopTrustedHostsVerified `
        -DesiredValue $desiredValue `
        -ElevationMode $ElevationMode `
        -AllowUacFallback $AllowUacFallback

    $afterValue = Get-WinRMWorkshopTrustedHostsValue
    $afterEntries = @(ConvertFrom-WinRMWorkshopTrustedHostsValue -Value $afterValue)
    if ($afterEntries -contains $target) {
        throw "TrustedHosts verification failed after removing exact target '$target'."
    }

    Write-WinRMWorkshopStatus -OnStatus $OnStatus -State 'Removed' -ComputerName $target -Message "$target was removed and the remaining TrustedHosts list was preserved."
    return [pscustomobject]@{
        PSTypeName    = 'WinRMWorkshop.PreparationResult'
        ComputerName  = $target
        Changed       = $true
        Verified      = $true
        NarrowedWildcard = $false
        ElevationPath = $elevationPath
        BeforeValue   = $beforeValue
        AfterValue    = $afterValue
    }
}

Export-ModuleMember -Function @(
    'Add-WinRMWorkshopTrustedHost'
    'Get-WinRMWorkshopTrustedHost'
    'Remove-WinRMWorkshopTrustedHost'
)
