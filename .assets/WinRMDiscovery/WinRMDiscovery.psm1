#requires -Version 5.1
Set-StrictMode -Version Latest

$script:WinRMDiscoveryModuleRoot = $PSScriptRoot
$script:WinRMDiscoveryBenchmarkMode = $false
$script:WinRMDiscoveryLastScanResult = $null

$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
if ([string]::IsNullOrWhiteSpace($localAppData)) {
    $localAppData = $env:TEMP
}
$script:WinRMDiscoveryStateRoot = if (-not [string]::IsNullOrWhiteSpace($env:WINRM_DISCOVERY_STATE_ROOT)) {
    [Environment]::ExpandEnvironmentVariables($env:WINRM_DISCOVERY_STATE_ROOT)
} else {
    Join-Path -Path $localAppData -ChildPath 'WinRMDiscovery'
}
try { $null = New-Item -ItemType Directory -Path $script:WinRMDiscoveryStateRoot -Force -ErrorAction Stop } catch {}

function Test-DeviceCheckLanDiscoveryIPv4 {
    param(
        [AllowEmptyString()][string]$Address,
        [string[]]$SubnetPrefixes = @()
    )

    if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) { return $false }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $false }

    $octets = $Address.Split('.')
    if ($octets.Count -ne 4) { return $false }
    $first = [int]$octets[0]
    $last = [int]$octets[3]
    if ($first -in @(0, 127, 255) -or ($first -ge 224 -and $first -le 239)) { return $false }
    if ($first -eq 169 -and [int]$octets[1] -eq 254) { return $false }
    if ($last -eq 0 -or $last -eq 255) { return $false }

    $prefixes = @($SubnetPrefixes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($prefixes.Count -gt 0) {
        $matchesSubnet = $false
        foreach ($prefix in $prefixes) {
            if ($Address.StartsWith("$prefix.", [System.StringComparison]::OrdinalIgnoreCase)) {
                $matchesSubnet = $true
                break
            }
        }
        if (-not $matchesSubnet) { return $false }
    }

    return $true
}

function ConvertTo-DeviceCheckHostDisplayName {
    param(
        [AllowEmptyString()][string]$HostName,
        [AllowEmptyString()][string]$FallbackIP
    )

    if ([string]::IsNullOrWhiteSpace($HostName)) { return $FallbackIP }
    $name = $HostName.Trim()
    $parsed = $null
    if ([System.Net.IPAddress]::TryParse($name, [ref]$parsed)) { return $FallbackIP }
    if ($name -match '\.in-addr\.arpa$') { return $FallbackIP }
    if ($name -match '^([^.]+)\.') { return $Matches[1] }
    return $name
}

function Get-DeviceCheckWsDiscoveryProbeFields {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    if ($Text -notmatch 'pub:Computer' -and $Text -notmatch '(?:^|[<\s/])(?:[A-Za-z0-9_-]+:)?Computer(?:[>\s/])') { return $null }

    $xaddr = $null
    $uuid = $null
    if ($Text -match '<(?:[A-Za-z0-9_-]+:)?Address>(urn:uuid:[^<]+)</(?:[A-Za-z0-9_-]+:)?Address>') { $uuid = $Matches[1] }
    if ($Text -match '<(?:[A-Za-z0-9_-]+:)?XAddrs>(http://[^<]+)</(?:[A-Za-z0-9_-]+:)?XAddrs>') { $xaddr = $Matches[1] }

    return [PSCustomObject]@{
        XAddr = $xaddr
        Uuid  = $uuid
    }
}

function Get-DeviceCheckWsDiscoveryMetadataComputerName {
    param([AllowEmptyString()][string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) { return $null }
    if ($Content -match '<(?:[A-Za-z0-9_-]+:)?Computer(?:\s[^>]*)?>([^<]+)</(?:[A-Za-z0-9_-]+:)?Computer>') {
        $computer = $Matches[1]
        if ($computer -match '^([^/]+)') { return $Matches[1] }
        return $computer
    }

    return $null
}

function Get-DeviceCheckExplorerNetworkComputerNameFromPath {
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ($Path -match '^\\\\([^\\]+)') { return $Matches[1].Trim() }
    return $null
}

function Invoke-DeviceCheckWsDiscoveryProbe {
    param(
        [string[]]$SubnetPrefixes = @(),
        [int]$TimeoutMs = 1800
    )

    $results = [ordered]@{}
    $messageId = [guid]::NewGuid().ToString()
    $probe = @"
<?xml version="1.0" encoding="UTF-8"?>
<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
  <e:Header>
    <w:MessageID>uuid:$messageId</w:MessageID>
    <w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
    <w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
  </e:Header>
  <e:Body><d:Probe /></e:Body>
</e:Envelope>
"@

    $client = [Net.Sockets.UdpClient]::new(0)
    try {
        $client.EnableBroadcast = $true
        $client.MulticastLoopback = $false
        $client.Client.ReceiveTimeout = 250
        $bytes = [Text.Encoding]::UTF8.GetBytes($probe)
        $endpoint = [Net.IPEndPoint]::new([Net.IPAddress]::Parse('239.255.255.250'), 3702)
        [void]$client.Send($bytes, $bytes.Length, $endpoint)

        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        while ([DateTime]::UtcNow -lt $deadline) {
            try {
                $remote = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
                $data = $client.Receive([ref]$remote)
                $text = [Text.Encoding]::UTF8.GetString($data)
                $ip = $remote.Address.ToString()
                if (-not (Test-DeviceCheckLanDiscoveryIPv4 -Address $ip -SubnetPrefixes $SubnetPrefixes)) { continue }
                $probeFields = Get-DeviceCheckWsDiscoveryProbeFields -Text $text
                if ($null -eq $probeFields) { continue }

                if (-not $results.Contains($ip)) {
                    $results[$ip] = [PSCustomObject]@{
                        IP       = $ip
                        HostName = $ip
                        XAddr    = $probeFields.XAddr
                        Uuid     = $probeFields.Uuid
                        Source   = 'WS-Discovery'
                    }
                }
            } catch [Net.Sockets.SocketException] {}
        }
    } catch {
    } finally {
        $client.Dispose()
    }

    foreach ($entry in $results.Values) {
        if (-not [string]::IsNullOrWhiteSpace($entry.XAddr) -and -not [string]::IsNullOrWhiteSpace($entry.Uuid)) {
            $name = Get-DeviceCheckWsDiscoveryComputerName -XAddr $entry.XAddr -Uuid $entry.Uuid
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                $entry.HostName = $name
            }
        }
    }

    return @($results.Values)
}

function Get-DeviceCheckWsDiscoveryComputerName {
    param(
        [Parameter(Mandatory)][string]$XAddr,
        [Parameter(Mandatory)][string]$Uuid
    )

    $messageId = [guid]::NewGuid().ToString()
    $body = @"
<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing">
  <soap:Header>
    <wsa:To>$Uuid</wsa:To>
    <wsa:Action>http://schemas.xmlsoap.org/ws/2004/09/transfer/Get</wsa:Action>
    <wsa:MessageID>urn:uuid:$messageId</wsa:MessageID>
    <wsa:ReplyTo><wsa:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</wsa:Address></wsa:ReplyTo>
  </soap:Header>
  <soap:Body />
</soap:Envelope>
"@

    try {
        $response = Invoke-WebRequest -Uri $XAddr -Method Post -Body $body -ContentType 'application/soap+xml; charset=utf-8' -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        $content = [string]$response.Content
        return (Get-DeviceCheckWsDiscoveryMetadataComputerName -Content $content)
    } catch {}

    return $null
}

function Get-DeviceCheckExplorerNetworkComputers {
    param([int]$TimeoutMilliseconds = 700)

    $runspace = $null
    $ps = $null
    $async = $null
    try {
        $runspace = [Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.ApartmentState = [Threading.ApartmentState]::STA
        $runspace.ThreadOptions = [Runspaces.PSThreadOptions]::ReuseThread
        $runspace.Open()

        $ps = [PowerShell]::Create()
        $ps.Runspace = $runspace
        [void]$ps.AddScript({
            $results = [ordered]@{}
            $shell = $null
            try {
                $shell = New-Object -ComObject Shell.Application
                $folder = $shell.Namespace('shell:::{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}')
                if ($null -ne $folder) {
                    foreach ($item in @($folder.Items())) {
                        $name = [string]$item.Name
                        $path = [string]$item.Path
                        if ([string]::IsNullOrWhiteSpace($name) -and [string]::IsNullOrWhiteSpace($path)) { continue }

                        $hostName = $null
                        if ($path -match '^\\\\([^\\]+)') {
                            $hostName = $Matches[1]
                        }

                        if ([string]::IsNullOrWhiteSpace($hostName)) { continue }
                        $hostName = $hostName.Trim()
                        if (-not $results.Contains($hostName)) {
                            $results[$hostName] = [PSCustomObject]@{
                                HostName = $hostName
                                Path     = $path
                                Source   = 'ExplorerNetwork'
                            }
                        }
                    }
                }
            } catch {
            } finally {
                if ($null -ne $shell) {
                    try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch {}
                }
            }

            return @($results.Values)
        })

        $async = $ps.BeginInvoke()
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) {
            try { $ps.Stop() } catch {}
            return @()
        }

        return @($ps.EndInvoke($async))
    } catch {
        return @()
    } finally {
        if ($null -ne $async -and $null -ne $async.AsyncWaitHandle) { try { $async.AsyncWaitHandle.Dispose() } catch {} }
        if ($null -ne $ps) { try { $ps.Dispose() } catch {}; $ps = $null }
        if ($null -ne $runspace) { try { $runspace.Dispose() } catch {}; $runspace = $null }
    }
}

function Get-DeviceCheckNetBiosNodeStatusName {
    param(
        [Parameter(Mandatory)][byte[]]$Response,
        [string]$FallbackIP
    )

    if ($Response.Length -lt 57) { return $null }

    $offset = 12
    while ($offset -lt $Response.Length -and $Response[$offset] -ne 0) {
        $offset += 1 + [int]$Response[$offset]
    }
    if ($offset + 12 -ge $Response.Length) { return $null }

    $offset += 1
    $type = ([int]$Response[$offset] -shl 8) -bor [int]$Response[$offset + 1]
    if ($type -ne 0x21) { return $null }

    $offset += 10
    if ($offset -ge $Response.Length) { return $null }

    $nameCount = [int]$Response[$offset]
    $offset++

    $preferred = $null
    $fallback = $null
    for ($i = 0; $i -lt $nameCount; $i++) {
        if ($offset + 17 -ge $Response.Length) { break }

        $rawName = [Text.Encoding]::ASCII.GetString($Response, $offset, 15).Trim()
        $suffix = [int]$Response[$offset + 15]
        $flags = ([int]$Response[$offset + 16] -shl 8) -bor [int]$Response[$offset + 17]
        $isGroup = (($flags -band 0x8000) -ne 0)
        $offset += 18

        if ([string]::IsNullOrWhiteSpace($rawName) -or $rawName -eq 'WORKGROUP') { continue }

        if ($suffix -eq 0x20 -and -not $isGroup) {
            $preferred = $rawName
            break
        }
        if ($suffix -eq 0x00 -and -not $isGroup -and [string]::IsNullOrWhiteSpace($fallback)) {
            $fallback = $rawName
        }
    }

    $name = $(if (-not [string]::IsNullOrWhiteSpace($preferred)) { $preferred } else { $fallback })
    return (ConvertTo-DeviceCheckHostDisplayName -HostName $name -FallbackIP $FallbackIP)
}

function Resolve-DeviceCheckNetBiosName {
    param(
        [Parameter(Mandatory)][string]$IPAddress,
        [int]$TimeoutMs = 450
    )

    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($IPAddress, [ref]$parsed)) { return $null }
    if ($parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $null }

    $transactionId = Get-Random -Minimum 1 -Maximum 65535
    $query = [byte[]]::new(50)
    $query[0] = [byte](($transactionId -shr 8) -band 0xff)
    $query[1] = [byte]($transactionId -band 0xff)
    $query[5] = 1
    $query[12] = 0x20
    $encodedWildcard = [Text.Encoding]::ASCII.GetBytes(('CK' + ('CA' * 15)))
    for ($i = 0; $i -lt 32; $i++) { $query[13 + $i] = $encodedWildcard[$i] }
    $query[45] = 0
    $query[47] = 0x21
    $query[49] = 0x01

    $client = $null
    try {
        $client = [Net.Sockets.UdpClient]::new(0)
        $client.Client.ReceiveTimeout = $TimeoutMs
        $endpoint = [Net.IPEndPoint]::new($parsed, 137)
        [void]$client.Send($query, $query.Length, $endpoint)
        $remote = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
        $response = $client.Receive([ref]$remote)
        $rawName = Get-DeviceCheckNetBiosNodeStatusName -Response $response -FallbackIP $IPAddress
        if (-not [string]::IsNullOrWhiteSpace($rawName) -and $rawName -ne $IPAddress) { return $rawName }
    } catch {
    } finally {
        if ($null -ne $client) { $client.Dispose() }
    }

    if ($null -eq (Get-Command nbtstat.exe -ErrorAction SilentlyContinue)) { return $null }

    try {
        $lines = @(nbtstat.exe -A $IPAddress 2>$null)
        $preferred = $null
        $fallback = $null
        foreach ($line in $lines) {
            if ($line -match '^\s*(?<name>.{1,15})<(?<suffix>[0-9A-Fa-f]{2})>\s+UNIQUE\s+Registered') {
                $name = $Matches.name.Trim()
                if ([string]::IsNullOrWhiteSpace($name) -or $name -eq 'WORKGROUP') { continue }
                $suffix = $Matches.suffix.ToUpperInvariant()
                if ($suffix -eq '20') {
                    $preferred = $name
                    break
                }
                if ($suffix -eq '00' -and [string]::IsNullOrWhiteSpace($fallback)) {
                    $fallback = $name
                }
            }
        }

        $name = $(if (-not [string]::IsNullOrWhiteSpace($preferred)) { $preferred } else { $fallback })
        return (ConvertTo-DeviceCheckHostDisplayName -HostName $name -FallbackIP $IPAddress)
    } catch {
        return $null
    }
}

function Invoke-DeviceCheckComputerPortSweep {
    param(
        [string[]]$SubnetPrefixes = @(),
        [string[]]$ExcludedIPs = @(),
        [int[]]$Ports = @(3389, 5985, 445),
        [int]$TimeoutMs = 220,
        [int]$BatchSize = 2048
    )

    $prefixes = @($SubnetPrefixes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($prefixes.Count -eq 0) { return @() }

    $excluded = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ip in @($ExcludedIPs)) {
        if (-not [string]::IsNullOrWhiteSpace($ip)) { $null = $excluded.Add($ip) }
    }

    $candidateIPs = [System.Collections.Generic.List[string]]::new()
    foreach ($prefix in $prefixes) {
        for ($lastOctet = 1; $lastOctet -le 254; $lastOctet++) {
            $ip = "$prefix.$lastOctet"
            if (-not $excluded.Contains($ip)) { $candidateIPs.Add($ip) }
        }
    }

    $results = [ordered]@{}
    for ($offset = 0; $offset -lt $candidateIPs.Count; $offset += $BatchSize) {
        $scanTasks = [System.Collections.Generic.List[PSCustomObject]]::new()
        $end = [Math]::Min($offset + $BatchSize - 1, $candidateIPs.Count - 1)
        for ($index = $offset; $index -le $end; $index++) {
            $ip = $candidateIPs[$index]
            foreach ($port in $Ports) {
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new()
                    $task = $tcp.ConnectAsync($ip, $port)
                    $scanTasks.Add([PSCustomObject]@{ IP = $ip; Port = $port; TcpClient = $tcp; Task = $task })
                } catch {}
            }
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
            $allDone = $true
            foreach ($scanTask in $scanTasks) {
                if (-not $scanTask.Task.IsCompleted) {
                    $allDone = $false
                    break
                }
            }
            if ($allDone) { break }
            Start-Sleep -Milliseconds 15
        }

        foreach ($scanTask in $scanTasks) {
            try {
                if ($scanTask.Task.IsCompleted -and $scanTask.TcpClient.Connected) {
                    if (-not $results.Contains($scanTask.IP)) {
                        $results[$scanTask.IP] = [PSCustomObject]@{
                            IP        = $scanTask.IP
                            RdpOpen   = $false
                            WinRmOpen = $false
                            SmbOpen   = $false
                        }
                    }
                    if ($scanTask.Port -eq 3389) { $results[$scanTask.IP].RdpOpen = $true }
                    if ($scanTask.Port -eq 5985) { $results[$scanTask.IP].WinRmOpen = $true }
                    if ($scanTask.Port -eq 445) { $results[$scanTask.IP].SmbOpen = $true }
                }
            } finally {
                try { $scanTask.TcpClient.Dispose() } catch {}
            }
        }
    }

    return @($results.Values)
}

function Get-DeviceCheckHostsCache {
    param([string]$NetworkId)
    $path = Join-Path -Path $script:WinRMDiscoveryStateRoot -ChildPath 'hosts-cache.json'
    $hash = @{}
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $json -and $json.PSObject.Properties[$NetworkId]) {
                $netObj = $json.PSObject.Properties[$NetworkId].Value
                if ($null -ne $netObj) {
                    foreach ($p in $netObj.PSObject.Properties) { $hash[$p.Name] = $p.Value }
                }
            }
        } catch {}
    }
    return $hash
}

function Save-DeviceCheckHostsCache {
    param([Parameter(Mandatory)]$Cache, [Parameter(Mandatory)][string]$NetworkId)
    $path = Join-Path -Path $script:WinRMDiscoveryStateRoot -ChildPath 'hosts-cache.json'
    try {
        $fullCache = @{}
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($null -ne $json) {
                foreach ($p in $json.PSObject.Properties) {
                    if ($p.Name -match '\|') { $fullCache[$p.Name] = $p.Value }
                }
            }
        }
        $fullCache[$NetworkId] = $Cache
        ($fullCache | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $path -Encoding UTF8
    } catch {}
}

function Start-DeviceCheckBackgroundResolver {
    param(
        [Parameter(Mandatory)][string[]]$IPs,
        [Parameter(Mandatory)][string]$NetworkId
    )
    if ($IPs.Count -eq 0) { return }
    $cachePath = Join-Path -Path $script:WinRMDiscoveryStateRoot -ChildPath 'hosts-cache.json'

    $null = Start-Job -ScriptBlock {
        param($ips, $path, $networkId)
        $fullCache = @{}
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                if ($null -ne $json) {
                    foreach ($prop in $json.PSObject.Properties) {
                        if ($prop.Name -match '\|') { $fullCache[$prop.Name] = $prop.Value }
                    }
                }
            } catch {}
        }

        $netCache = @{}
        if ($fullCache.ContainsKey($networkId)) {
            $netObj = $fullCache[$networkId]
            if ($null -ne $netObj) {
                foreach ($prop in $netObj.PSObject.Properties) { $netCache[$prop.Name] = $prop.Value }
            }
        }

        $updated = $false
        foreach ($ip in $ips) {
            if (-not $netCache.ContainsKey($ip)) {
                try {
                    $entry = [System.Net.Dns]::GetHostEntry($ip)
                    if ($entry.HostName) {
                        $name = $entry.HostName
                        if ($name -eq $ip -or $name -match '\.in-addr\.arpa$') { $name = $ip } elseif ($name -match '^([^.]+)\.') { $name = $Matches[1] }
                        $netCache[$ip] = $name
                        $updated = $true
                    }
                } catch {
                    try {
                        $dnsRes = Resolve-DnsName -Name $ip -QuickTimeout -ErrorAction Stop
                        if ($dnsRes) {
                            $name = $dnsRes[0].NameHost
                            if ($name -eq $ip -or $name -match '\.in-addr\.arpa$') { $name = $ip } elseif ($name -match '^([^.]+)\.') { $name = $Matches[1] }
                            $netCache[$ip] = $name
                            $updated = $true
                        }
                    } catch {}
                }
            }
        }
        if ($updated) {
            try {
                $fullCache[$networkId] = $netCache
                $json = $fullCache | ConvertTo-Json -Depth 4
                $json | Set-Content -LiteralPath $path -Encoding UTF8
            } catch {}
        }
    } -ArgumentList $IPs, $cachePath, $NetworkId
}


function Get-CurrentNetworkIdentity {
    $profileName = "Unknown Network"
    $gatewayMac = "00-00-00-00-00-00"
    $subnetId = "0.0.0.0"

    try {
        $profile = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object IPv4Connectivity -eq 'Internet' | Select-Object -First 1
        if ($null -eq $profile) {
            $profile = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if ($null -ne $profile) {
            $profileName = $profile.Name
        }
    } catch {}

    try {
        $routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
        if ($routes) {
            $gatewayIp = $routes[0].NextHop
            $neighbor = Get-NetNeighbor -IPAddress $gatewayIp -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($neighbor -and $neighbor.LinkLayerAddress) {
                $gatewayMac = $neighbor.LinkLayerAddress.ToUpper()
            }
        }
    } catch {}

    try {
        $ipInfo = $null
        if ($null -ne $profile) {
            $ipInfo = Get-NetIPAddress -InterfaceIndex $profile.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if ($null -eq $ipInfo) {
            $ipInfo = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceAlias -notmatch 'Loopback|vEthernet' } |
                Select-Object -First 1
        }
        if ($ipInfo -and $ipInfo.IPAddress -match '^(\d+\.\d+\.\d+)\.\d+$') {
            $subnetId = $Matches[1]
        }
    } catch {}

    $networkId = "$profileName|$gatewayMac|$subnetId"
    return [PSCustomObject]@{
        NetworkId   = $networkId
        ProfileName = $profileName
        GatewayMac  = $gatewayMac
        SubnetId    = $subnetId
    }
}

function Get-DeviceCheckDiscoveredHosts {
    $swTotal = [System.Diagnostics.Stopwatch]::StartNew()

    $discovered = [System.Collections.Generic.List[object]]::new()
    $results = @()

    # 1. Interfaces lookup
    $swPhase = [System.Diagnostics.Stopwatch]::StartNew()
    $interfaces = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InterfaceAlias -notmatch "Loopback|vEthernet" -and
            $_.AddressState -eq "Preferred" -and
            $_.IPAddress -notmatch "^169\.254\."
        }

    if (-not $interfaces) {
        $timeInterfaces = $swPhase.Elapsed.TotalMilliseconds
        $logLines = @(
            "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] Network Scan Completed (No active interfaces)"
            "  Total Time       : $([Math]::Round($swTotal.Elapsed.TotalMilliseconds, 1)) ms"
            "  Phase 1 (Ifaces) : $([Math]::Round($timeInterfaces, 1)) ms"
        )
        if ($script:WinRMDiscoveryBenchmarkMode) {
            $script:WinRMDiscoveryLastScanResult = $logLines
            $resolvedScriptRoot = $script:WinRMDiscoveryModuleRoot
            if ([string]::IsNullOrWhiteSpace($resolvedScriptRoot)) { $resolvedScriptRoot = $global:PSScriptRoot }
            if ([string]::IsNullOrWhiteSpace($resolvedScriptRoot)) { $resolvedScriptRoot = "." }
            $logsDir = Join-Path -Path $resolvedScriptRoot -ChildPath 'logs'
            if (-not (Test-Path -LiteralPath $logsDir)) { $null = New-Item -ItemType Directory -Path $logsDir -Force }
            $timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
            $logFile = Join-Path -Path $logsDir -ChildPath "network_scan_$timestamp.log"
            try { $logLines | Out-File -FilePath $logFile -Append -Encoding utf8 } catch {}
        } else {
            $script:WinRMDiscoveryLastScanResult = $null
        }
        return $discovered
    }
    $timeInterfaces = $swPhase.Elapsed.TotalMilliseconds

    # 2. History retrieval & Parallel DNS Lookup
    $swPhase.Restart()
    $historyIPs = @()
    $historyIpToName = @{}
    $history = Get-DeviceCheckConnectionHistory
    $currentNetwork = Get-CurrentNetworkIdentity
    $currentNetworkId = $currentNetwork.NetworkId

    $dnsDetailsLog = [System.Collections.Generic.List[string]]::new()
    $explorerNetworkIPsSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $explorerHostNameSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ipList = [System.Collections.Generic.List[string]]::new()
    $hostNamesToResolveSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if ($history) {
        # Add static IP history entries instantly if they match the current network ID
        foreach ($entry in $history) {
            if ($entry.NetworkId -eq $currentNetworkId -and $entry.LastIPAddress -match '^\d+\.\d+\.\d+\.\d+$') {
                $ipList.Add($entry.LastIPAddress)
                $historyIpToName[$entry.LastIPAddress] = $entry.ComputerName
            }
        }

        # Filter hostnames that need DNS lookup from the current network
        $hostsToResolve = $history | Where-Object {
            $_.NetworkId -eq $currentNetworkId -and
            -not [string]::IsNullOrWhiteSpace($_.ComputerName) -and
            $_.ComputerName -notmatch '^\d+\.\d+\.\d+\.\d+$' -and
            ([string]::IsNullOrWhiteSpace($_.LastIPAddress) -or $_.LastIPAddress -notmatch '^\d+\.\d+\.\d+\.\d+$')
        } | Select-Object -ExpandProperty ComputerName -Unique

        foreach ($hostToResolve in @($hostsToResolve)) {
            if (-not [string]::IsNullOrWhiteSpace($hostToResolve)) {
                $null = $hostNamesToResolveSet.Add($hostToResolve)
            }
        }
    }

    $explorerNetworkHosts = @(Get-DeviceCheckExplorerNetworkComputers)
    if ($explorerNetworkHosts.Count -gt 0) {
        $dnsDetailsLog.Add("    Explorer Network computers: $(@($explorerNetworkHosts.HostName) -join ', ')")
        foreach ($explorerHost in $explorerNetworkHosts) {
            if (-not [string]::IsNullOrWhiteSpace($explorerHost.HostName)) {
                $null = $explorerHostNameSet.Add($explorerHost.HostName)
                $null = $hostNamesToResolveSet.Add($explorerHost.HostName)
            }
        }
    }

    $hostsToResolve = @($hostNamesToResolveSet)
    if ($hostsToResolve) {
            $isPS6Plus = $PSVersionTable.PSVersion.Major -ge 6
            $hasResolveDnsName = $null -ne (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)

            $resolvedResults = $hostsToResolve | ForEach-Object -Parallel {
                $hostName = $_
                $ips = [System.Collections.Generic.List[string]]::new()
                $swSingle = [System.Diagnostics.Stopwatch]::StartNew()
                $methodUsed = "None"
                $hasResolveDns = $using:hasResolveDnsName

                if ($hasResolveDns) {
                    try {
                        $methodUsed = "Resolve-DnsName"
                        $resolved = Resolve-DnsName -Name $hostName -DnsOnly -QuickTimeout -ErrorAction Stop
                        if ($resolved) {
                            foreach ($r in $resolved) {
                                if ($r.IPAddress) {
                                    $parsed = $null
                                    if ([System.Net.IPAddress]::TryParse([string]$r.IPAddress, [ref]$parsed) -and $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                                        $ips.Add($r.IPAddress)
                                    }
                                }
                            }
                        }
                    } catch {
                        # Resolve-DnsName failed (e.g. host offline).
                        # methodUsed is already "Resolve-DnsName", which prevents the slow GetHostAddresses fallback.
                    }
                }

                if ($ips.Count -eq 0 -and $methodUsed -eq "None") {
                    try {
                        $dnsIps = [System.Net.Dns]::GetHostAddresses($hostName)
                        if ($dnsIps) {
                            $methodUsed = "GetHostAddresses"
                            foreach ($ip in $dnsIps) {
                                if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                                    $ips.Add($ip.IPAddressToString)
                                }
                            }
                        }
                    } catch {}
                }

                $singleMs = $swSingle.Elapsed.TotalMilliseconds
                if ($ips.Count -gt 0) {
                    [PSCustomObject]@{
                        ComputerName = $hostName
                        IPs          = @($ips)
                        Success      = $true
                        Method       = $methodUsed
                        Duration     = $singleMs
                    }
                } else {
                    [PSCustomObject]@{
                        ComputerName = $hostName
                        IPs          = @()
                        Success      = $false
                        Method       = $methodUsed
                        Duration     = $singleMs
                    }
                }
            } -ThrottleLimit 10

            if ($resolvedResults) {
                foreach ($res in $resolvedResults) {
                    if ($null -ne $res) {
                        $dnsDetailsLog.Add("    Host '$($res.ComputerName)' resolved via $($res.Method) in $([Math]::Round($res.Duration, 1)) ms (Success: $($res.Success), IPs: $($res.IPs -join ', '))")
                        if ($res.Success) {
                            foreach ($ip in $res.IPs) {
                                $ipList.Add($ip)
                                $historyIpToName[$ip] = $res.ComputerName
                                if ($explorerHostNameSet.Contains($res.ComputerName)) {
                                    $null = $explorerNetworkIPsSet.Add($ip)
                                }
                            }
                        }
                    }
                }
            }
    }
    $historyIPs = @($ipList | Select-Object -Unique)
    $timeDns = $swPhase.Elapsed.TotalMilliseconds

    # 3. Keep refresh fast; active TCP/WS-D probes refresh neighbors without a foreground ARP purge.
    $swPhase.Restart()
    $timeArpClear = $swPhase.Elapsed.TotalMilliseconds

    # 4. ICMP is skipped for the PC-only selector; WS-D/TCP prove computer visibility.
    $swPhase.Restart()

    # Get neighbors first to know which IPs to target
    $localSubnetPrefixes = @(
        foreach ($if in $interfaces) {
            if ($if.IPAddress -match '^(\d+\.\d+\.\d+)\.\d+$') { $Matches[1] }
        }
    ) | Select-Object -Unique

    $neighbors = foreach ($if in $interfaces) {
        Get-NetNeighbor -InterfaceIndex $if.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.State -ne 'Unreachable' -and
                $_.LinkLayerAddress -ne '00-00-00-00-00-00' -and
                (Test-DeviceCheckLanDiscoveryIPv4 -Address $_.IPAddress -SubnetPrefixes $localSubnetPrefixes)
            }
    }

    # Filter out gateway IPs to avoid connecting to router
    $gateways = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
    if ($routes) {
        foreach ($r in $routes) {
            if (-not [string]::IsNullOrWhiteSpace($r.NextHop)) {
                $null = $gateways.Add($r.NextHop)
            }
        }
    }

    # Filter out local machine IPs to avoid self-discovery
    $localIPs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($if in $interfaces) {
        $null = $localIPs.Add($if.IPAddress)
    }

    $swWsDiscovery = [System.Diagnostics.Stopwatch]::StartNew()
    $wsDiscoveryHosts = @(Invoke-DeviceCheckWsDiscoveryProbe -SubnetPrefixes $localSubnetPrefixes)
    $timeWsDiscovery = $swWsDiscovery.Elapsed.TotalMilliseconds
    $wsDiscoveryIPsSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $sweepExcludedIPs = [System.Collections.Generic.List[string]]::new()
    foreach ($ip in $localIPs) { $sweepExcludedIPs.Add($ip) }
    foreach ($ip in $gateways) { $sweepExcludedIPs.Add($ip) }
    $swComputerSweep = [System.Diagnostics.Stopwatch]::StartNew()
    $computerPortHosts = @(Invoke-DeviceCheckComputerPortSweep -SubnetPrefixes $localSubnetPrefixes -ExcludedIPs @($sweepExcludedIPs))
    $timeComputerSweep = $swComputerSweep.Elapsed.TotalMilliseconds
    $computerPortIPsSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $neighborIPs = @()
    if ($neighbors) {
        $neighborIPs = @($neighbors.IPAddress)
    }

    # Combine neighbor cache IPs and history IPs
    $targetIPsSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ip in $neighborIPs) { $null = $targetIPsSet.Add($ip) }
    foreach ($hostEntry in $wsDiscoveryHosts) {
        if (-not $localIPs.Contains($hostEntry.IP)) {
            $null = $wsDiscoveryIPsSet.Add($hostEntry.IP)
            $null = $targetIPsSet.Add($hostEntry.IP)
            if (-not [string]::IsNullOrWhiteSpace($hostEntry.HostName) -and $hostEntry.HostName -ne $hostEntry.IP) {
                $historyIpToName[$hostEntry.IP] = $hostEntry.HostName
            }
        }
    }
    foreach ($hostEntry in $computerPortHosts) {
        if (-not $localIPs.Contains($hostEntry.IP)) {
            $null = $computerPortIPsSet.Add($hostEntry.IP)
            $null = $targetIPsSet.Add($hostEntry.IP)
        }
    }
    foreach ($ip in $historyIPs) {
        if (Test-DeviceCheckLanDiscoveryIPv4 -Address $ip -SubnetPrefixes $localSubnetPrefixes) { $null = $targetIPsSet.Add($ip) }
    }

    $targetIPs = @(
        $targetIPsSet | Where-Object { -not $gateways.Contains($_) -and -not $localIPs.Contains($_) }
    )

    $swPhase.Restart()
    $timePing = $swPhase.Elapsed.TotalMilliseconds

    # 5. Neighbor/Active Target Setup
    $swPhase.Restart()
    $uniqueIPs = $targetIPs
    $timeNeighbors = $swPhase.Elapsed.TotalMilliseconds

    # 6. Fast parallel TCP scan on port 5985 and 445
    $swPhase.Restart()
    $winrmOpenIPs = [System.Collections.Generic.List[string]]::new()
    $smbOpenIPs = [System.Collections.Generic.List[string]]::new()

    foreach ($hostEntry in $computerPortHosts) {
        if ($hostEntry.WinRmOpen -and -not ($winrmOpenIPs -contains $hostEntry.IP)) { $winrmOpenIPs.Add($hostEntry.IP) }
        if ($hostEntry.SmbOpen -and -not ($smbOpenIPs -contains $hostEntry.IP)) { $smbOpenIPs.Add($hostEntry.IP) }
    }

    $tcpScanIPs = @(
        foreach ($ip in $uniqueIPs) {
            if (-not ($computerPortIPsSet.Contains($ip) -and ($winrmOpenIPs -contains $ip))) { $ip }
        }
    )

    if ($tcpScanIPs) {
        $connections = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($ip in $tcpScanIPs) {
            $tcp1 = [System.Net.Sockets.TcpClient]::new()
            $tcp2 = [System.Net.Sockets.TcpClient]::new()
            try {
                $ipObj = [System.Net.IPAddress]::Parse($ip)
                $task1 = $tcp1.ConnectAsync($ipObj, 5985)
                $task2 = $tcp2.ConnectAsync($ipObj, 445)
                $connections.Add([PSCustomObject]@{
                    IP         = $ip
                    TcpClient1 = $tcp1
                    Task1      = $task1
                    TcpClient2 = $tcp2
                    Task2      = $task2
                })
            } catch {
                $tcp1.Dispose()
                $tcp2.Dispose()
            }
        }

        # Wait up to 500ms for connection tasks to complete
        $swTimeout = [System.Diagnostics.Stopwatch]::StartNew()
        while ($swTimeout.ElapsedMilliseconds -lt 500) {
            $allDone = $true
            foreach ($c in $connections) {
                if (-not $c.Task1.IsCompleted -or -not $c.Task2.IsCompleted) {
                    $allDone = $false
                    break
                }
            }
            if ($allDone) { break }
            Start-Sleep -Milliseconds 20
        }
        $swTimeout.Stop()

        foreach ($c in $connections) {
            $winrmConnected = $c.Task1.IsCompleted -and $c.TcpClient1.Connected
            $smbConnected = $c.Task2.IsCompleted -and $c.TcpClient2.Connected

            if ($winrmConnected) {
                $winrmOpenIPs.Add($c.IP)
            } elseif ($smbConnected) {
                $smbOpenIPs.Add($c.IP)
            }

            $c.TcpClient1.Dispose()
            $c.TcpClient2.Dispose()
        }
    }
    $timeTcpScan = $swPhase.Elapsed.TotalMilliseconds

    # 7. Asynchronous Hostname Resolution for Online Hosts
    $swPhase.Restart()

    # Keep confirmed WS-Discovery computers visible before WinRM is enabled, without listing ARP-only phones/cameras.
    $onlineIPsSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ip in $winrmOpenIPs) { $null = $onlineIPsSet.Add($ip) }
    foreach ($ip in $smbOpenIPs) { $null = $onlineIPsSet.Add($ip) }
    $detectedOnlyIPsSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ip in $targetIPs) {
        if (($wsDiscoveryIPsSet.Contains($ip) -or $computerPortIPsSet.Contains($ip) -or $explorerNetworkIPsSet.Contains($ip)) -and -not $onlineIPsSet.Contains($ip)) { $null = $detectedOnlyIPsSet.Add($ip) }
    }
    foreach ($ip in $detectedOnlyIPsSet) { $null = $onlineIPsSet.Add($ip) }

    $onlineIPs = @($onlineIPsSet)
    $resolvedNames = @{}
    $hostsCache = Get-DeviceCheckHostsCache -NetworkId $currentNetworkId
    $cacheUpdatedFromDiscovery = $false
    foreach ($entry in $historyIpToName.GetEnumerator()) {
        $displayName = ConvertTo-DeviceCheckHostDisplayName -HostName $entry.Value -FallbackIP $entry.Key
        if ($displayName -ne $entry.Key -and ((-not $hostsCache.ContainsKey($entry.Key)) -or $hostsCache[$entry.Key] -ne $displayName)) {
            $hostsCache[$entry.Key] = $displayName
            $cacheUpdatedFromDiscovery = $true
        }
    }
    if ($cacheUpdatedFromDiscovery) {
        Save-DeviceCheckHostsCache -Cache $hostsCache -NetworkId $currentNetworkId
    }

    $unresolvedIPs = [System.Collections.Generic.List[string]]::new()
    foreach ($ip in $onlineIPs) {
        if ($historyIpToName.ContainsKey($ip)) {
            $displayName = ConvertTo-DeviceCheckHostDisplayName -HostName $historyIpToName[$ip] -FallbackIP $ip
            if ($displayName -ne $ip) {
                $resolvedNames[$ip] = $displayName
            } else {
                $unresolvedIPs.Add($ip)
            }
        } elseif ($hostsCache.ContainsKey($ip)) {
            $displayName = ConvertTo-DeviceCheckHostDisplayName -HostName $hostsCache[$ip] -FallbackIP $ip
            if ($displayName -ne $ip) {
                $resolvedNames[$ip] = $displayName
            } else {
                $unresolvedIPs.Add($ip)
            }
        } else {
            $unresolvedIPs.Add($ip)
        }
    }

    if ($unresolvedIPs.Count -gt 0) {
        $resolutionTasks = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($ip in $unresolvedIPs) {
            # Start asynchronous NetBIOS/DNS resolution
            try {
                $dnsTask = [System.Net.Dns]::GetHostEntryAsync($ip)
                $resolutionTasks.Add([PSCustomObject]@{
                    IP   = $ip
                    Task = $dnsTask
                })
            } catch {}
        }

        if ($resolutionTasks.Count -gt 0) {
            $resTasksArray = [System.Threading.Tasks.Task[]]::new($resolutionTasks.Count)
            for ($i = 0; $i -lt $resolutionTasks.Count; $i++) {
                $resTasksArray[$i] = $resolutionTasks[$i].Task
            }
            try {
                $null = [System.Threading.Tasks.Task]::WaitAll($resTasksArray, 400)
            } catch {}

            $newlyResolved = @{}
            foreach ($rt in $resolutionTasks) {
                if ($rt.Task.IsCompleted -and -not $rt.Task.IsFaulted -and $rt.Task.Result.HostName) {
                    $hostName = ConvertTo-DeviceCheckHostDisplayName -HostName $rt.Task.Result.HostName -FallbackIP $rt.IP
                    if ($hostName -ne $rt.IP) {
                        $resolvedNames[$rt.IP] = $hostName
                        $newlyResolved[$rt.IP] = $hostName
                    }
                }
            }
            if ($newlyResolved.Count -gt 0) {
                foreach ($ip in $newlyResolved.Keys) {
                    $hostsCache[$ip] = $newlyResolved[$ip]
                }
                Save-DeviceCheckHostsCache -Cache $hostsCache -NetworkId $currentNetworkId
            }
        }
    }

    # Fallback to local DNS/IP lookup if async GetHostEntry failed or timed out
    $stillUnresolved = [System.Collections.Generic.List[string]]::new()
    foreach ($ip in $onlineIPs) {
        if (-not $resolvedNames.ContainsKey($ip)) {
            try {
                $dnsRes = Resolve-DnsName -Name $ip -DnsOnly -QuickTimeout -ErrorAction SilentlyContinue
                if ($dnsRes) {
                    $dnsName = ConvertTo-DeviceCheckHostDisplayName -HostName $dnsRes[0].NameHost -FallbackIP $ip
                    if ($dnsName -ne $ip) {
                        $resolvedNames[$ip] = $dnsName
                        $hostsCache[$ip] = $dnsName
                        Save-DeviceCheckHostsCache -Cache $hostsCache -NetworkId $currentNetworkId
                    } else {
                        $resolvedNames[$ip] = $ip
                        $stillUnresolved.Add($ip)
                    }
                } else {
                    $resolvedNames[$ip] = $ip
                    $stillUnresolved.Add($ip)
                }
            } catch {
                $resolvedNames[$ip] = $ip
                $stillUnresolved.Add($ip)
            }
        }
    }

    $netBiosCandidates = @(
        $stillUnresolved |
            Where-Object { ($smbOpenIPs -contains $_) -or $detectedOnlyIPsSet.Contains($_) } |
            Select-Object -First 6
    )
    foreach ($ip in $netBiosCandidates) {
        $netBiosName = Resolve-DeviceCheckNetBiosName -IPAddress $ip -TimeoutMs 350
        if (-not [string]::IsNullOrWhiteSpace($netBiosName) -and $netBiosName -ne $ip) {
            $resolvedNames[$ip] = $netBiosName
            $hostsCache[$ip] = $netBiosName
            Save-DeviceCheckHostsCache -Cache $hostsCache -NetworkId $currentNetworkId
        }
    }

    $stillUnresolvedAfterNetBios = [System.Collections.Generic.List[string]]::new()
    foreach ($ip in $stillUnresolved) {
        if (-not $resolvedNames.ContainsKey($ip) -or $resolvedNames[$ip] -eq $ip) {
            $stillUnresolvedAfterNetBios.Add($ip)
        }
    }
    $stillUnresolved = $stillUnresolvedAfterNetBios

    # Resolve unresolved IPs in background to populate cache for future scans
    if ($stillUnresolved.Count -gt 0) {
        Start-DeviceCheckBackgroundResolver -IPs @($stillUnresolved) -NetworkId $currentNetworkId
    }

    # Build final scan results list
    $scanResultsList = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($ip in $onlineIPs) {
        $name = $resolvedNames[$ip]
        $isWinRm = $ip -in $winrmOpenIPs
        $isSmb = $ip -in $smbOpenIPs
        $isDetectedOnly = $detectedOnlyIPsSet.Contains($ip)
        $scanResultsList.Add([PSCustomObject]@{ IP = $ip; HostName = $name; WinRmOpen = $isWinRm; SmbOpen = $isSmb; DetectedOnly = $isDetectedOnly })
    }

    $results = @($scanResultsList)

    # Final mapping & MAC lookup
    $latestNeighbors = foreach ($if in $interfaces) {
        Get-NetNeighbor -InterfaceIndex $if.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    }
    $macLookup = @{}
    if ($latestNeighbors) {
        foreach ($n in $latestNeighbors) {
            if (-not [string]::IsNullOrWhiteSpace($n.IPAddress) -and -not [string]::IsNullOrWhiteSpace($n.LinkLayerAddress)) {
                $macLookup[$n.IPAddress] = $n.LinkLayerAddress.Replace(':', '-').ToUpper()
            }
        }
    }

    foreach ($res in $results) {
        if ($null -ne $res) {
            $mac = 'Unknown'
            if ($macLookup.ContainsKey($res.IP)) {
                $mac = $macLookup[$res.IP]
            }
            $discovered.Add([PSCustomObject]@{ IP = $res.IP; HostName = $res.HostName; MAC = $mac; WinRmOpen = $res.WinRmOpen; SmbOpen = $res.SmbOpen; DetectedOnly = $res.DetectedOnly })
        }
    }
    $timeFinalMap = $swPhase.Elapsed.TotalMilliseconds

    $totalMs = $swTotal.Elapsed.TotalMilliseconds

    # Write details and phases to benchmark log
    $logLines = [System.Collections.Generic.List[string]]::new()
    $logLines.Add("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] Network Scan Completed")
    $logLines.Add("  Total Time       : $([Math]::Round($totalMs, 1)) ms")
    $logLines.Add("  Phase 1 (Ifaces) : $([Math]::Round($timeInterfaces, 1)) ms")
    $logLines.Add("  Phase 2 (DNS)    : $([Math]::Round($timeDns, 1)) ms")
    if ($dnsDetailsLog.Count -gt 0) {
        foreach ($logDnsLine in $dnsDetailsLog) {
            $logLines.Add($logDnsLine)
        }
    }
    $logLines.Add("  Phase 3 (ArpClr) : $([Math]::Round($timeArpClear, 1)) ms")
    $logLines.Add("  Phase 4 (Ping)   : $([Math]::Round($timePing, 1)) ms")
    $logLines.Add("  Phase 4b (WS-Disc): $([Math]::Round($timeWsDiscovery, 1)) ms ($($wsDiscoveryHosts.Count) hosts)")
    $logLines.Add("  Phase 4c (PCPort): $([Math]::Round($timeComputerSweep, 1)) ms ($($computerPortHosts.Count) hosts)")
    $logLines.Add("  Phase 5 (Neighbr): $([Math]::Round($timeNeighbors, 1)) ms")
    $logLines.Add("  Phase 6 (TCPScan): $([Math]::Round($timeTcpScan, 1)) ms")
    $logLines.Add("  Phase 7 (Reverse): $([Math]::Round($timeFinalMap, 1)) ms")
    $logLines.Add("  Scan Results     : $($discovered.Count) hosts found ($($uniqueIPs.Count) unique IPs scanned)")
    $logLines.Add("")

    if ($script:WinRMDiscoveryBenchmarkMode) {
        $script:WinRMDiscoveryLastScanResult = @($logLines)
        $resolvedScriptRoot = $script:WinRMDiscoveryModuleRoot
        if ([string]::IsNullOrWhiteSpace($resolvedScriptRoot)) { $resolvedScriptRoot = $global:PSScriptRoot }
        if ([string]::IsNullOrWhiteSpace($resolvedScriptRoot)) { $resolvedScriptRoot = "." }
        $logsDir = Join-Path -Path $resolvedScriptRoot -ChildPath 'logs'
        if (-not (Test-Path -LiteralPath $logsDir)) { $null = New-Item -ItemType Directory -Path $logsDir -Force }
        $timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
        $logFile = Join-Path -Path $logsDir -ChildPath "network_scan_$timestamp.log"
        try {
            $logLines | Out-File -FilePath $logFile -Append -Encoding utf8
        } catch {}
    } else {
        $script:WinRMDiscoveryLastScanResult = $null
    }

    return $discovered
}

function Get-DeviceCheckConnectionHistory {
    $path = Join-Path -Path $script:WinRMDiscoveryStateRoot -ChildPath 'connection-history.json'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $history = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($history -is [Array]) {
                return [System.Collections.Generic.List[object]]::new($history)
            } else {
                return [System.Collections.Generic.List[object]]::new(@($history))
            }
        } catch {}
    }
    return [System.Collections.Generic.List[object]]::new()
}

function Save-DeviceCheckConnectionHistory {
    param([Parameter(Mandatory)]$History)
    $path = Join-Path -Path $script:WinRMDiscoveryStateRoot -ChildPath 'connection-history.json'
    try {
        $json = $History | ConvertTo-Json -Depth 4
        $json | Set-Content -LiteralPath $path -Encoding UTF8
    } catch {}
}

function Add-DeviceCheckConnectionHistoryEntry {
    param(
        [string]$ComputerName,
        [string]$LastIPAddress,
        [string]$MACAddress,
        [string]$UserName,
        [string]$NetworkId
    )

    if ([string]::IsNullOrWhiteSpace($ComputerName)) { return }
    if (-not (Test-DeviceCheckIPv4Address -Address $LastIPAddress)) {
        $LastIPAddress = $null
    }

    $historyList = Get-DeviceCheckConnectionHistory
    $history = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $historyList) {
        foreach ($item in @($historyList)) {
            $history.Add($item)
        }
    }

    $existing = $null
    foreach ($entry in $history) {
        if ($entry.NetworkId -eq $NetworkId) {
            if ($entry.ComputerName.ToLower() -eq $ComputerName.ToLower()) {
                $existing = $entry
                break
            }
            if ($entry.ComputerName -match '^\d+\.\d+\.\d+\.\d+$' -and ($entry.ComputerName -eq $LastIPAddress -or $entry.LastIPAddress -eq $LastIPAddress)) {
                $existing = $entry
                break
            }
        }
    }

    if ($null -ne $existing) {
        if ($existing.ComputerName -match '^\d+\.\d+\.\d+\.\d+$' -and $ComputerName -notmatch '^\d+\.\d+\.\d+\.\d+$') {
            $existing.ComputerName = $ComputerName
        }
        if (-not [string]::IsNullOrWhiteSpace($LastIPAddress)) {
            $existing.LastIPAddress = $LastIPAddress
        }
        if (-not [string]::IsNullOrWhiteSpace($MACAddress) -and $MACAddress -ne 'Unknown') {
            $existing.MACAddress = $MACAddress
        }
        $existing.UserName = $UserName
        $existing.LastConnected = (Get-Date).ToString('o')
    } else {
        $newEntry = [PSCustomObject]@{
            ComputerName    = $ComputerName
            LastIPAddress   = $LastIPAddress
            MACAddress      = $(if ([string]::IsNullOrWhiteSpace($MACAddress)) { 'Unknown' } else { $MACAddress })
            UserName        = $UserName
            NetworkId       = $NetworkId
            LastConnected   = (Get-Date).ToString('o')
        }
        $history.Add($newEntry)
    }

    $sortedHistory = [System.Collections.Generic.List[object]]::new(
        @($history | Sort-Object { [DateTime]$_.LastConnected } -Descending)
    )
    Save-DeviceCheckConnectionHistory -History $sortedHistory
}

function Test-PortOpen {
    param(
        [string]$ComputerName,
        [int]$Port = 5985,
        [int]$TimeoutMs = 1500
    )

    $tcp = [System.Net.Sockets.TcpClient]::new()
    $cts = [System.Threading.CancellationTokenSource]::new($TimeoutMs)
    try {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $task = $tcp.ConnectAsync($ComputerName, $Port, $cts.Token)
            $task.GetAwaiter().GetResult()
        } else {
            $task = $tcp.ConnectAsync($ComputerName, $Port)
            $null = $task.Wait($TimeoutMs)
        }
        return $tcp.Connected
    } catch {
        return $false
    } finally {
        $cts.Dispose()
        $tcp.Dispose()
    }
}

function Test-DeviceCheckIPv4Address {
    param([AllowEmptyString()][string]$Address)

    if ([string]::IsNullOrWhiteSpace($Address)) {
        return $false
    }

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) {
        return $false
    }

    return $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
}

function Get-DeviceCheckIPv4Addresses {
    param($Addresses)

    foreach ($address in @($Addresses)) {
        $addressText = $null
        if ($address -is [System.Net.IPAddress]) {
            $addressText = $address.IPAddressToString
        } else {
            $addressText = [string]$address
        }

        if (Test-DeviceCheckIPv4Address -Address $addressText) {
            $addressText
        }
    }
}

function Resolve-HistoryTargetAddress {
    param(
        [string]$ComputerName,
        [string]$LastIPAddress,
        [string]$MACAddress
    )

    Write-Verbose "Resolving address for target $ComputerName..."

    # 1. Try to resolve the hostname directly via DNS/LLMNR
    try {
        $ips = [System.Net.Dns]::GetHostAddresses($ComputerName)
        foreach ($resolvedIp in @(Get-DeviceCheckIPv4Addresses -Addresses $ips)) {
            if (Test-PortOpen -ComputerName $resolvedIp -Port 5985) {
                return $resolvedIp
            }
        }
    } catch {}

    try {
        $resolved = Resolve-DnsName -Name $ComputerName -ErrorAction SilentlyContinue
        if ($resolved) {
            foreach ($r in $resolved) {
                foreach ($resolvedIp in @(Get-DeviceCheckIPv4Addresses -Addresses $r.IPAddress)) {
                    if (Test-PortOpen -ComputerName $resolvedIp -Port 5985) {
                        return $resolvedIp
                    }
                }
            }
        }
    } catch {}

    # 2. Check local ARP cache
    if (-not [string]::IsNullOrWhiteSpace($MACAddress) -and $MACAddress -ne 'Unknown') {
        $normMAC = $MACAddress.Replace(':', '-').ToUpper()
        $neighbors = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $nMac = $_.LinkLayerAddress
                if ($nMac) { $nMac = $nMac.Replace(':', '-').ToUpper() }
                $nMac -eq $normMAC -and $_.InterfaceAlias -notmatch 'Loopback|vEthernet'
            }
        if ($neighbors) {
            $arpIp = $neighbors[0].IPAddress
            if ((Test-DeviceCheckIPv4Address -Address $arpIp) -and (Test-PortOpen -ComputerName $arpIp -Port 5985)) {
                return $arpIp
            }
        }
    }

    # 3. Fallback to last known IP
    if (-not [string]::IsNullOrWhiteSpace($LastIPAddress)) {
        if (-not (Test-DeviceCheckIPv4Address -Address $LastIPAddress)) {
            return $null
        }

        if (Test-PortOpen -ComputerName $LastIPAddress -Port 5985) {
            # If MACAddress is known, verify the MAC of $LastIPAddress matches
            if (-not [string]::IsNullOrWhiteSpace($MACAddress) -and $MACAddress -ne 'Unknown') {
                $neighbor = Get-NetNeighbor -IPAddress $LastIPAddress -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($neighbor -and $neighbor.LinkLayerAddress) {
                    $foundMac = $neighbor.LinkLayerAddress.Replace(':', '-').ToUpper()
                    $normMac = $MACAddress.Replace(':', '-').ToUpper()
                    if ($foundMac -ne $normMac) {
                        Write-Verbose "MAC mismatch for fallback IP $LastIPAddress (expected $normMac, got $foundMac). Skipping."
                        return $null
                    }
                }
            }
            return $LastIPAddress
        }
    }

    return $null
}

function Set-WinRMDiscoveryStateRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
        throw 'WinRM discovery state root must be an absolute path.'
    }
    $null = New-Item -ItemType Directory -Path $expanded -Force -ErrorAction Stop
    $script:WinRMDiscoveryStateRoot = (Resolve-Path -LiteralPath $expanded).Path
}

function Get-WinRMDiscoveryStateRoot {
    [CmdletBinding()]
    param()
    return $script:WinRMDiscoveryStateRoot
}

function Get-WinRMNetworkIdentity {
    [CmdletBinding()]
    param()
    return Get-CurrentNetworkIdentity
}

function Get-WinRMConnectionHistory {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$NetworkId = ''
    )

    $history = @(Get-DeviceCheckConnectionHistory)
    if ([string]::IsNullOrWhiteSpace($NetworkId)) {
        return $history
    }

    return @($history | Where-Object { $_.NetworkId -eq $NetworkId })
}

function Add-WinRMConnectionHistoryEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [AllowEmptyString()][string]$LastIPAddress = '',
        [AllowEmptyString()][string]$MACAddress = 'Unknown',
        [AllowEmptyString()][string]$UserName = 'Unknown',
        [AllowEmptyString()][string]$NetworkId = ''
    )

    if ([string]::IsNullOrWhiteSpace($NetworkId)) {
        $NetworkId = (Get-CurrentNetworkIdentity).NetworkId
    }

    Add-DeviceCheckConnectionHistoryEntry `
        -ComputerName $ComputerName `
        -LastIPAddress $LastIPAddress `
        -MACAddress $MACAddress `
        -UserName $UserName `
        -NetworkId $NetworkId
}

function Resolve-WinRMHistoryTargetAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [AllowEmptyString()][string]$LastIPAddress = '',
        [AllowEmptyString()][string]$MACAddress = 'Unknown'
    )

    return Resolve-HistoryTargetAddress `
        -ComputerName $ComputerName `
        -LastIPAddress $LastIPAddress `
        -MACAddress $MACAddress
}

function Find-WinRMComputer {
    [CmdletBinding()]
    param(
        [string]$StateRoot = '',
        [switch]$IncludeDiagnostics
    )

    if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
        Set-WinRMDiscoveryStateRoot -Path $StateRoot
    }

    $script:WinRMDiscoveryBenchmarkMode = [bool]$IncludeDiagnostics
    $ProgressPreference = 'SilentlyContinue'
    $raw = @(Get-DeviceCheckDiscoveredHosts)
    foreach ($item in $raw) {
        $status = if ($item.WinRmOpen) {
            'WinRMReady'
        } elseif ($item.SmbOpen) {
            'WinRMDisabled'
        } else {
            'ComputerDetected'
        }

        [PSCustomObject]@{
            PSTypeName      = 'WinRMDiscovery.Computer'
            ComputerName    = $item.HostName
            IPAddress       = $item.IP
            MACAddress      = $item.MAC
            WinRMHttpOpen   = [bool]$item.WinRmOpen
            SMBOpen         = [bool]$item.SmbOpen
            DetectedOnly    = [bool]$item.DetectedOnly
            Status          = $status
            HostName        = $item.HostName
            IP              = $item.IP
            MAC             = $item.MAC
            WinRmOpen       = [bool]$item.WinRmOpen
        }
    }
}

function Get-WinRMDiscoveryDiagnostics {
    [CmdletBinding()]
    param()
    return @($script:WinRMDiscoveryLastScanResult)
}

function Test-WinRMDiscoveryIPv4 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Address,
        [string[]]$SubnetPrefixes = @()
    )
    return Test-DeviceCheckLanDiscoveryIPv4 -Address $Address -SubnetPrefixes $SubnetPrefixes
}

function ConvertTo-WinRMDiscoveryHostDisplayName {
    [CmdletBinding()]
    param(
        [string]$HostName,
        [Parameter(Mandatory)][string]$FallbackIP
    )
    return ConvertTo-DeviceCheckHostDisplayName -HostName $HostName -FallbackIP $FallbackIP
}

Export-ModuleMember -Function @(
    'Find-WinRMComputer',
    'Get-WinRMNetworkIdentity',
    'Get-WinRMDiscoveryDiagnostics',
    'Get-WinRMDiscoveryStateRoot',
    'Set-WinRMDiscoveryStateRoot',
    'Get-WinRMConnectionHistory',
    'Add-WinRMConnectionHistoryEntry',
    'Resolve-WinRMHistoryTargetAddress',
    'Test-WinRMDiscoveryIPv4',
    'ConvertTo-WinRMDiscoveryHostDisplayName'
)
