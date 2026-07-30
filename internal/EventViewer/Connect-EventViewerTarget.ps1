Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$workshopManifestPath = Join-Path $repoRoot '.assets\WinRMWorkshop\WinRMWorkshop.psd1'
$connectionManifestPath = Join-Path $repoRoot '.assets\WinRMConnection\WinRMConnection.psd1'
foreach ($requiredManifestPath in @($workshopManifestPath, $connectionManifestPath)) {
    if (-not (Test-Path -LiteralPath $requiredManifestPath -PathType Leaf)) {
        throw "Required shared WinRM manifest not found: $requiredManifestPath"
    }
}
Import-Module -Name $workshopManifestPath -Force -ErrorAction Stop
Import-Module -Name $connectionManifestPath -Force -ErrorAction Stop

function Connect-EventViewerTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [string[]]$ComputerAlias,

        [string]$UserName,

        [PSCredential]$Credential,

        [switch]$BlankPassword,

        [AllowEmptyString()]
        [string]$ProfileStateRoot = ''
    )

    $workshopStatusHandler = {
        param($Status)
        if ($null -ne (Get-Command -Name 'Write-EventViewerWinRMWorkshopStatus' -ErrorAction SilentlyContinue)) {
            Write-EventViewerWinRMWorkshopStatus -Status $Status
        } else {
            Write-Host ("[WinRMWorkshop:{0}] {1}" -f $Status.State, $Status.Message)
        }
    }
    $workshopPreparation = Add-WinRMWorkshopTrustedHost `
        -ComputerName $ComputerName `
        -OnStatus $workshopStatusHandler
    if (-not $workshopPreparation.Verified) {
        throw "Exact-target TrustedHosts preparation was not verified for $ComputerName."
    }
    $ComputerName = $workshopPreparation.ComputerName

    $profileNames = @(
        $ComputerName
        $ComputerAlias
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    $credentialSource = if ($Credential) { 'Explicit' } else { 'CurrentUser' }
    if (-not $Credential -and -not $BlankPassword) {
        $Credential = Get-WinRMCredentialProfile -ComputerName $profileNames -StateRoot $ProfileStateRoot
        if ($Credential) {
            $credentialSource = 'SavedProfile'
            Write-Host "[Credential] Using saved DPAPI profile for $ComputerName as $($Credential.UserName)." -ForegroundColor Green
        }
    }

    if (-not $Credential -and $BlankPassword) {
        if ([string]::IsNullOrWhiteSpace($UserName)) {
            throw 'UserName is required when BlankPassword is specified.'
        }

        $Credential = New-WinRMBlankPasswordCredential -UserName $UserName
        $credentialSource = 'BlankPassword'
    } elseif (-not $Credential) {
        $credentialParameters = @{ Message = "Credentials for $ComputerName" }
        if (-not [string]::IsNullOrWhiteSpace($UserName)) {
            $credentialParameters.UserName = $UserName
        }
        $Credential = Get-Credential @credentialParameters
        $credentialSource = 'Prompted'
    }

    if (-not $Credential) {
        throw "No credentials were supplied for $ComputerName."
    }

    Write-Host "WinRM connection: attempt 1/3 will start for $ComputerName." -ForegroundColor Cyan
    $statusHandler = {
        param($Status)
        if ($null -ne (Get-Command -Name 'Write-EventViewerWinRMConnectionStatus' -ErrorAction SilentlyContinue)) {
            Write-EventViewerWinRMConnectionStatus -Status $Status
        } else {
            Write-Host ("[{0}] {1}" -f $Status.State, $Status.Message)
        }
    }

    $openSession = {
        param([PSCredential]$ActiveCredential)

        Connect-WinRMSession `
            -ComputerName $ComputerName `
            -Credential $ActiveCredential `
            -OnStatus $statusHandler
    }

    try {
        $session = & $openSession $Credential
    } catch {
        $category = Get-WinRMConnectionErrorCategory -ErrorObject $_
        if ($credentialSource -ne 'SavedProfile' -or $category -ne 'AuthenticationRejected') {
            throw
        }

        $promptUserName = if ([string]::IsNullOrWhiteSpace($UserName)) { $Credential.UserName } else { $UserName }
        Remove-WinRMCredentialProfile -ComputerName $profileNames -StateRoot $ProfileStateRoot -Confirm:$false
        Write-Warning "Saved credential for $ComputerName was rejected and removed. Enter the current credential once."
        $Credential = Get-Credential -UserName $promptUserName -Message "Credentials for $ComputerName"
        if (-not $Credential) {
            throw "No replacement credential was supplied for $ComputerName."
        }
        $credentialSource = 'Prompted'
        $session = & $openSession $Credential
    }

    if ($credentialSource -eq 'Prompted') {
        Save-WinRMCredentialProfile -ComputerName $profileNames -Credential $Credential -StateRoot $ProfileStateRoot
        Write-Host "[Credential] Saved DPAPI profile for future connections to $ComputerName." -ForegroundColor Green
    }

    $session | Add-Member -NotePropertyName EventViewerCredential -NotePropertyValue $Credential -Force
    $session | Add-Member -NotePropertyName EventViewerCredentialSource -NotePropertyValue $credentialSource -Force
    $session | Add-Member -NotePropertyName EventViewerWorkshopPreparation -NotePropertyValue $workshopPreparation -Force
    return $session
}
