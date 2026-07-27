Set-StrictMode -Version Latest

$script:WinRMConnectionSessionFactoryOverride = $null
$script:WinRMConnectionTcpProbeOverride = $null

function Get-WinRMConnectionErrorCategory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object]$ErrorObject
    )

    process {
        if ($null -eq $ErrorObject) {
            return 'Unknown'
        }

        $exception = $null
        $fullyQualifiedErrorId = ''
        if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) {
            $exception = $ErrorObject.Exception
            $fullyQualifiedErrorId = [string]$ErrorObject.FullyQualifiedErrorId
        } elseif ($ErrorObject -is [System.Exception]) {
            $exception = $ErrorObject
        } elseif ($ErrorObject.PSObject.Properties['Exception']) {
            $exception = $ErrorObject.Exception
        }

        if ($null -ne $exception -and $exception.Data.Contains('WinRMConnectionCategory')) {
            return [string]$exception.Data['WinRMConnectionCategory']
        }

        $message = if ($null -ne $exception) {
            [string]$exception.Message
        } else {
            [string]$ErrorObject
        }
        $exceptionType = if ($null -ne $exception) { $exception.GetType().FullName } else { '' }
        $evidence = "$message $fullyQualifiedErrorId $exceptionType"

        if ($evidence -match '(?i)access is denied|logon failure|user name or password|username or password|credentials? (?:were |was )?rejected|authentication failed|0x8009030[ce]') {
            return 'AuthenticationRejected'
        }
        if ($evidence -match '(?i)trustedhosts|cannot use the default authentication with an IP address|kerberos.*(?:cannot|failed)|https transport must be used') {
            return 'TrustedHosts'
        }
        if ($evidence -match '(?i)no such host|name resolution|could not be resolved|cannot be resolved|network path was not found|known such host') {
            return 'NameResolution'
        }
        if ($evidence -match '(?i)timed out|time[- ]?out|operation timeout|0x80338126|TimeoutException') {
            return 'Timeout'
        }
        if ($evidence -match '(?i)actively refused|connection refused|target machine actively refused') {
            return 'ConnectionRefused'
        }
        if ($evidence -match '(?i)configuration name.*(?:not found|cannot be found)|cannot find the requested shell|plugin.*not found') {
            return 'Configuration'
        }
        if ($evidence -match '(?i)cannot connect to the destination|winrm service is not running|firewall exception|WSManFault') {
            return 'EndpointUnavailable'
        }
        if ($evidence -match '(?i)PSRemotingTransportException|WinRM|WSMan|transport') {
            return 'Transport'
        }

        return 'Unknown'
    }
}

function Test-WinRMConnectionRetryCategory {
    param([Parameter(Mandatory)][string]$Category)

    return $Category -in @(
        'ConnectionRefused'
        'EndpointUnavailable'
        'TcpUnavailable'
        'Timeout'
        'Transport'
        'Unknown'
    )
}

function New-WinRMConnectionStatus {
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][int]$Attempt,
        [Parameter(Mandatory)][int]$MaxAttempts,
        [Parameter(Mandatory)][string]$Message,
        [string]$Category = '',
        [int]$DelayMilliseconds = 0,
        [long]$ElapsedMilliseconds = 0
    )

    return [PSCustomObject]@{
        PSTypeName        = 'WinRMConnection.Status'
        Timestamp         = Get-Date
        State             = $State
        ComputerName      = $ComputerName
        Attempt           = $Attempt
        MaxAttempts       = $MaxAttempts
        Category          = $Category
        DelayMilliseconds = $DelayMilliseconds
        ElapsedMilliseconds = $ElapsedMilliseconds
        Message           = $Message
    }
}

function Publish-WinRMConnectionStatus {
    param(
        [Parameter(Mandatory)]$Status,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$AttemptLog,
        [AllowNull()][scriptblock]$OnStatus
    )

    $AttemptLog.Add($Status)
    if ($null -ne $OnStatus) {
        try {
            $null = & $OnStatus $Status
        } catch {
            Write-Verbose "WinRM status callback failed: $($_.Exception.Message)"
        }
    }
}

function Invoke-WinRMTcpProbe {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds
    )

    if ($null -ne $script:WinRMConnectionTcpProbeOverride) {
        $overrideResult = & $script:WinRMConnectionTcpProbeOverride $ComputerName $Port $TimeoutMilliseconds
        if ($overrideResult -is [bool]) {
            return [PSCustomObject]@{
                Open         = [bool]$overrideResult
                Category     = $(if ($overrideResult) { '' } else { 'TcpUnavailable' })
                ErrorMessage = ''
            }
        }
        return $overrideResult
    }

    $tcpClient = [System.Net.Sockets.TcpClient]::new()
    $asyncResult = $null
    try {
        $asyncResult = $tcpClient.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
            return [PSCustomObject]@{
                Open         = $false
                Category     = 'TcpUnavailable'
                ErrorMessage = "TCP $Port did not accept a connection within ${TimeoutMilliseconds}ms."
            }
        }

        $tcpClient.EndConnect($asyncResult)
        return [PSCustomObject]@{
            Open         = [bool]$tcpClient.Connected
            Category     = $(if ($tcpClient.Connected) { '' } else { 'TcpUnavailable' })
            ErrorMessage = ''
        }
    } catch {
        $category = Get-WinRMConnectionErrorCategory -ErrorObject $_
        if ($category -eq 'Unknown') {
            $category = 'TcpUnavailable'
        }
        return [PSCustomObject]@{
            Open         = $false
            Category     = $category
            ErrorMessage = $_.Exception.Message
        }
    } finally {
        if ($null -ne $asyncResult) {
            try { $asyncResult.AsyncWaitHandle.Close() } catch {}
        }
        $tcpClient.Dispose()
    }
}

function New-WinRMBlankPasswordCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$UserName
    )

    $emptyPassword = [System.Security.SecureString]::new()
    $emptyPassword.MakeReadOnly()
    return [System.Management.Automation.PSCredential]::new($UserName, $emptyPassword)
}

function Connect-WinRMSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [AllowNull()]
        [System.Management.Automation.PSCredential]$Credential,

        [ValidateRange(1, 10)]
        [int]$MaxAttempts = 3,

        [ValidateRange(100, 60000)]
        [int]$TcpTimeoutMs = 1200,

        [ValidateRange(100, 60000)]
        [int]$OpenTimeoutMs = 7000,

        [ValidateRange(1000, 3600000)]
        [int]$OperationTimeoutMs = 60000,

        [ValidateRange(0, 30000)]
        [int]$BaseRetryDelayMs = 1000,

        [ValidateRange(0, 65535)]
        [int]$Port = 0,

        [string]$ConfigurationName = 'Microsoft.PowerShell',

        [System.Management.Automation.Runspaces.AuthenticationMechanism]$Authentication = [System.Management.Automation.Runspaces.AuthenticationMechanism]::Default,

        [switch]$UseSSL,

        [switch]$SkipTcpPreflight,

        [AllowNull()]
        [scriptblock]$OnStatus
    )

    $effectivePort = if ($Port -gt 0) {
        $Port
    } elseif ($UseSSL) {
        5986
    } else {
        5985
    }

    $overallWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $attemptLog = [System.Collections.Generic.List[object]]::new()
    $lastCategory = 'Unknown'
    $lastMessage = 'No connection attempt completed.'
    $completedAttempts = 0

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $completedAttempts = $attempt

        if (-not $SkipTcpPreflight) {
            $probeStatus = New-WinRMConnectionStatus `
                -State 'TcpProbe' `
                -ComputerName $ComputerName `
                -Attempt $attempt `
                -MaxAttempts $MaxAttempts `
                -ElapsedMilliseconds $overallWatch.ElapsedMilliseconds `
                -Message "Attempt $attempt/${MaxAttempts}: probing TCP $effectivePort."
            Publish-WinRMConnectionStatus -Status $probeStatus -AttemptLog $attemptLog -OnStatus $OnStatus

            $probeResult = Invoke-WinRMTcpProbe -ComputerName $ComputerName -Port $effectivePort -TimeoutMilliseconds $TcpTimeoutMs
            if (-not $probeResult.Open) {
                $lastCategory = if ([string]::IsNullOrWhiteSpace([string]$probeResult.Category)) { 'TcpUnavailable' } else { [string]$probeResult.Category }
                $lastMessage = if ([string]::IsNullOrWhiteSpace([string]$probeResult.ErrorMessage)) {
                    "TCP $effectivePort is unavailable."
                } else {
                    [string]$probeResult.ErrorMessage
                }

                $failedStatus = New-WinRMConnectionStatus `
                    -State 'AttemptFailed' `
                    -ComputerName $ComputerName `
                    -Attempt $attempt `
                    -MaxAttempts $MaxAttempts `
                    -Category $lastCategory `
                    -ElapsedMilliseconds $overallWatch.ElapsedMilliseconds `
                    -Message "Attempt $attempt/$MaxAttempts failed before authentication: $lastMessage"
                Publish-WinRMConnectionStatus -Status $failedStatus -AttemptLog $attemptLog -OnStatus $OnStatus

                if ($attempt -lt $MaxAttempts -and (Test-WinRMConnectionRetryCategory -Category $lastCategory)) {
                    $delay = [Math]::Min(8000, $BaseRetryDelayMs * [Math]::Pow(2, $attempt - 1))
                    $retryStatus = New-WinRMConnectionStatus `
                        -State 'Retrying' `
                        -ComputerName $ComputerName `
                        -Attempt $attempt `
                        -MaxAttempts $MaxAttempts `
                        -Category $lastCategory `
                        -DelayMilliseconds ([int]$delay) `
                        -ElapsedMilliseconds $overallWatch.ElapsedMilliseconds `
                        -Message "Retrying WinRM in $([int]$delay)ms."
                    Publish-WinRMConnectionStatus -Status $retryStatus -AttemptLog $attemptLog -OnStatus $OnStatus
                    if ($delay -gt 0) { Start-Sleep -Milliseconds ([int]$delay) }
                    continue
                }
                break
            }
        }

        $connectStatus = New-WinRMConnectionStatus `
            -State 'Connecting' `
            -ComputerName $ComputerName `
            -Attempt $attempt `
            -MaxAttempts $MaxAttempts `
            -ElapsedMilliseconds $overallWatch.ElapsedMilliseconds `
            -Message "Attempt $attempt/${MaxAttempts}: opening authenticated WinRM session."
        Publish-WinRMConnectionStatus -Status $connectStatus -AttemptLog $attemptLog -OnStatus $OnStatus

        $session = $null
        try {
            $sessionOption = New-PSSessionOption -OpenTimeout $OpenTimeoutMs -OperationTimeout $OperationTimeoutMs
            $sessionParams = @{
                ComputerName     = $ComputerName
                ConfigurationName = $ConfigurationName
                Authentication   = $Authentication
                SessionOption    = $sessionOption
                ErrorAction      = 'Stop'
            }
            if ($null -ne $Credential) {
                $sessionParams.Credential = $Credential
            }
            if ($UseSSL) {
                $sessionParams.UseSSL = $true
            }
            if ($Port -gt 0) {
                $sessionParams.Port = $Port
            }

            if ($null -ne $script:WinRMConnectionSessionFactoryOverride) {
                $session = & $script:WinRMConnectionSessionFactoryOverride $sessionParams
            } else {
                $session = New-PSSession @sessionParams
            }

            if ($null -eq $session -or [string]$session.State -ne 'Opened') {
                $stateText = if ($null -eq $session) { 'null' } else { [string]$session.State }
                throw "WinRM session state is '$stateText' instead of 'Opened'."
            }

            $connectedStatus = New-WinRMConnectionStatus `
                -State 'Connected' `
                -ComputerName $ComputerName `
                -Attempt $attempt `
                -MaxAttempts $MaxAttempts `
                -ElapsedMilliseconds $overallWatch.ElapsedMilliseconds `
                -Message "WinRM session opened on attempt $attempt/$MaxAttempts."
            Publish-WinRMConnectionStatus -Status $connectedStatus -AttemptLog $attemptLog -OnStatus $OnStatus

            $session | Add-Member -NotePropertyName WinRMConnectionAttemptCount -NotePropertyValue $attempt -Force
            $session | Add-Member -NotePropertyName WinRMConnectionElapsedMs -NotePropertyValue $overallWatch.ElapsedMilliseconds -Force
            $session | Add-Member -NotePropertyName WinRMConnectionAttempts -NotePropertyValue @($attemptLog) -Force
            return $session
        } catch {
            if ($null -ne $session -and $session -is [System.Management.Automation.Runspaces.PSSession]) {
                Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            }

            $lastCategory = Get-WinRMConnectionErrorCategory -ErrorObject $_
            $lastMessage = ($_.Exception.Message -replace '\s+', ' ').Trim()
            $failedStatus = New-WinRMConnectionStatus `
                -State 'AttemptFailed' `
                -ComputerName $ComputerName `
                -Attempt $attempt `
                -MaxAttempts $MaxAttempts `
                -Category $lastCategory `
                -ElapsedMilliseconds $overallWatch.ElapsedMilliseconds `
                -Message "Attempt $attempt/$MaxAttempts failed ($lastCategory): $lastMessage"
            Publish-WinRMConnectionStatus -Status $failedStatus -AttemptLog $attemptLog -OnStatus $OnStatus

            if ($attempt -lt $MaxAttempts -and (Test-WinRMConnectionRetryCategory -Category $lastCategory)) {
                $delay = [Math]::Min(8000, $BaseRetryDelayMs * [Math]::Pow(2, $attempt - 1))
                $retryStatus = New-WinRMConnectionStatus `
                    -State 'Retrying' `
                    -ComputerName $ComputerName `
                    -Attempt $attempt `
                    -MaxAttempts $MaxAttempts `
                    -Category $lastCategory `
                    -DelayMilliseconds ([int]$delay) `
                    -ElapsedMilliseconds $overallWatch.ElapsedMilliseconds `
                    -Message "Retrying WinRM in $([int]$delay)ms."
                Publish-WinRMConnectionStatus -Status $retryStatus -AttemptLog $attemptLog -OnStatus $OnStatus
                if ($delay -gt 0) { Start-Sleep -Milliseconds ([int]$delay) }
                continue
            }
            break
        }
    }

    $overallWatch.Stop()
    $finalMessage = "WinRM connection to '$ComputerName' failed after $completedAttempts attempt(s) in $($overallWatch.ElapsedMilliseconds)ms. Category=$lastCategory. LastError=$lastMessage"
    $finalStatus = New-WinRMConnectionStatus `
        -State 'Failed' `
        -ComputerName $ComputerName `
        -Attempt $completedAttempts `
        -MaxAttempts $MaxAttempts `
        -Category $lastCategory `
        -ElapsedMilliseconds $overallWatch.ElapsedMilliseconds `
        -Message $finalMessage
    Publish-WinRMConnectionStatus -Status $finalStatus -AttemptLog $attemptLog -OnStatus $OnStatus

    $exception = [System.InvalidOperationException]::new($finalMessage)
    $exception.Data['WinRMConnectionCategory'] = $lastCategory
    $exception.Data['WinRMConnectionAttemptCount'] = $completedAttempts
    $exception.Data['WinRMConnectionElapsedMs'] = $overallWatch.ElapsedMilliseconds
    $exception.Data['WinRMConnectionAttempts'] = @($attemptLog)
    throw $exception
}

function Test-WinRMConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ComputerName,
        [AllowNull()][System.Management.Automation.PSCredential]$Credential,
        [ValidateRange(1, 10)][int]$MaxAttempts = 3,
        [ValidateRange(100, 60000)][int]$TcpTimeoutMs = 1200,
        [ValidateRange(100, 60000)][int]$OpenTimeoutMs = 7000,
        [ValidateRange(1000, 3600000)][int]$OperationTimeoutMs = 60000,
        [ValidateRange(0, 30000)][int]$BaseRetryDelayMs = 1000,
        [ValidateRange(0, 65535)][int]$Port = 0,
        [string]$ConfigurationName = 'Microsoft.PowerShell',
        [System.Management.Automation.Runspaces.AuthenticationMechanism]$Authentication = [System.Management.Automation.Runspaces.AuthenticationMechanism]::Default,
        [switch]$UseSSL,
        [switch]$SkipTcpPreflight,
        [AllowNull()][scriptblock]$OnStatus
    )

    $statusLog = [System.Collections.Generic.List[object]]::new()
    $forwardStatus = {
        param($status)
        $statusLog.Add($status)
        if ($null -ne $OnStatus) {
            $null = & $OnStatus $status
        }
    }.GetNewClosure()

    $session = $null
    try {
        $session = Connect-WinRMSession `
            -ComputerName $ComputerName `
            -Credential $Credential `
            -MaxAttempts $MaxAttempts `
            -TcpTimeoutMs $TcpTimeoutMs `
            -OpenTimeoutMs $OpenTimeoutMs `
            -OperationTimeoutMs $OperationTimeoutMs `
            -BaseRetryDelayMs $BaseRetryDelayMs `
            -Port $Port `
            -ConfigurationName $ConfigurationName `
            -Authentication $Authentication `
            -UseSSL:$UseSSL `
            -SkipTcpPreflight:$SkipTcpPreflight `
            -OnStatus $forwardStatus

        return [PSCustomObject]@{
            PSTypeName          = 'WinRMConnection.Result'
            Success             = $true
            ComputerName        = $ComputerName
            AttemptCount        = $session.WinRMConnectionAttemptCount
            ElapsedMilliseconds = $session.WinRMConnectionElapsedMs
            ErrorCategory       = ''
            ErrorMessage        = ''
            Attempts            = @($statusLog)
        }
    } catch {
        $category = Get-WinRMConnectionErrorCategory -ErrorObject $_
        $attemptCount = if ($_.Exception.Data.Contains('WinRMConnectionAttemptCount')) {
            [int]$_.Exception.Data['WinRMConnectionAttemptCount']
        } else {
            @($statusLog | Where-Object State -eq 'AttemptFailed').Count
        }
        $elapsed = if ($_.Exception.Data.Contains('WinRMConnectionElapsedMs')) {
            [long]$_.Exception.Data['WinRMConnectionElapsedMs']
        } else {
            0
        }
        return [PSCustomObject]@{
            PSTypeName          = 'WinRMConnection.Result'
            Success             = $false
            ComputerName        = $ComputerName
            AttemptCount        = $attemptCount
            ElapsedMilliseconds = $elapsed
            ErrorCategory       = $category
            ErrorMessage        = $_.Exception.Message
            Attempts            = @($statusLog)
        }
    } finally {
        if ($null -ne $session -and $session -is [System.Management.Automation.Runspaces.PSSession]) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-WinRMCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ComputerName,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [AllowNull()][System.Management.Automation.PSCredential]$Credential,
        [object[]]$ArgumentList = @(),
        [ValidateRange(1, 10)][int]$MaxAttempts = 3,
        [ValidateRange(100, 60000)][int]$TcpTimeoutMs = 1200,
        [ValidateRange(100, 60000)][int]$OpenTimeoutMs = 7000,
        [ValidateRange(1000, 3600000)][int]$OperationTimeoutMs = 60000,
        [ValidateRange(0, 30000)][int]$BaseRetryDelayMs = 1000,
        [ValidateRange(0, 65535)][int]$Port = 0,
        [string]$ConfigurationName = 'Microsoft.PowerShell',
        [System.Management.Automation.Runspaces.AuthenticationMechanism]$Authentication = [System.Management.Automation.Runspaces.AuthenticationMechanism]::Default,
        [switch]$UseSSL,
        [switch]$SkipTcpPreflight,
        [AllowNull()][scriptblock]$OnStatus
    )

    $session = $null
    try {
        $session = Connect-WinRMSession `
            -ComputerName $ComputerName `
            -Credential $Credential `
            -MaxAttempts $MaxAttempts `
            -TcpTimeoutMs $TcpTimeoutMs `
            -OpenTimeoutMs $OpenTimeoutMs `
            -OperationTimeoutMs $OperationTimeoutMs `
            -BaseRetryDelayMs $BaseRetryDelayMs `
            -Port $Port `
            -ConfigurationName $ConfigurationName `
            -Authentication $Authentication `
            -UseSSL:$UseSSL `
            -SkipTcpPreflight:$SkipTcpPreflight `
            -OnStatus $OnStatus

        Invoke-Command -Session $session -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
    } finally {
        if ($null -ne $session -and $session -is [System.Management.Automation.Runspaces.PSSession]) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}

Export-ModuleMember -Function @(
    'Connect-WinRMSession'
    'Get-WinRMConnectionErrorCategory'
    'Invoke-WinRMCommand'
    'New-WinRMBlankPasswordCredential'
    'Test-WinRMConnection'
)
