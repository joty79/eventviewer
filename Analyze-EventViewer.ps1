# Analyze-EventViewer.ps1
# Script to diagnose system crashes, WHEA errors, and volmgr dump failures (Event ID 161).
# Supports both CLI output mode and interactive TUI mode (PS_UI_Blueprint).
# Version 1.0.0

param(
    [Parameter(Mandatory = $false, HelpMessage = "Enter the target ComputerName or IP Address (e.g. 192.168.1.47)")]
    [string]$ComputerName,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [switch]$Interactive
)

$isRemote = -not [string]::IsNullOrEmpty($ComputerName) -and 
            ($ComputerName -ne "localhost") -and 
            ($ComputerName -ne "127.0.0.1") -and 
            ($ComputerName -ne $env:COMPUTERNAME)

$runTui = $Interactive -or ($null -eq $PSBoundParameters["ComputerName"] -and $null -eq $PSBoundParameters["Credential"])

if ($runTui) {
    $blueprintPath = "C:\Users\joty79\.agent-shared\templates\PS_UI_Blueprint.psm1"
    if (Test-Path -LiteralPath $blueprintPath) {
        Invoke-Expression (Get-Content -Raw -LiteralPath $blueprintPath)
    } else {
        Write-Warning "Could not find TUI Blueprint at: $blueprintPath"
        Write-Warning "Falling back to standard CLI mode..."
        $runTui = $false
    }
}

# Paths
$historyPath = "d:\Users\joty79\scripts\eventviewer\history.json"
$exportsDir = "d:\Users\joty79\scripts\eventviewer\exports"

# Network Identity Check
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

    return [PSCustomObject]@{
        NetworkId   = "$profileName|$gatewayMac|$subnetId"
        ProfileName = $profileName
        GatewayMac  = $gatewayMac
        SubnetId    = $subnetId
    }
}

# Connection History Management
function Get-ConnectionHistory {
    if (Test-Path -LiteralPath $historyPath) {
        try {
            $content = Get-Content -LiteralPath $historyPath -Raw -ErrorAction Stop
            $history = ConvertFrom-Json $content
            $list = [System.Collections.Generic.List[object]]::new()
            if ($history) {
                foreach ($h in @($history)) {
                    $comp = if ($h.ComputerName) { $h.ComputerName } else { "Unknown" }
                    $ip = if ($h.IPAddress) { $h.IPAddress } else { $comp }
                    $user = if ($h.UserName) { $h.UserName } else { "Administrator" }
                    $netId = if ($h.NetworkId) { $h.NetworkId } else { "" }
                    $time = if ($h.LastConnected) { $h.LastConnected } else { "" }
                    
                    $list.Add([PSCustomObject]@{
                        ComputerName  = $comp
                        IPAddress     = $ip
                        UserName      = $user
                        NetworkId     = $netId
                        LastConnected = $time
                    })
                }
            }
            return @($list)
        } catch {
            return @()
        }
    }
    return @()
}

function Add-ConnectionHistoryEntry {
    param(
        [string]$ComputerName,
        [string]$IPAddress,
        [string]$UserName
    )
    
    $netId = (Get-CurrentNetworkIdentity).NetworkId
    $history = Get-ConnectionHistory
    
    $history = $history | Where-Object { 
        -not ($_.IPAddress -eq $IPAddress -and $_.NetworkId -eq $netId)
    }
    
    $newEntry = [PSCustomObject]@{
        ComputerName  = $ComputerName
        IPAddress     = $IPAddress
        UserName      = $UserName
        NetworkId     = $netId
        LastConnected = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
    
    $updatedHistory = @($newEntry) + $history
    if ($updatedHistory.Count -gt 15) {
        $updatedHistory = $updatedHistory[0..14]
    }
    
    try {
        $null = New-Item -ItemType File -Path $historyPath -Force -ErrorAction SilentlyContinue
        $updatedHistory | ConvertTo-Json | Set-Content -LiteralPath $historyPath -Encoding UTF8
    } catch {}
}

# Helper function to ensure local WinRM service is running
function Ensure-LocalWinRM {
    try {
        $winrmService = Get-Service -Name "WinRM" -ErrorAction Stop
        if ($winrmService.Status -ne 'Running') {
            Write-Host "Starting local WinRM service..." -ForegroundColor Gray
            try {
                Start-Service -Name "WinRM" -ErrorAction Stop
            } catch {
                Write-Host "  🔒 Local elevation required to start WinRM. Executing via gsudo..." -ForegroundColor Cyan
                & gsudo.exe pwsh -NoProfile -Command "Start-Service -Name 'WinRM'"
            }
        }
    } catch {
        Write-Warning "Could not access or start WinRM service locally: $_"
    }
}

# Helper function to auto-configure TrustedHosts for remote targets
function Add-ToTrustedHosts {
    param([string]$Target)
    
    Ensure-LocalWinRM
    
    try {
        $hostsItem = Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop
        $currentHosts = $hostsItem.Value
        
        if ($currentHosts -eq "*" -or $currentHosts.Split(",") -contains $Target) {
            Write-Host "  ✅ Target '$Target' is already in TrustedHosts." -ForegroundColor Green
            return
        }
        
        Write-Host "  ⚠️ Target '$Target' is not in TrustedHosts. Adding..." -ForegroundColor Yellow
        $newHosts = if ([string]::IsNullOrEmpty($currentHosts)) { $Target } else { "$currentHosts,$Target" }
        
        try {
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newHosts -Force -ErrorAction Stop
            Write-Host "  ✅ Successfully added '$Target' to TrustedHosts." -ForegroundColor Green
        } catch {
            Write-Host "  🔒 Local elevation required to modify TrustedHosts. Executing via gsudo..." -ForegroundColor Cyan
            $encodedCmd = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes("Set-Item WSMan:\localhost\Client\TrustedHosts -Value '$newHosts' -Force"))
            & gsudo.exe pwsh -NoProfile -EncodedCommand $encodedCmd
            
            # Verify update
            $verifyHosts = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value
            if ($verifyHosts.Split(",") -contains $Target -or $verifyHosts -eq "*") {
                Write-Host "  ✅ Successfully added '$Target' to TrustedHosts via gsudo." -ForegroundColor Green
            } else {
                throw "Verification failed. Target still not in TrustedHosts."
            }
        }
    } catch {
        Write-Warning "❌ Failed to update TrustedHosts: $_"
    }
}

# Fast network discovery using ConnectAsync (port 5985)
function Get-NetDiscoveredHosts {
    $discovered = [System.Collections.Generic.List[object]]::new()
    
    $interfaces = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -notmatch 'Loopback|vEthernet' }
        
    if (-not $interfaces) { return $discovered }
    
    $neighbors = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.State -ne 'Unreachable' -and $_.IPAddress -notmatch '^\d+\.\d+\.\d+\.255$' -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' }
        
    $gateways = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
    if ($routes) {
        foreach ($r in $routes) {
            if (-not [string]::IsNullOrWhiteSpace($r.NextHop)) { $null = $gateways.Add($r.NextHop) }
        }
    }
    
    $localIPs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($if in $interfaces) { $null = $localIPs.Add($if.IPAddress) }
    
    $targetIPsSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($neighbors) {
        foreach ($n in $neighbors) { $null = $targetIPsSet.Add($n.IPAddress) }
    }
    
    $targetIPs = @(
        $targetIPsSet | Where-Object { -not $gateways.Contains($_) -and -not $localIPs.Contains($_) }
    )
    
    if (-not $targetIPs) { return $discovered }
    
    $connections = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($ip in $targetIPs) {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        try {
            $ipObj = [System.Net.IPAddress]::Parse($ip)
            $task = $tcp.ConnectAsync($ipObj, 5985)
            $connections.Add([PSCustomObject]@{
                IP        = $ip
                TcpClient = $tcp
                Task      = $task
            })
        } catch {
            $tcp.Dispose()
        }
    }
    
    # Wait up to 500ms
    $swTimeout = [System.Diagnostics.Stopwatch]::StartNew()
    while ($swTimeout.ElapsedMilliseconds -lt 500) {
        $allDone = $true
        foreach ($c in $connections) {
            if (-not $c.Task.IsCompleted) {
                $allDone = $false
                break
            }
        }
        if ($allDone) { break }
        Start-Sleep -Milliseconds 20
    }
    $swTimeout.Stop()
    
    $winrmOpenIPs = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $connections) {
        if ($c.Task.IsCompleted -and $c.TcpClient.Connected) {
            $winrmOpenIPs.Add($c.IP)
        }
        $c.TcpClient.Dispose()
    }
    
    # Resolve names asynchronously
    $resolutionTasks = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($ip in $winrmOpenIPs) {
        try {
            $dnsTask = [System.Net.Dns]::GetHostEntryAsync($ip)
            $resolutionTasks.Add([PSCustomObject]@{ IP = $ip; Task = $dnsTask })
        } catch {}
    }
    
    if ($resolutionTasks.Count -gt 0) {
        $resTasksArray = [System.Threading.Tasks.Task[]]::new($resolutionTasks.Count)
        for ($i = 0; $i -lt $resolutionTasks.Count; $i++) { $resTasksArray[$i] = $resolutionTasks[$i].Task }
        try { [System.Threading.Tasks.Task]::WaitAll($resTasksArray, 400) } catch {}
    }
    
    foreach ($rt in $resolutionTasks) {
        $hostName = $rt.IP
        if ($rt.Task.IsCompleted -and -not $rt.Task.IsFaulted -and $rt.Task.Result.HostName) {
            $hostName = $rt.Task.Result.HostName
            if ($hostName -match '^([^.]+)\.') { $hostName = $Matches[1] }
        }
        $discovered.Add([PSCustomObject]@{ IP = $rt.IP; HostName = $hostName })
    }
    
    return $discovered
}

# Core Data Retrieval Function (Local or Remote)
function Get-DiagnosticsData {
    param(
        [string]$TargetComputer,
        [System.Management.Automation.PSCredential]$TargetCred
    )
    
    $isTargetRemote = -not [string]::IsNullOrEmpty($TargetComputer) -and 
                      ($TargetComputer -ne "localhost") -and 
                      ($TargetComputer -ne "127.0.0.1") -and 
                      ($TargetComputer -ne $env:COMPUTERNAME)

    $diagBlock = {
        # Helper to decode volmgr BugCheckProgress status codes
        function Decode-VolmgrCode {
            param([string]$progressStr)
            if ([string]::IsNullOrWhiteSpace($progressStr)) { return "No progress parameters available" }
            
            $results = [System.Collections.Generic.List[string]]::new()
            # Look for hex patterns like C00000A1 or C00001AC in progressStr
            if ($progressStr -match 'A10004C0' -or $progressStr -match 'C00000A1' -or $progressStr -match 'A10000C0') {
                $results.Add("STATUS_DEVICE_PROTOCOL_ERROR (0xC00000A1): Ο δίσκος/controller παρουσίασε σφάλμα πρωτοκόλλου επικοινωνίας.")
            }
            if ($progressStr -match 'AC0104C0' -or $progressStr -match 'C00001AC' -or $progressStr -match 'AC0100C0') {
                $results.Add("STATUS_DEVICE_DATA_ERROR (0xC00001AC): Σφάλμα ανάγνωσης/γραφής δεδομένων στη συσκευή αποθήκευσης.")
            }
            if ($progressStr -match '100000C0' -or $progressStr -match 'C0000010') {
                $results.Add("STATUS_DEVICE_DOES_NOT_EXIST (0xC0000010): Ο δίσκος αποσυνδέθηκε εντελώς κατά τη διάρκεια του κρασαρίσματος.")
            }
            if ($progressStr -match '0E0000C0' -or $progressStr -match 'C000000E') {
                $results.Add("STATUS_NO_SUCH_DEVICE (0xC000000E): Δεν βρέθηκε η συσκευή αποθήκευσης.")
            }
            if ($results.Count -eq 0) {
                return "Άγνωστος κωδικός σφάλματος (Hex: $progressStr)"
            }
            return $results -join " | "
        }

        # Retrieve Hardware and OS Specs
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $board = Get-CimInstance Win32_BaseBoard | Select-Object -First 1
        $bios = Get-CimInstance Win32_Bios | Select-Object -First 1
        $os = Get-CimInstance Win32_OperatingSystem | Select-Object -First 1
        $ram = Get-CimInstance Win32_PhysicalMemory | Select-Object DeviceLocator, Capacity, Speed, Manufacturer, PartNumber
        
        # Fast Startup Configuration
        $fastStartup = 0
        try {
            $fastStartup = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -ErrorAction SilentlyContinue).HiberbootEnabled
            if ($null -eq $fastStartup) { $fastStartup = 0 }
        } catch {}

        # Dump Configuration
        $crashControl = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" -ErrorAction SilentlyContinue
        
        # Physical Disks Info
        $disks = Get-PhysicalDisk -ErrorAction SilentlyContinue | Select-Object DeviceId, FriendlyName, OperationalStatus, HealthStatus, Size
        $wear = try {
            Get-PhysicalDisk -ErrorAction SilentlyContinue | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue | Select-Object DeviceId, Wear, Temperature
        } catch { @() }

        # Check for dump files
        $memoryDmp = Get-Item -Path "C:\Windows\MEMORY.DMP" -ErrorAction SilentlyContinue | Select-Object FullName, Length, LastWriteTime
        $minidumps = Get-ChildItem -Path "C:\Windows\Minidump" -Filter "*.dmp" -ErrorAction SilentlyContinue | Select-Object FullName, Length, LastWriteTime

        # Read Crash / Unexpected Shutdown / Boot / volmgr Events
        # ID 41: Kernel-Power unexpected reboot
        # ID 6008: Unexpected shutdown
        # ID 1001: Bugcheck
        # ID 161: volmgr dump file creation failed
        $crashEvents = [System.Collections.Generic.List[object]]::new()
        try {
            $events = Get-WinEvent -FilterHashtable @{LogName='System'; Id=@(41, 6008, 1001, 161)} -MaxEvents 50 -ErrorAction SilentlyContinue
            if ($events) {
                foreach ($e in $events) {
                    $decoded = ""
                    if ($e.Id -eq 161 -and $e.Message -match 'BugCheckProgress:\s*([0-9A-Fa-f]+)') {
                        $decoded = Decode-VolmgrCode -progressStr $Matches[1]
                    }
                    
                    $crashEvents.Add([PSCustomObject]@{
                        TimeCreated  = $e.TimeCreated
                        Id           = $e.Id
                        Level        = $e.LevelDisplayName
                        ProviderName = $e.ProviderName
                        Message      = $e.Message
                        Analysis     = $decoded
                    })
                }
            }
        } catch {}

        # Read WHEA events from log
        # Microsoft-Windows-Kernel-WHEA/Operational has record of sources initialized, attestation, errors
        $wheaEvents = [System.Collections.Generic.List[object]]::new()
        try {
            $events = Get-WinEvent -LogName "Microsoft-Windows-Kernel-WHEA/Operational" -MaxEvents 30 -ErrorAction SilentlyContinue
            if ($events) {
                foreach ($e in $events) {
                    $wheaEvents.Add([PSCustomObject]@{
                        TimeCreated = $e.TimeCreated
                        Id          = $e.Id
                        Message     = $e.Message
                    })
                }
            }
        } catch {}

        # Read System Log Warnings/Errors containing "WHEA" or "hardware error"
        $systemWheaEvents = [System.Collections.Generic.List[object]]::new()
        try {
            $events = Get-WinEvent -FilterHashtable @{LogName='System'; Level=@(1,2,3)} -ErrorAction SilentlyContinue |
                Where-Object { $_.ProviderName -like "*WHEA*" -or $_.Message -like "*WHEA*" -or $_.Message -like "*hardware error*" } |
                Select-Object -First 20
            if ($events) {
                foreach ($e in $events) {
                    $systemWheaEvents.Add([PSCustomObject]@{
                        TimeCreated  = $e.TimeCreated
                        Id           = $e.Id
                        ProviderName = $e.ProviderName
                        Message      = $e.Message
                    })
                }
            }
        } catch {}

        return [PSCustomObject]@{
            ComputerName      = $env:COMPUTERNAME
            Cpu               = $cpu.Name
            Motherboard       = "$($board.Manufacturer) $($board.Product)"
            MotherboardSerial = $board.SerialNumber
            BiosVersion       = $bios.Name
            BiosReleaseDate   = $bios.ReleaseDate
            OSArchitecture    = $os.OSArchitecture
            OSCaption         = $os.Caption
            OSVersion         = $os.Version
            Ram               = $ram
            FastStartup       = $fastStartup
            CrashControl      = [PSCustomObject]@{
                CrashDumpEnabled = $crashControl.CrashDumpEnabled
                DumpFile         = $crashControl.DumpFile
                MinidumpDir      = $crashControl.MinidumpDir
            }
            Disks             = $disks
            Wear              = $wear
            MemoryDmp         = $memoryDmp
            Minidumps         = $minidumps
            CrashEvents       = $crashEvents
            WheaEvents        = $wheaEvents
            SystemWheaEvents  = $systemWheaEvents
        }
    }

    if ($isTargetRemote) {
        Add-ToTrustedHosts -Target $TargetComputer
        $sessionParams = @{ ComputerName = $TargetComputer }
        if ($null -ne $TargetCred) { $sessionParams["Credential"] = $TargetCred }
        
        $session = New-PSSession @sessionParams -ErrorAction Stop
        try {
            $remoteData = Invoke-Command -Session $session -ScriptBlock $diagBlock -ErrorAction Stop
            return $remoteData
        } finally {
            Remove-PSSession $session
        }
    } else {
        return Invoke-Command -ScriptBlock $diagBlock
    }
}

# Helper to format data into text lines
function Get-FormattedDiagLines {
    param($diagData)
    
    $lines = [System.Collections.Generic.List[string]]::new()
    
    $lines.Add("======================================================================")
    $lines.Add("            EVENTVIEWER SYSTEM DIAGNOSTICS REPORT                    ")
    $lines.Add("======================================================================")
    $lines.Add("Computer Name:  $($diagData.ComputerName)")
    $lines.Add("OS Architecture: $($diagData.OSArchitecture) | $($diagData.OSCaption) ($($diagData.OSVersion))")
    $lines.Add("Processor:      $($diagData.Cpu)")
    $lines.Add("Motherboard:    $($diagData.Motherboard) (S/N: $($diagData.MotherboardSerial))")
    $lines.Add("BIOS Version:   $($diagData.BiosVersion) (Release: $($diagData.BiosReleaseDate))")
    
    # Check if BIOS is outdated (Dell OptiPlex 7060 latest is 1.32.0)
    if ($diagData.Motherboard -like "*OptiPlex 7060*" -or $diagData.BiosVersion -match '1\.(1[0-9]|2[0-9]|3[0-1])\.') {
        if ($diagData.BiosVersion -notlike "*1.32.*") {
            $lines.Add("")
            $lines.Add("⚠️🚨 WARNING: Το BIOS είναι outdated ($($diagData.BiosVersion)).")
            $lines.Add("             Η τελευταία έκδοση για το Dell OptiPlex 7060 είναι η 1.32.0 (08/11/2024).")
            $lines.Add("             Συνιστάται αναβάθμιση BIOS για επίλυση θεμάτων PTT/TPM και PCIe ASPM.")
        }
    }
    
    $lines.Add("")
    $lines.Add("=== POWER CONFIGURATION ===")
    $startupText = if ($diagData.FastStartup -eq 1) { "ENABLED (Ενεργό - Συνιστάται Απενεργοποίηση)" } else { "DISABLED (Απενεργοποιημένο - OK)" }
    $lines.Add("Fast Startup (Hiberboot): $startupText")
    
    $lines.Add("")
    $lines.Add("=== CRASH & RECOVERY SETTINGS ===")
    $dumpEnabledText = switch ($diagData.CrashControl.CrashDumpEnabled) {
        0 { "None (Απενεργοποιημένο)" }
        1 { "Complete Memory Dump (Πλήρης)" }
        2 { "Kernel Memory Dump (Πυρήνα)" }
        3 { "Small Memory Dump (Minidump)" }
        7 { "Automatic Memory Dump (Αυτόματο)" }
        Default { "Unknown ($($diagData.CrashControl.CrashDumpEnabled))" }
    }
    $lines.Add("Dump Type Configured: $dumpEnabledText")
    $lines.Add("Dump File Location:  $($diagData.CrashControl.DumpFile)")
    $lines.Add("Minidump Directory:  $($diagData.CrashControl.MinidumpDir)")
    
    $lines.Add("")
    $lines.Add("=== MEMORY DUMP FILES ON DISK ===")
    if ($diagData.MemoryDmp) {
        $lines.Add("MEMORY.DMP found: $($diagData.MemoryDmp.FullName) | Size: $([Math]::Round($diagData.MemoryDmp.Length/1MB, 2)) MB | Last Written: $($diagData.MemoryDmp.LastWriteTime)")
    } else {
        $lines.Add("MEMORY.DMP: NOT FOUND")
    }
    if ($diagData.Minidumps -and $diagData.Minidumps.Count -gt 0) {
        $lines.Add("Minidump files found ($($diagData.Minidumps.Count)):")
        foreach ($d in $diagData.Minidumps) {
            $lines.Add("  - $([System.IO.Path]::GetFileName($d.FullName)) | Size: $([Math]::Round($d.Length/1KB, 2)) KB | Last Written: $($d.LastWriteTime)")
        }
    } else {
        $lines.Add("Minidumps: None found in C:\Windows\Minidump")
    }
    
    $lines.Add("")
    $lines.Add("=== STORAGE DRIVES ===")
    foreach ($d in $diagData.Disks) {
        $wearInfo = $diagData.Wear | Where-Object { $_.DeviceId -eq $d.DeviceId } | Select-Object -First 1
        $tempText = if ($wearInfo -and $wearInfo.Temperature) { "$($wearInfo.Temperature)°C" } else { "N/A" }
        $wearText = if ($wearInfo -and $wearInfo.Wear -ne $null) { "Wear: $($wearInfo.Wear)%" } else { "" }
        $lines.Add("Disk $($d.DeviceId): $($d.FriendlyName) | Health: $($d.HealthStatus) | Status: $($d.OperationalStatus) | Size: $([Math]::Round($d.Size/1GB, 2)) GB | Temp: $tempText $wearText")
    }
    
    $lines.Add("")
    $lines.Add("=== CRASH & REBOOT HISTORY (LATEST 20 EVENTS) ===")
    if ($diagData.CrashEvents.Count -eq 0) {
        $lines.Add("  No crash/reboot events found in the event log.")
    } else {
        foreach ($e in $diagData.CrashEvents | Select-Object -First 20) {
            $msg = $e.Message -replace "`r?`n", " "
            if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 117) + "..." }
            $lines.Add("[$($e.TimeCreated)] ID: $($e.Id) ($($e.ProviderName)) | $msg")
            if ($e.Analysis) {
                $lines.Add("   💡 ANALYSIS: $($e.Analysis)")
            }
        }
    }

    $lines.Add("")
    $lines.Add("=== KERNEL-WHEA OPERATIONAL EVENTS ===")
    if ($diagData.WheaEvents.Count -eq 0) {
        $lines.Add("  No Kernel-WHEA operational events found.")
    } else {
        foreach ($e in $diagData.WheaEvents | Select-Object -First 15) {
            $msg = $e.Message -replace "`r?`n", " "
            if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 117) + "..." }
            $lines.Add("[$($e.TimeCreated)] ID: $($e.Id) | $msg")
        }
    }
    
    $lines.Add("")
    $lines.Add("=== SYSTEM LOG HARDWARE / WHEA WARNINGS & ERRORS ===")
    if ($diagData.SystemWheaEvents.Count -eq 0) {
        $lines.Add("  No WHEA hardware errors/warnings found in System log.")
    } else {
        foreach ($e in $diagData.SystemWheaEvents) {
            $msg = $e.Message -replace "`r?`n", " "
            if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 117) + "..." }
            $lines.Add("[$($e.TimeCreated)] ID: $($e.Id) ($($e.ProviderName)) | $msg")
        }
    }

    $lines.Add("")
    $lines.Add("=== DIAGNOSTICS CONCLUSION & RECOMMENDATIONS ===")
    $hasVolmgr161 = $diagData.CrashEvents | Where-Object { $_.Id -eq 161 }
    if ($hasVolmgr161) {
        $lines.Add("🔴 [1] Εντοπίστηκε volmgr Event ID 161 (Αποτυχία Dump):")
        $lines.Add("       Το λειτουργικό σύστημα κατέρρευσε (BSOD) αλλά δεν κατάφερε να γράψει dump αρχείο")
        $lines.Add("       διότι η επικοινωνία με το δίσκο SSD χάθηκε ακαριαία (Device Protocol / Data Error).")
        $lines.Add("       Αυτό δείχνει αστάθεια PCIe bus, controller δίσκου ή τροφοδοσίας του SSD.")
    }
    
    if ($diagData.FastStartup -eq 1) {
        $lines.Add("🟡 [2] Το Fast Startup είναι Ενεργοποιημένο:")
        $lines.Add("       Συνιστάται η απενεργοποίησή του για να αποφευχθούν σφάλματα power-state transitions")
        $lines.Add("       που προκαλούν κρασαρίσματα κατά την εκκίνηση/τερματισμό.")
    }
    
    if ($diagData.BiosVersion -notlike "*1.32.*" -and ($diagData.Motherboard -like "*OptiPlex 7060*" -or $diagData.BiosVersion -match '1\.(1[0-9]|2[0-9]|3[0-1])\.')) {
        $lines.Add("🔵 [3] Outdated BIOS ($($diagData.BiosVersion)):")
        $lines.Add("       Η αναβάθμιση στην έκδοση 1.32.0 θα ενημερώσει το microcode της CPU και τις ρυθμίσεις")
        $lines.Add("       σταθερότητας του TPM και του chipset.")
    }
    
    return $lines
}

# CSV/Markdown Data Export
function Export-DiagnosticsReport {
    param(
        [string]$Target,
        $diagData
    )
    
    if (-not (Test-Path -LiteralPath $exportsDir)) {
        $null = New-Item -ItemType Directory -Path $exportsDir -Force
    }
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $mdFile = Join-Path -Path $exportsDir -ChildPath "report_${Target}_$timestamp.md"
    
    # Generate Markdown
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine("# System Diagnostics Report for $Target")
    $null = $sb.AppendLine("Generated on: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $null = $sb.AppendLine()
    
    $null = $sb.AppendLine("## System Specifications")
    $null = $sb.AppendLine("- **Model:** $($diagData.Motherboard)")
    $null = $sb.AppendLine("- **S/N:** $($diagData.MotherboardSerial)")
    $null = $sb.AppendLine("- **CPU:** $($diagData.Cpu)")
    $null = $sb.AppendLine("- **BIOS Version:** $($diagData.BiosVersion) ($($diagData.BiosReleaseDate))")
    $null = $sb.AppendLine("- **OS:** $($diagData.OSCaption) ($($diagData.OSArchitecture)) version $($diagData.OSVersion)")
    $null = $sb.AppendLine("- **Fast Startup:** $(if($diagData.FastStartup -eq 1){"Enabled"}else{"Disabled"})")
    $null = $sb.AppendLine()
    
    $null = $sb.AppendLine("## Storage Drives")
    $null = $sb.AppendLine("| Device ID | Friendly Name | Health | Status | Size (GB) |")
    $null = $sb.AppendLine("|---|---|---|---|---|")
    foreach ($d in $diagData.Disks) {
        $null = $sb.AppendLine("| $($d.DeviceId) | $($d.FriendlyName) | $($d.HealthStatus) | $($d.OperationalStatus) | $([Math]::Round($d.Size/1GB, 2)) |")
    }
    $null = $sb.AppendLine()
    
    $null = $sb.AppendLine("## Crash & Reboot Log History")
    $null = $sb.AppendLine("| Timestamp | Event ID | Provider | Message | Analysis |")
    $null = $sb.AppendLine("|---|---|---|---|---|")
    foreach ($e in $diagData.CrashEvents) {
        $msg = $e.Message -replace "`r?`n", " " -replace '\|', '/'
        $null = $sb.AppendLine("| $($e.TimeCreated) | $($e.Id) | $($e.ProviderName) | $msg | $($e.Analysis) |")
    }
    
    $sb.ToString() | Set-Content -LiteralPath $mdFile -Encoding UTF8
    
    # Export CSVs
    $csvCrash = Join-Path -Path $exportsDir -ChildPath "crashes_${Target}_$timestamp.csv"
    $diagData.CrashEvents | Export-Csv -Path $csvCrash -NoTypeInformation -Encoding UTF8
    
    $csvSpecs = Join-Path -Path $exportsDir -ChildPath "specs_${Target}_$timestamp.csv"
    [PSCustomObject]@{
        ComputerName   = $diagData.ComputerName
        Motherboard    = $diagData.Motherboard
        BiosVersion    = $diagData.BiosVersion
        OSCaption      = $diagData.OSCaption
        FastStartup    = $diagData.FastStartup
    } | Export-Csv -Path $csvSpecs -NoTypeInformation -Encoding UTF8

    return [PSCustomObject]@{
        MarkdownPath = $mdFile
        CsvCrashPath = $csvCrash
    }
}

# Action to Disable Fast Startup
function Disable-FastStartupAction {
    param(
        [string]$TargetComputer,
        [System.Management.Automation.PSCredential]$TargetCred
    )
    
    $isTargetRemote = -not [string]::IsNullOrEmpty($TargetComputer) -and 
                      ($TargetComputer -ne "localhost") -and 
                      ($TargetComputer -ne "127.0.0.1") -and 
                      ($TargetComputer -ne $env:COMPUTERNAME)
                      
    $cmdBlock = {
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0 -Force -ErrorAction Stop
    }
    
    if ($isTargetRemote) {
        $sessionParams = @{ ComputerName = $TargetComputer }
        if ($null -ne $TargetCred) { $sessionParams["Credential"] = $TargetCred }
        
        $session = New-PSSession @sessionParams -ErrorAction Stop
        try {
            Invoke-Command -Session $session -ScriptBlock $cmdBlock -ErrorAction Stop
            return $true
        } catch {
            return $false
        } finally {
            Remove-PSSession $session
        }
    } else {
        try {
            Invoke-Command -ScriptBlock $cmdBlock -ErrorAction Stop
            return $true
        } catch {
            # Try via gsudo if local access fails due to privileges
            try {
                & gsudo.exe pwsh -NoProfile -Command "Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Value 0 -Force"
                return $true
            } catch {
                return $false
            }
        }
    }
}

# TUI Rendering Scrollable Screen
function Show-ScrollableDiagText {
    param(
        [string]$Title,
        $diagData
    )
    
    $scrollOffset = 0
    $exitScroll = $false
    
    try {
        while (-not $exitScroll) {
            Lock-ViewportToWindow
            $width = Get-UiWidth
            $height = $Host.UI.RawUI.WindowSize.Height
            $maxVisibleLines = [Math]::Max(5, $height - 11)
            
            $rawLines = Get-FormattedDiagLines -diagData $diagData
            
            $frame = New-UiFrame
            Add-UiFrameBanner -Frame $frame -Title $Title -Subtitle "Up/Down/PgUp/PgDn to scroll. E to export. F to disable FastStartup. Esc to return." -Width $width
            
            $innerWidth = $width - 4
            $borderH = (Get-UiGlyph -Name BoxH) * $innerWidth
            Add-UiFrameLine -Frame $frame -Text "$($_C.H2)$(Get-UiGlyph -Name BoxTopLeft)$borderH$(Get-UiGlyph -Name BoxTopRight)$($_C.Reset)$($_C.EraseLn)"
            
            $endIndex = [Math]::Min($scrollOffset + $maxVisibleLines - 1, $rawLines.Count - 1)
            for ($i = $scrollOffset; $i -le $endIndex; $i++) {
                $lineText = $rawLines[$i].Replace("`t", "    ")
                
                if ($lineText.Length -gt $innerWidth) {
                    $lineText = $lineText.Substring(0, $innerWidth)
                }
                
                $padWidth = [Math]::Max(0, $innerWidth - $lineText.Length)
                $paddedText = $lineText + (' ' * $padWidth)
                
                # Apply custom colors
                $coloredText = $paddedText
                if ($paddedText -match '^===') {
                    $coloredText = "$($_C.Info)$($_C.Bold)$paddedText$($_C.Reset)"
                } elseif ($paddedText -match '^---') {
                    $coloredText = "$($_C.Dim)$paddedText$($_C.Reset)"
                } elseif ($paddedText -match '⚠️🚨 WARNING|volmgr Event ID 161') {
                    $coloredText = "$($_C.Fail)$($_C.Bold)$paddedText$($_C.Reset)"
                } elseif ($paddedText -match 'conclusion & recommendations') {
                    $coloredText = "$($_C.Gold)$($_C.Bold)$paddedText$($_C.Reset)"
                } else {
                    $coloredText = $coloredText -replace '\bENABLED\b', "$($_C.Fail)ENABLED$($_C.Reset)"
                    $coloredText = $coloredText -replace '\bDISABLED\b', "$($_C.OK)DISABLED$($_C.Reset)"
                    $coloredText = $coloredText -replace '💡 ANALYSIS:', "$($_C.Gold)💡 ANALYSIS:$($_C.Reset)"
                }
                
                Add-UiFrameLine -Frame $frame -Text "$($_C.H2)$(Get-UiGlyph -Name BoxV)$($_C.Reset) $coloredText $($_C.H2)$(Get-UiGlyph -Name BoxV)$($_C.Reset)$($_C.EraseLn)"
            }
            
            $printedCount = $endIndex - $scrollOffset + 1
            if ($printedCount -lt $maxVisibleLines) {
                for ($i = $printedCount; $i -lt $maxVisibleLines; $i++) {
                    $emptyPad = ' ' * $innerWidth
                    Add-UiFrameLine -Frame $frame -Text "$($_C.H2)$(Get-UiGlyph -Name BoxV)$($_C.Reset) $emptyPad $($_C.H2)$(Get-UiGlyph -Name BoxV)$($_C.Reset)$($_C.EraseLn)"
                }
            }
            
            Add-UiFrameLine -Frame $frame -Text "$($_C.H2)$(Get-UiGlyph -Name BoxBottomLeft)$borderH$(Get-UiGlyph -Name BoxBottomRight)$($_C.Reset)$($_C.EraseLn)"
            Add-UiFrameLine -Frame $frame
            
            $scrollInfo = "Line $($scrollOffset + 1) of $($rawLines.Count)"
            $segments = @(
                New-UiShortcutSegment -Text "$(Get-UiGlyph -Name Up)$(Get-UiGlyph -Name Down)" -Color $_C.White
                New-UiShortcutSegment -Text " Scroll ($scrollInfo)   " -Color $_C.Dim
                New-UiShortcutSegment -Text "E" -Color $_C.Gold
                New-UiShortcutSegment -Text " = export   " -Color $_C.Dim
                New-UiShortcutSegment -Text "F" -Color $_C.Cyan
                New-UiShortcutSegment -Text " = fix FastStartup   " -Color $_C.Dim
                New-UiShortcutSegment -Text "Esc" -Color $_C.Fail
                New-UiShortcutSegment -Text " = back" -Color $_C.Dim
            )
            Add-UiFrameShortcutSegments -Frame $frame -Segments $segments -Width $width
            Write-UiFrame -Frame $frame
            
            $key = Read-ConsoleKey
            switch ($key.Key) {
                'UpArrow' { $scrollOffset = [Math]::Max(0, $scrollOffset - 1) }
                'DownArrow' { $scrollOffset = [Math]::Min([Math]::Max(0, $rawLines.Count - $maxVisibleLines), $scrollOffset + 1) }
                'PageUp' { $scrollOffset = [Math]::Max(0, $scrollOffset - $maxVisibleLines) }
                'PageDown' { $scrollOffset = [Math]::Min([Math]::Max(0, $rawLines.Count - $maxVisibleLines), $scrollOffset + $maxVisibleLines) }
                'E' {
                    # Export action
                    Clear-TuiScreen
                    Write-Host "Exporting diagnostics report..." -ForegroundColor Gray
                    $exports = Export-DiagnosticsReport -Target $diagData.ComputerName -diagData $diagData
                    Write-Host "`n✅ Report saved to:" -ForegroundColor Green
                    Write-Host "   Markdown: $($exports.MarkdownPath)" -ForegroundColor White
                    Write-Host "   CSV:      $($exports.CsvCrashPath)" -ForegroundColor White
                    Write-Host "`nPress any key to return..." -ForegroundColor Gray
                    $null = [Console]::ReadKey($true)
                    $script:RequestForceClear = $true
                }
                'F' {
                    # Fix Fast Startup action
                    Clear-TuiScreen
                    Write-Host "Disabling Fast Startup on $($diagData.ComputerName)..." -ForegroundColor Yellow
                    $isRemoteComputer = -not [string]::IsNullOrEmpty($ComputerName) -and ($ComputerName -ne $env:COMPUTERNAME)
                    $credToUse = if ($isRemoteComputer) { $Credential } else { $null }
                    $compToUse = if ($isRemoteComputer) { $ComputerName } else { "" }
                    
                    $success = Disable-FastStartupAction -TargetComputer $compToUse -TargetCred $credToUse
                    if ($success) {
                        Write-Host "`n✅ Successfully disabled Fast Startup!" -ForegroundColor Green
                        # Update local diagnostic representation
                        $diagData.FastStartup = 0
                    } else {
                        Write-Host "`n❌ Failed to disable Fast Startup. Ensure you have admin access." -ForegroundColor Red
                    }
                    Write-Host "`nPress any key to return..." -ForegroundColor Gray
                    $null = [Console]::ReadKey($true)
                    $script:RequestForceClear = $true
                }
                'Escape' { $exitScroll = $true }
                'ResizeEvent' { $script:RequestForceClear = $true }
            }
        }
    } finally {
        $script:RequestForceClear = $true
    }
}

# TUI Flow Functions
function Show-LocalDiagFlow {
    Clear-TuiScreen
    Write-Host "Gathering local event logs and hardware diagnostics..." -ForegroundColor Gray
    try {
        $data = Get-DiagnosticsData -TargetComputer "localhost"
        Show-ScrollableDiagText -Title "Local PC Diagnostics Details" -diagData $data
    } catch {
        Clear-TuiScreen
        Write-Host "❌ Error gathering local diagnostics: $_" -ForegroundColor Red
        Write-Host "`nPress any key to return to menu..." -ForegroundColor Gray
        $null = [Console]::ReadKey($true)
    }
}

function Run-RemoteDiagFlow {
    param(
        [string]$TargetComputer,
        [string]$TargetName,
        [string]$DefaultUser
    )
    
    Clear-TuiScreen
    Write-Host "Connecting to $TargetName ($TargetComputer) via WinRM..." -ForegroundColor Gray
    
    $credToUse = $null
    
    # Prompt for credential if none exists
    if ($null -eq $Credential) {
        Write-Host "`nEnter WinRM credentials for target PC." -ForegroundColor White
        Write-Host "Username [default: $DefaultUser]: " -NoNewline -ForegroundColor Gray
        $inputUser = Read-Host
        $user = if ([string]::IsNullOrWhiteSpace($inputUser)) { $DefaultUser } else { $inputUser }
        
        Write-Host "Password (press Enter if blank): " -NoNewline -ForegroundColor Gray
        $passSec = Read-Host -AsSecureString
        $credToUse = New-Object System.Management.Automation.PSCredential($user, $passSec)
    } else {
        $credToUse = $Credential
    }
    
    try {
        $data = Get-DiagnosticsData -TargetComputer $TargetComputer -TargetCred $credToUse
        # Save connection to history
        Add-ConnectionHistoryEntry -ComputerName $data.ComputerName -IPAddress $TargetComputer -UserName $credToUse.UserName
        
        Show-ScrollableDiagText -Title "Remote PC Diagnostics: $($data.ComputerName) ($TargetComputer)" -diagData $data
    } catch {
        Clear-TuiScreen
        Write-Host "❌ Failed to complete diagnostics on $TargetComputer." -ForegroundColor Red
        Write-Host "Error details: $_" -ForegroundColor DarkRed
        Write-Host "`nPress any key to return..." -ForegroundColor Gray
        $null = [Console]::ReadKey($true)
    }
}

function Connect-RemotePcFlow {
    Clear-TuiScreen
    Write-Host "=== Connect to Remote PC via WinRM ===" -ForegroundColor Cyan
    Write-Host "Enter Target IP Address or Computer Name: " -NoNewline -ForegroundColor White
    $target = Read-Host
    if ([string]::IsNullOrWhiteSpace($target)) { return }
    
    Run-RemoteDiagFlow -TargetComputer $target -TargetName $target -DefaultUser "Administrator"
}

function Invoke-LanScanFlow {
    Clear-TuiScreen
    Write-Host "Scanning local network for active WinRM hosts (port 5985)..." -ForegroundColor Yellow
    $hosts = Get-NetDiscoveredHosts
    
    if ($hosts.Count -eq 0) {
        Write-Host "`nNo hosts with open WinRM port (5985) discovered on the network." -ForegroundColor Red
        Write-Host "Press any key to return..." -ForegroundColor Gray
        $null = [Console]::ReadKey($true)
        return
    }
    
    $scanExit = $false
    $selIndex = 0
    
    try {
        while (-not $scanExit) {
            Lock-ViewportToWindow
            $width = Get-UiWidth
            $height = $Host.UI.RawUI.WindowSize.Height
            $maxVisible = [Math]::Max(3, $height - 8)
            
            $frame = New-UiFrame
            Add-UiFrameBanner -Frame $frame -Title "Network Discovered WinRM Hosts" -Subtitle "Select an active host and press Enter to connect." -Width $width
            Add-UiFrameSection -Frame $frame -Title "Discovered Active WinRM Targets" -Width $width
            
            for ($i = 0; $i -lt $hosts.Count; $i++) {
                $h = $hosts[$i]
                $lineText = "  $($h.HostName) ($($h.IP))"
                if ($i -eq $selIndex) {
                    Add-UiFrameLine -Frame $frame -Text "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $(Get-UiGlyph -Name SelectionArrow) $lineText $($_C.Reset)$($_C.EraseLn)"
                } else {
                    Add-UiFrameLine -Frame $frame -Text "    $($_C.White)$lineText$($_C.Reset)$($_C.EraseLn)"
                }
            }
            
            Add-UiFrameLine -Frame $frame
            $segments = @(
                New-UiShortcutSegment -Text "$(Get-UiGlyph -Name Up)$(Get-UiGlyph -Name Down)" -Color $_C.White
                New-UiShortcutSegment -Text ' navigate   ' -Color $_C.Dim
                New-UiShortcutSegment -Text 'Enter' -Color $_C.OK
                New-UiShortcutSegment -Text ' = connect   ' -Color $_C.Dim
                New-UiShortcutSegment -Text 'Esc' -Color $_C.Fail
                New-UiShortcutSegment -Text ' = back' -Color $_C.Dim
            )
            Add-UiFrameShortcutSegments -Frame $frame -Segments $segments -Width $width
            Write-UiFrame -Frame $frame
            
            $key = Read-ConsoleKey
            switch ($key.Key) {
                'UpArrow' { $selIndex = [Math]::Max(0, $selIndex - 1) }
                'DownArrow' { $selIndex = [Math]::Min($hosts.Count - 1, $selIndex + 1) }
                'Escape' { $scanExit = $true }
                'ResizeEvent' { $script:RequestForceClear = $true }
                'Enter' {
                    $selected = $hosts[$selIndex]
                    Run-RemoteDiagFlow -TargetComputer $selected.IP -TargetName $selected.HostName -DefaultUser "cbx_t"
                    $scanExit = $true
                }
            }
        }
    } finally {
        $script:RequestForceClear = $true
    }
}

function Clear-TuiScreen {
    [Console]::Write((Get-TuiForceClearSequence))
}

# Main TUI Loop Control Panel
function Invoke-EventViewerTui {
    Init-TuiHost
    Clear-TuiScreen
    
    $selectedIndex = 0
    $netInfo = Get-CurrentNetworkIdentity
    $networkName = $netInfo.ProfileName
    $networkId = $netInfo.NetworkId
    
    try {
        while ($true) {
            Lock-ViewportToWindow
            $width = Get-UiWidth
            
            # Rebuild Menu Options based on Connection History filtered by Network ID
            $menuOptions = [System.Collections.Generic.List[string]]::new()
            $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
            
            $menuOptions.Add("Analyze Local PC Logs")
            $actions.Add([PSCustomObject]@{ Type = 'Local'; Label = "Analyze Local PC Logs" })
            
            $menuOptions.Add("Scan Local Network (Ctrl+L)")
            $actions.Add([PSCustomObject]@{ Type = 'Scan'; Label = "Scan Local Network" })
            
            $menuOptions.Add("Connect to Remote PC (IP/Name)")
            $actions.Add([PSCustomObject]@{ Type = 'ConnectNew'; Label = "Connect to Remote PC" })
            
            # Connection History
            $history = Get-ConnectionHistory | Where-Object { $_.NetworkId -eq $networkId }
            if ($history -and @($history).Count -gt 0) {
                $menuOptions.Add("--- Connection History ($networkName) ---")
                $actions.Add([PSCustomObject]@{ Type = 'Header'; Label = "Header" })
                
                foreach ($h in @($history)) {
                    $displayName = if ($h.ComputerName -eq $h.IPAddress) {
                        "  $($h.IPAddress) (user: $($h.UserName))"
                    } else {
                        "  $($h.ComputerName) ($($h.IPAddress)) (user: $($h.UserName))"
                    }
                    $menuOptions.Add($displayName)
                    $actions.Add([PSCustomObject]@{ Type = 'HistoryEntry'; Data = $h; Label = $displayName })
                }
            }
            
            $menuOptions.Add("Exit")
            $actions.Add([PSCustomObject]@{ Type = 'Exit'; Label = "Exit" })
            
            if ($selectedIndex -ge $menuOptions.Count) {
                $selectedIndex = $menuOptions.Count - 1
            }
            if ($actions[$selectedIndex].Type -eq 'Header') {
                $selectedIndex++
            }
            
            $frame = New-UiFrame
            Add-UiFrameBanner -Frame $frame -Title "EventViewer Diagnostic TUI" -Subtitle "Hardware Crashes & Dump Diagnostics Tool | Active Network: $networkName" -Width $width
            Add-UiFrameSection -Frame $frame -Title "Main Options" -Width $width
            
            for ($i = 0; $i -lt $menuOptions.Count; $i++) {
                if ($i -eq $selectedIndex) {
                    Add-UiFrameLine -Frame $frame -Text "$($_C.SelBg)$($_C.SelFg)$($_C.Bold)  $(Get-UiGlyph -Name SelectionArrow) $($menuOptions[$i]) $($_C.Reset)$($_C.EraseLn)"
                } else {
                    if ($actions[$i].Type -eq 'Header') {
                        Add-UiFrameLine -Frame $frame -Text "  $($_C.Info)$($menuOptions[$i])$($_C.Reset)$($_C.EraseLn)"
                    } else {
                        Add-UiFrameLine -Frame $frame -Text "    $($_C.White)$($menuOptions[$i])$($_C.Reset)$($_C.EraseLn)"
                    }
                }
            }
            
            Add-UiFrameLine -Frame $frame
            $segments = @(
                New-UiShortcutSegment -Text "$(Get-UiGlyph -Name Up)$(Get-UiGlyph -Name Down)" -Color $_C.White
                New-UiShortcutSegment -Text ' navigate   ' -Color $_C.Dim
                New-UiShortcutSegment -Text 'Enter' -Color $_C.OK
                New-UiShortcutSegment -Text ' = select   ' -Color $_C.Dim
                New-UiShortcutSegment -Text 'Ctrl+L' -Color $_C.Gold
                New-UiShortcutSegment -Text ' = scan network   ' -Color $_C.Dim
                New-UiShortcutSegment -Text 'Esc' -Color $_C.Fail
                New-UiShortcutSegment -Text ' = exit' -Color $_C.Dim
            )
            Add-UiFrameShortcutSegments -Frame $frame -Segments $segments -Width $width
            Write-UiFrame -Frame $frame
            
            $key = Read-ConsoleKey
            if ($key.KeyChar -eq [char]12 -or ($key.Key -eq 'L' -and $key.VirtualKeyCode -eq 76)) {
                Invoke-LanScanFlow
                $script:RequestForceClear = $true
                continue
            }
            
            switch ($key.Key) {
                'UpArrow' {
                    $selectedIndex = [Math]::Max(0, $selectedIndex - 1)
                    if ($actions[$selectedIndex].Type -eq 'Header') {
                        $selectedIndex = [Math]::Max(0, $selectedIndex - 1)
                    }
                }
                'DownArrow' {
                    $selectedIndex = [Math]::Min($menuOptions.Count - 1, $selectedIndex + 1)
                    if ($actions[$selectedIndex].Type -eq 'Header') {
                        $selectedIndex = [Math]::Min($menuOptions.Count - 1, $selectedIndex + 1)
                    }
                }
                'Escape' { return }
                'ResizeEvent' { continue }
                'Enter' {
                    $action = $actions[$selectedIndex]
                    switch ($action.Type) {
                        'Local' { Show-LocalDiagFlow }
                        'Scan' { Invoke-LanScanFlow }
                        'ConnectNew' { Connect-RemotePcFlow }
                        'HistoryEntry' {
                            Run-RemoteDiagFlow -TargetComputer $action.Data.IPAddress -TargetName $action.Data.ComputerName -DefaultUser $action.Data.UserName
                        }
                        'Exit' { return }
                    }
                    $script:RequestForceClear = $true
                }
            }
        }
    } finally {
        Restore-TuiHost
    }
}

# CLI Mode Functions
function Show-DiagnosticsCli {
    $targetName = if ($isRemote) { $ComputerName } else { "localhost" }
    Write-Host "Initializing EventViewer Diagnostics check for target: $targetName" -ForegroundColor Cyan
    
    try {
        $data = Get-DiagnosticsData -TargetComputer $targetName -TargetCred $Credential
        $reportLines = Get-FormattedDiagLines -diagData $data
        
        foreach ($l in $reportLines) {
            # Basic colorization for CLI stdout
            if ($l -match '⚠️🚨 WARNING|volmgr Event ID 161') {
                Write-Host $l -ForegroundColor Red
            } elseif ($l -match '===') {
                Write-Host $l -ForegroundColor Cyan
            } elseif ($l -match 'conclusion & recommendations') {
                Write-Host $l -ForegroundColor Yellow -Bold
            } else {
                Write-Host $l
            }
        }
        
        # Auto export in CLI mode
        $exports = Export-DiagnosticsReport -Target $data.ComputerName -diagData $data
        Write-Host "`n✅ Report successfully exported:" -ForegroundColor Green
        Write-Host "   Markdown: $($exports.MarkdownPath)" -ForegroundColor White
        Write-Host "   CSV:      $($exports.CsvCrashPath)" -ForegroundColor White
        
    } catch {
        Write-Error "❌ Error retrieving diagnostics data: $_"
    }
}

# Main Execution Entry Point
if ($runTui) {
    Invoke-EventViewerTui
} else {
    Show-DiagnosticsCli
}
