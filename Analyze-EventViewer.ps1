# Analyze-EventViewer.ps1
# Script to diagnose system crashes, WHEA errors, and volmgr dump failures (Event ID 161).
# Supports both CLI output mode and interactive TUI mode (PS_UI_Blueprint).

param(
    [Parameter(Mandatory = $false, HelpMessage = "Enter the target ComputerName or IP Address (e.g. 192.168.1.47)")]
    [string]$ComputerName,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$UserName = 'Administrator',

    [Parameter(Mandatory = $false)]
    [switch]$BlankPassword,

    [Parameter(Mandatory = $false)]
    [switch]$Interactive
)

$winRMDiscoveryManifest = Join-Path -Path $PSScriptRoot -ChildPath '.assets\WinRMDiscovery\WinRMDiscovery.psd1'
$eventViewerConnector = Join-Path -Path $PSScriptRoot -ChildPath 'internal\EventViewer\Connect-EventViewerTarget.ps1'
foreach ($requiredPath in @($winRMDiscoveryManifest, $eventViewerConnector)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required shared WinRM component not found: $requiredPath"
    }
}
Import-Module -Name $winRMDiscoveryManifest -Force -ErrorAction Stop
. $eventViewerConnector

function Write-EventViewerWinRMConnectionStatus {
    param([Parameter(Mandatory)]$Status)

    $statusColor = if ($Status.State -in @('AttemptFailed', 'Failed')) {
        'Yellow'
    } elseif ($Status.State -eq 'Connected') {
        'Green'
    } else {
        'Cyan'
    }
    Write-Host "  WinRM: $($Status.Message)" -ForegroundColor $statusColor
}

function Write-EventViewerWinRMWorkshopStatus {
    param([Parameter(Mandatory)]$Status)

    $statusColor = if ($Status.State -eq 'Ready') {
        'Green'
    } elseif ($Status.State -eq 'Narrowing') {
        'Yellow'
    } else {
        'Cyan'
    }
    Write-Host "  WinRM setup: $($Status.Message)" -ForegroundColor $statusColor
}

$isRemote = -not [string]::IsNullOrEmpty($ComputerName) -and 
            ($ComputerName -ne "localhost") -and 
            ($ComputerName -ne "127.0.0.1") -and 
            ($ComputerName -ne $env:COMPUTERNAME)

$runTui = $Interactive -or ($null -eq $PSBoundParameters["ComputerName"] -and $null -eq $PSBoundParameters["Credential"])
$script:EventViewerUserNameWasExplicit = $PSBoundParameters.ContainsKey('UserName')
$script:EventViewerCredentialWasExplicit = $PSBoundParameters.ContainsKey('Credential')

if ($runTui) {
    $blueprintCandidates = @(
        (Join-Path $env:USERPROFILE '.agent-shared\templates\PS_UI_Blueprint.psm1')
        'C:\Users\joty79\.agent-shared\templates\PS_UI_Blueprint.psm1'
        'D:\Users\joty79\.agent-shared\templates\PS_UI_Blueprint.psm1'
    ) | Select-Object -Unique
    $blueprintPath = @(
        $blueprintCandidates | Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf
        }
    ) | Select-Object -First 1

    if (-not [string]::IsNullOrWhiteSpace($blueprintPath)) {
        Invoke-Expression (Get-Content -Raw -LiteralPath $blueprintPath)
    } else {
        Write-Warning "Could not find the canonical TUI Blueprint in any resolved .agent-shared root."
        Write-Warning "Falling back to standard CLI mode..."
        $runTui = $false
    }
}

# Paths
$exportsDir = Join-Path -Path $PSScriptRoot -ChildPath 'exports'

# Core Data Retrieval Function (Local or Remote)
function Get-DiagnosticsData {
    param(
        [string]$TargetComputer,
        [System.Management.Automation.PSCredential]$TargetCred,
        [string]$TargetUserName = 'Administrator',
        [string[]]$TargetAliases,
        [switch]$TargetBlankPassword
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
        
        # SafeBoot & Fast Startup Configuration
        $safeBootOption = $null
        $safeBootStatus = 'Unknown (SafeBoot query unavailable)'
        try {
            $safeBootState = Get-ItemProperty `
                -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option' `
                -ErrorAction Stop
            $safeBootOptionProperty = $safeBootState.PSObject.Properties['Option']
            if ($null -eq $safeBootOptionProperty) {
                $safeBootStatus = 'Unknown (SafeBoot Option value missing)'
            } else {
                $safeBootOption = $safeBootOptionProperty.Value
                $safeBootStatus = if ($safeBootOption -eq 1) {
                    'Safe Mode (Minimal)'
                } elseif ($safeBootOption -eq 2) {
                    'Safe Mode (With Networking)'
                } else {
                    "Unknown (SafeBoot Option=$safeBootOption)"
                }
            }
        } catch {
            if ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound) {
                $safeBootStatus = 'Normal Boot (SafeBoot Option key absent)'
            }
        }

        $fastStartup = $null
        $hiberboot = $null
        $hiberGlobal = $null
        $hiberFileExists = $null
        $powerCfgAvailableStates = @()
        $powerCfgQuerySucceeded = $false
        try {
            $hiberboot = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -ErrorAction Stop).HiberbootEnabled
            $fastStartup = [int]$hiberboot
        } catch {}
        try {
            $hiberGlobal = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name "HibernateEnabled" -ErrorAction Stop).HibernateEnabled
        } catch {}
        try {
            $hiberFileExists = Test-Path -Path "$env:SystemDrive\hiberfil.sys" -ErrorAction Stop
        } catch {}

        try {
            $powerCfgAvailableStates = @(& powercfg.exe /a 2>&1 | ForEach-Object { [string]$_ })
            $powerCfgQuerySucceeded = ($LASTEXITCODE -eq 0)
        } catch {}


        # Dump Configuration & Path Resolution
        $crashControl = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" -ErrorAction SilentlyContinue
        $dumpFilePath = if ($crashControl.DumpFile) { [Environment]::ExpandEnvironmentVariables($crashControl.DumpFile) } else { "C:\Windows\MEMORY.DMP" }
        $minidumpDirPath = if ($crashControl.MinidumpDir) { [Environment]::ExpandEnvironmentVariables($crashControl.MinidumpDir) } else { "C:\Windows\Minidump" }
        
        # Physical Disks Info
        $disks = @()
        $diskQuerySucceeded = $false
        try {
            $disks = @(Get-PhysicalDisk -ErrorAction Stop | Select-Object DeviceId, FriendlyName, OperationalStatus, HealthStatus, Size)
            $diskQuerySucceeded = $true
        } catch {}
        $wear = @()
        $wearQuerySucceeded = $false
        try {
            $wear = @(Get-PhysicalDisk -ErrorAction Stop | Get-StorageReliabilityCounter -ErrorAction Stop | Select-Object DeviceId, Wear, Temperature)
            $wearQuerySucceeded = $true
        } catch {}

        # Check for dump files on configured paths
        $memoryDmp = Get-Item -Path $dumpFilePath -ErrorAction SilentlyContinue | Select-Object FullName, Length, LastWriteTime
        $minidumps = Get-ChildItem -Path $minidumpDirPath -Filter "*.dmp" -ErrorAction SilentlyContinue | Select-Object FullName, Length, LastWriteTime

        # PnP Hardware Device Errors & Disabled Devices (ConfigManagerErrorCode != 0)
        $pnpErrors = [System.Collections.Generic.List[object]]::new()
        $pnpQuerySucceeded = $false
        try {
            $errDevs = Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.ConfigManagerErrorCode -ne 0 }
            $pnpQuerySucceeded = $true
            if ($errDevs) {
                foreach ($d in $errDevs) {
                    $pnpErrors.Add([PSCustomObject]@{
                        Name                   = $d.Name
                        ConfigManagerErrorCode = $d.ConfigManagerErrorCode
                        Status                 = $d.Status
                        Manufacturer           = $d.Manufacturer
                        DeviceID               = $d.DeviceID
                    })
                }
            }
        } catch {}

        # Read Crash / Unexpected Shutdown / Boot / volmgr Events
        # ID 41: Kernel-Power unexpected reboot
        # ID 6008: Unexpected shutdown
        # ID 1001: Bugcheck
        # ID 161: volmgr dump file creation failed
        $crashEvents = [System.Collections.Generic.List[object]]::new()
        $crashEventQuerySucceeded = $false
        try {
            $events = Get-WinEvent -FilterHashtable @{LogName='System'; Id=@(41, 6008, 1001, 161)} -MaxEvents 50 -ErrorAction Stop
            $crashEventQuerySucceeded = $true
            if ($events) {
                foreach ($e in $events) {
                    $decoded = ""
                    if ($e.Id -eq 161 -and $e.Message -match 'BugCheckProgress:\s*([0-9A-Fa-f]+)') {
                        $decoded = Decode-VolmgrCode -progressStr $Matches[1]
                    } elseif ($e.Id -eq 41) {
                        try {
                            $xml = [xml]$e.ToXml()
                            $dataHash = @{}
                            foreach ($d in $xml.Event.EventData.Data) { $dataHash[$d.Name] = $d.'#text' }
                            $bc = if ($dataHash.ContainsKey('BugcheckCode')) { $dataHash['BugcheckCode'] } else { '0' }
                            $pb = if ($dataHash.ContainsKey('PowerButtonTimestamp')) { $dataHash['PowerButtonTimestamp'] } else { '0' }
                            if ($bc -eq '0' -and $pb -ne '0' -and $pb -ne '' -and $pb -ne '0x0') {
                                $decoded = "Hard restart via Power Button press (BugcheckCode=0, PowerButtonTimestamp=$pb)."
                            } elseif ($bc -ne '0' -and $bc -ne '0x0') {
                                $decoded = "BSOD BugcheckCode: 0x{0:X}" -f [int64]$bc
                            }
                        } catch {}
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
        } catch {
            if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') {
                $crashEventQuerySucceeded = $true
            }
        }

        # Read WHEA events from log
        # Microsoft-Windows-Kernel-WHEA/Operational has record of sources initialized, attestation, errors
        $wheaEvents = [System.Collections.Generic.List[object]]::new()
        $wheaOperationalQuerySucceeded = $false
        try {
            $events = Get-WinEvent -LogName "Microsoft-Windows-Kernel-WHEA/Operational" -MaxEvents 30 -ErrorAction Stop
            $wheaOperationalQuerySucceeded = $true
            if ($events) {
                foreach ($e in $events) {
                    $wheaEvents.Add([PSCustomObject]@{
                        TimeCreated = $e.TimeCreated
                        Id          = $e.Id
                        Message     = $e.Message
                    })
                }
            }
        } catch {
            if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') {
                $wheaOperationalQuerySucceeded = $true
            }
        }

        # Read System Log Warnings/Errors containing "WHEA" or "hardware error"
        $systemWheaEvents = [System.Collections.Generic.List[object]]::new()
        $systemWheaQuerySucceeded = $false
        try {
            $events = Get-WinEvent -FilterHashtable @{
                LogName      = 'System'
                ProviderName = 'Microsoft-Windows-WHEA-Logger'
            } -MaxEvents 20 -ErrorAction Stop
            $systemWheaQuerySucceeded = $true
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
        } catch {
            if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') {
                $systemWheaQuerySucceeded = $true
            }
        }

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
            SafeBootStatus    = $safeBootStatus
            FastStartup       = $fastStartup
            HiberbootPreference = $hiberboot
            HibernateEnabled  = $hiberGlobal
            HiberFileExists   = $hiberFileExists
            PowerCfgAvailableStates = $powerCfgAvailableStates
            PowerCfgQuerySucceeded = $powerCfgQuerySucceeded
            CrashControl      = [PSCustomObject]@{
                CrashDumpEnabled = $crashControl.CrashDumpEnabled
                DumpFile         = $dumpFilePath
                MinidumpDir      = $minidumpDirPath
            }
            Disks             = $disks
            DiskQuerySucceeded = $diskQuerySucceeded
            Wear              = $wear
            WearQuerySucceeded = $wearQuerySucceeded
            MemoryDmp         = $memoryDmp
            Minidumps         = $minidumps
            PnpErrors         = $pnpErrors
            PnpQuerySucceeded = $pnpQuerySucceeded
            CrashEvents       = $crashEvents
            CrashEventQuerySucceeded = $crashEventQuerySucceeded
            WheaEvents        = $wheaEvents
            WheaOperationalQuerySucceeded = $wheaOperationalQuerySucceeded
            SystemWheaEvents  = $systemWheaEvents
            SystemWheaQuerySucceeded = $systemWheaQuerySucceeded
        }
    }


    if ($isTargetRemote) {
        $session = Connect-EventViewerTarget `
            -ComputerName $TargetComputer `
            -ComputerAlias $TargetAliases `
            -UserName $TargetUserName `
            -Credential $TargetCred `
            -BlankPassword:$TargetBlankPassword
        try {
            $remoteData = Invoke-Command -Session $session -ScriptBlock $diagBlock -ErrorAction Stop
            $remoteData | Add-Member -NotePropertyName WinRMTarget -NotePropertyValue $TargetComputer -Force
            $remoteData | Add-Member -NotePropertyName WinRMUserName -NotePropertyValue $session.EventViewerCredential.UserName -Force
            $remoteData | Add-Member -NotePropertyName WinRMBlankPassword -NotePropertyValue ([bool]$TargetBlankPassword) -Force
            return $remoteData
        } finally {
            Remove-PSSession -Session $session
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
    
    $lines.Add("")
    $lines.Add("=== POWER & BOOT CONFIGURATION ===")
    $startupText = if ($diagData.FastStartup -eq 1) {
        "REGISTRY PREFERENCE ENABLED (δεν αποδεικνύει χρήση στο τελευταίο boot)"
    } elseif ($diagData.FastStartup -eq 0) {
        "REGISTRY PREFERENCE DISABLED"
    } else {
        "UNKNOWN (η registry preference δεν ήταν διαθέσιμη)"
    }
    $hibernateText = if ($null -eq $diagData.HibernateEnabled) { "Unknown" } else { [string]$diagData.HibernateEnabled }
    $hiberFileText = if ($null -eq $diagData.HiberFileExists) { "Unknown" } elseif ($diagData.HiberFileExists) { "Present" } else { "Not found" }
    $lines.Add("Boot Environment:         $($diagData.SafeBootStatus)")
    $lines.Add("Fast Startup (Hiberboot): $startupText")
    $lines.Add("HibernateEnabled:         $hibernateText")
    $lines.Add("hiberfil.sys:             $hiberFileText")
    if ($diagData.PowerCfgQuerySucceeded) {
        $lines.Add("powercfg /a:")
        foreach ($powerCfgLine in @($diagData.PowerCfgAvailableStates)) {
            if (-not [string]::IsNullOrWhiteSpace($powerCfgLine)) {
                $lines.Add("  $powerCfgLine")
            }
        }
    } else {
        $lines.Add("powercfg /a:              QUERY UNAVAILABLE")
    }
    
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
    $memoryDumpFullNameProperty = if ($null -ne $diagData.MemoryDmp) {
        $diagData.MemoryDmp.PSObject.Properties['FullName']
    } else {
        $null
    }
    if ($null -ne $memoryDumpFullNameProperty -and -not [string]::IsNullOrWhiteSpace([string]$memoryDumpFullNameProperty.Value)) {
        $lines.Add("MEMORY.DMP found: $($diagData.MemoryDmp.FullName) | Size: $([Math]::Round($diagData.MemoryDmp.Length/1MB, 2)) MB | Last Written: $($diagData.MemoryDmp.LastWriteTime)")
    } else {
        $lines.Add("MEMORY.DMP: NOT FOUND")
    }
    $validMinidumps = @(
        foreach ($dumpRecord in @($diagData.Minidumps)) {
            if ($null -eq $dumpRecord) { continue }
            $fullNameProperty = $dumpRecord.PSObject.Properties['FullName']
            if ($null -ne $fullNameProperty -and -not [string]::IsNullOrWhiteSpace([string]$fullNameProperty.Value)) {
                $dumpRecord
            }
        }
    )
    if ($validMinidumps.Count -gt 0) {
        $lines.Add("Minidump files found ($($validMinidumps.Count)):")
        foreach ($d in $validMinidumps) {
            $lines.Add("  - $([System.IO.Path]::GetFileName($d.FullName)) | Size: $([Math]::Round($d.Length/1KB, 2)) KB | Last Written: $($d.LastWriteTime)")
        }
    } else {
        $lines.Add("Minidumps: None found in $($diagData.CrashControl.MinidumpDir)")
    }
    
    $lines.Add("")
    $lines.Add("=== PNP DEVICES WITH NON-ZERO CONFIG MANAGER STATUS ===")
    if (-not $diagData.PnpQuerySucceeded) {
        $lines.Add("  PnP query unavailable; no absence claim can be made.")
    } elseif (-not $diagData.PnpErrors -or $diagData.PnpErrors.Count -eq 0) {
        $lines.Add("  No devices with a non-zero ConfigManagerErrorCode were returned.")
    } else {
        foreach ($dev in $diagData.PnpErrors) {
            $errCodeText = switch ($dev.ConfigManagerErrorCode) {
                22 { "Code 22 (Disabled; may be intentional — context required)" }
                31 { "Code 31 (Driver failed to load / missing driver)" }
                Default { "Code $($dev.ConfigManagerErrorCode)" }
            }
            $statusMarker = if ($dev.ConfigManagerErrorCode -eq 22) { "ℹ️" } else { "⚠️" }
            $lines.Add("$statusMarker [$($dev.Name)] | Status: $errCodeText | Manufacturer: $($dev.Manufacturer) | DeviceID: $($dev.DeviceID)")
        }
    }

    $lines.Add("")
    $lines.Add("=== STORAGE DRIVES ===")
    if (-not $diagData.DiskQuerySucceeded) {
        $lines.Add("  Physical-disk query unavailable; no disk-health claim can be made.")
    } else {
        foreach ($d in $diagData.Disks) {
            $wearInfo = $diagData.Wear | Where-Object { $_.DeviceId -eq $d.DeviceId } | Select-Object -First 1
            $tempText = if ($diagData.WearQuerySucceeded -and $wearInfo -and $wearInfo.Temperature) { "$($wearInfo.Temperature)°C" } else { "N/A" }
            $wearText = if ($diagData.WearQuerySucceeded -and $wearInfo -and $wearInfo.Wear -ne $null) { "Wear counter: $($wearInfo.Wear)%" } else { "Wear counter: N/A" }
            $lines.Add("Disk $($d.DeviceId): $($d.FriendlyName) | Windows HealthStatus: $($d.HealthStatus) | OperationalStatus: $($d.OperationalStatus) | Size: $([Math]::Round($d.Size/1GB, 2)) GB | Temp: $tempText | $wearText")
        }
    }
    
    $lines.Add("")
    $lines.Add("=== CRASH & REBOOT HISTORY (LATEST 20 EVENTS) ===")
    if (-not $diagData.CrashEventQuerySucceeded) {
        $lines.Add("  System crash-event query unavailable; no absence claim can be made.")
    } elseif ($diagData.CrashEvents.Count -eq 0) {
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
    if (-not $diagData.WheaOperationalQuerySucceeded) {
        $lines.Add("  Kernel-WHEA Operational query unavailable; no absence claim can be made.")
    } elseif ($diagData.WheaEvents.Count -eq 0) {
        $lines.Add("  No Kernel-WHEA operational events found.")
    } else {
        foreach ($e in $diagData.WheaEvents | Select-Object -First 15) {
            $msg = $e.Message -replace "`r?`n", " "
            if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 117) + "..." }
            $lines.Add("[$($e.TimeCreated)] ID: $($e.Id) | $msg")
        }
    }
    
    $lines.Add("")
    $lines.Add("=== SYSTEM LOG MICROSOFT-WINDOWS-WHEA-LOGGER EVENTS ===")
    if (-not $diagData.SystemWheaQuerySucceeded) {
        $lines.Add("  Microsoft-Windows-WHEA-Logger query unavailable; no absence claim can be made.")
    } elseif ($diagData.SystemWheaEvents.Count -eq 0) {
        $lines.Add("  No Microsoft-Windows-WHEA-Logger events found in System log.")
    } else {
        foreach ($e in $diagData.SystemWheaEvents) {
            $msg = $e.Message -replace "`r?`n", " "
            if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 117) + "..." }
            $lines.Add("[$($e.TimeCreated)] ID: $($e.Id) ($($e.ProviderName)) | $msg")
        }
    }

    $lines.Add("")
    $lines.Add("=== DIAGNOSTICS CONCLUSION & RECOMMENDATIONS ===")
    $recIdx = 1

    $amdPspError = $diagData.PnpErrors | Where-Object {
        ($_.Name -like "*AMD PSP*" -or $_.Name -like "*Platform Security*") -and
        $_.ConfigManagerErrorCode -ne 22
    }
    if ($amdPspError) {
        $lines.Add("🔴 [$recIdx] Το AMD PSP Device επέστρεψε non-zero status διαφορετικό από intentional-disable Code 22:")
        $lines.Add("       Απαιτείται συσχέτιση με το ακριβές code, driver state και το incident πριν από remediation.")
        $recIdx++
    }
    $amdPspDisabled = $diagData.PnpErrors | Where-Object {
        ($_.Name -like "*AMD PSP*" -or $_.Name -like "*Platform Security*") -and
        $_.ConfigManagerErrorCode -eq 22
    }
    if ($amdPspDisabled) {
        $lines.Add("🟡 [$recIdx] Το AMD PSP Device είναι disabled (Code 22).")
        $lines.Add("       Αυτό μπορεί να είναι σκόπιμη ρύθμιση. Μην το ενεργοποιήσεις χωρίς επιβεβαίωση του intended state.")
        $recIdx++
    }


    $hasVolmgr161 = $diagData.CrashEvents | Where-Object { $_.Id -eq 161 }
    if ($hasVolmgr161) {
        $lines.Add("🔴 [$recIdx] Εντοπίστηκε volmgr Event ID 161 (Αποτυχία Dump):")
        $lines.Add("       Το event αποδεικνύει μόνο αποτυχία δημιουργίας dump· δεν αποδεικνύει από μόνο του")
        $lines.Add("       την αιτία του crash ούτε συγκεκριμένο SSD/controller disconnect.")
        $decodedStorageFailures = @($hasVolmgr161 | Where-Object {
                $_.Analysis -match 'STATUS_DEVICE_PROTOCOL_ERROR|STATUS_DEVICE_DATA_ERROR|STATUS_DEVICE_DOES_NOT_EXIST|STATUS_NO_SUCH_DEVICE'
            })
        if ($decodedStorageFailures.Count -gt 0) {
            $lines.Add("       Decoded status evidence υποστηρίζει πρόβλημα στο storage I/O path· απαιτείται συσχέτιση με")
            $lines.Add("       timestamps, controller/disk events και το πραγματικό dump configuration.")
        } else {
            $lines.Add("       Δεν αποκωδικοποιήθηκε storage status που να δικαιολογεί ισχυρότερο hardware συμπέρασμα.")
        }
        $recIdx++
    }
    
    if ($diagData.FastStartup -eq 1) {
        $lines.Add("🟡 [$recIdx] Η Fast Startup registry preference είναι enabled.")
        $lines.Add("       Αυτό δεν αποδεικνύει ότι χρησιμοποιήθηκε στο τελευταίο boot ή ότι προκάλεσε το incident.")
        $lines.Add("       Αξιολόγησε powercfg /a, hiberfil.sys και χρονική συσχέτιση πριν από αλλαγή.")
        $recIdx++
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
    $fastStartupExportText = if ($diagData.FastStartup -eq 1) {
        'Registry preference enabled'
    } elseif ($diagData.FastStartup -eq 0) {
        'Registry preference disabled'
    } else {
        'Unknown'
    }
    $null = $sb.AppendLine("- **Fast Startup:** $fastStartupExportText")
    $null = $sb.AppendLine("- **HibernateEnabled:** $($diagData.HibernateEnabled)")
    $null = $sb.AppendLine("- **hiberfil.sys present:** $($diagData.HiberFileExists)")
    $null = $sb.AppendLine()
    
    $null = $sb.AppendLine("## Storage Drives")
    $null = $sb.AppendLine("| Device ID | Friendly Name | Windows HealthStatus | OperationalStatus | Size (GB) |")
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
        HiberbootPreference = $diagData.HiberbootPreference
        HibernateEnabled = $diagData.HibernateEnabled
        HiberFileExists = $diagData.HiberFileExists
        PowerCfgQuerySucceeded = $diagData.PowerCfgQuerySucceeded
    } | Export-Csv -Path $csvSpecs -NoTypeInformation -Encoding UTF8

    return [PSCustomObject]@{
        MarkdownPath = $mdFile
        CsvCrashPath = $csvCrash
    }
}

# Action to Disable Fast Startup
function Invoke-VerifiedFastStartupDisable {
    [CmdletBinding()]
    param(
        [scriptblock]$ReadPreference = {
            (Get-ItemProperty `
                -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
                -Name 'HiberbootEnabled' `
                -ErrorAction Stop).HiberbootEnabled
        },

        [scriptblock]$WriteDisabledPreference = {
            Set-ItemProperty `
                -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
                -Name 'HiberbootEnabled' `
                -Value 0 `
                -Force `
                -ErrorAction Stop
        }
    )

    $beforeValue = & $ReadPreference
    if ($beforeValue -ne 0) {
        & $WriteDisabledPreference
    }
    $afterValue = & $ReadPreference

    [PSCustomObject]@{
        Success     = ($afterValue -eq 0)
        Verified    = ($afterValue -eq 0)
        Changed     = ($beforeValue -ne $afterValue)
        BeforeValue = $beforeValue
        AfterValue  = $afterValue
        ErrorMessage = ''
    }
}

function New-FastStartupFailureResult {
    param(
        [string]$ErrorMessage,
        [string]$ElevationPath
    )

    [PSCustomObject]@{
        Success       = $false
        Verified      = $false
        Changed       = $false
        BeforeValue   = $null
        AfterValue    = $null
        ElevationPath = $ElevationPath
        ErrorMessage  = $ErrorMessage
    }
}

function Disable-FastStartupAction {
    [CmdletBinding()]
    param(
        [string]$TargetComputer,
        [System.Management.Automation.PSCredential]$TargetCred,
        [string]$TargetUserName = 'Administrator',
        [switch]$TargetBlankPassword
    )
    
    $isTargetRemote = -not [string]::IsNullOrEmpty($TargetComputer) -and 
                      ($TargetComputer -ne "localhost") -and 
                      ($TargetComputer -ne "127.0.0.1") -and 
                      ($TargetComputer -ne $env:COMPUTERNAME)
    
    if ($isTargetRemote) {
        $session = $null
        try {
            $session = Connect-EventViewerTarget `
                -ComputerName $TargetComputer `
                -UserName $TargetUserName `
                -Credential $TargetCred `
                -BlankPassword:$TargetBlankPassword
            $result = Invoke-Command `
                -Session $session `
                -ScriptBlock ${function:Invoke-VerifiedFastStartupDisable} `
                -ErrorAction Stop
            $result | Add-Member -NotePropertyName ElevationPath -NotePropertyValue 'RemoteAuthenticatedSession' -Force
            return $result
        } catch {
            return New-FastStartupFailureResult `
                -ErrorMessage $_.Exception.Message `
                -ElevationPath 'RemoteAuthenticatedSession'
        } finally {
            if ($null -ne $session) {
                Remove-PSSession -Session $session
            }
        }
    }

    try {
        $result = Invoke-VerifiedFastStartupDisable
        $result | Add-Member -NotePropertyName ElevationPath -NotePropertyValue 'CurrentProcess' -Force
        return $result
    } catch {
        $directError = $_
        $needsElevation = (
            $directError.Exception -is [System.UnauthorizedAccessException] -or
            $directError.Exception -is [System.Security.SecurityException] -or
            $directError.Exception.Message -match 'access.*denied|requested registry access is not allowed'
        )
        if (-not $needsElevation) {
            return New-FastStartupFailureResult `
                -ErrorMessage $directError.Exception.Message `
                -ElevationPath 'CurrentProcess'
        }
    }

    $gsudoCommand = Get-Command -Name 'gsudo.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $gsudoCommand) {
        return New-FastStartupFailureResult `
            -ErrorMessage 'Administrator access is required and gsudo.exe was not found.' `
            -ElevationPath 'Unavailable'
    }

    $elevatedBody = @'
$ErrorActionPreference = 'Stop'
$path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$beforeValue = (Get-ItemProperty -Path $path -Name 'HiberbootEnabled' -ErrorAction Stop).HiberbootEnabled
if ($beforeValue -ne 0) {
    Set-ItemProperty -Path $path -Name 'HiberbootEnabled' -Value 0 -Force -ErrorAction Stop
}
$afterValue = (Get-ItemProperty -Path $path -Name 'HiberbootEnabled' -ErrorAction Stop).HiberbootEnabled
if ($afterValue -ne 0) {
    throw "HiberbootEnabled readback was '$afterValue', expected '0'."
}
$changed = $beforeValue -ne $afterValue
[Console]::Out.WriteLine(('EVENTVIEWER_FASTSTARTUP_RESULT|{0}|{1}|{2}' -f $beforeValue, $afterValue, $changed))
'@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($elevatedBody))
    try {
        $elevatedOutput = @(
            & $gsudoCommand.Source `
                pwsh.exe `
                -NoProfile `
                -OutputFormat Text `
                -EncodedCommand $encodedCommand 2>&1
        )
        $elevatedExitCode = $LASTEXITCODE
    } catch {
        return New-FastStartupFailureResult `
            -ErrorMessage $_.Exception.Message `
            -ElevationPath 'gsudo'
    }

    if ($elevatedExitCode -ne 0) {
        $errorText = @($elevatedOutput | ForEach-Object { [string]$_ }) -join ' '
        return New-FastStartupFailureResult `
            -ErrorMessage "gsudo exited with code $elevatedExitCode. $errorText" `
            -ElevationPath 'gsudo'
    }

    $resultPattern = [regex]'EVENTVIEWER_FASTSTARTUP_RESULT\|([^|]*)\|([^|]*)\|(True|False)'
    $resultMarker = @(
        $elevatedOutput | ForEach-Object { [string]$_ } |
            Where-Object { $resultPattern.IsMatch($_) }
    ) | Select-Object -Last 1
    $resultMatch = if ([string]::IsNullOrWhiteSpace($resultMarker)) {
        $null
    } else {
        $resultPattern.Match($resultMarker)
    }
    if ($null -eq $resultMatch -or -not $resultMatch.Success) {
        return New-FastStartupFailureResult `
            -ErrorMessage 'The elevated command returned no verified before/after marker.' `
            -ElevationPath 'gsudo'
    }

    $beforeValue = $resultMatch.Groups[1].Value
    $afterValue = $resultMatch.Groups[2].Value
    $changedValue = $resultMatch.Groups[3].Value
    [PSCustomObject]@{
        Success       = ($afterValue -eq '0')
        Verified      = ($afterValue -eq '0')
        Changed       = [Convert]::ToBoolean($changedValue)
        BeforeValue   = $beforeValue
        AfterValue    = $afterValue
        ElevationPath = 'gsudo'
        ErrorMessage  = ''
    }
}

function Read-EventViewerRemoteAccountSelection {
    param(
        [Parameter(Mandatory)]
        [string]$TargetName,

        [string]$DefaultUser = 'Administrator'
    )

    if ($script:EventViewerCredentialWasExplicit -and $null -ne $Credential) {
        return [PSCustomObject]@{
            UserName     = $Credential.UserName
            Credential   = $Credential
            BlankPassword = $false
        }
    }
    if ($script:EventViewerUserNameWasExplicit -or $BlankPassword) {
        return [PSCustomObject]@{
            UserName     = $UserName
            Credential   = $Credential
            BlankPassword = [bool]$BlankPassword
        }
    }

    Clear-TuiScreen
    Write-Host '=== Remote account selection ===' -ForegroundColor Cyan
    Write-Host "Target: $TargetName" -ForegroundColor Gray
    Write-Host ''
    Write-Host 'Enter the Windows account used by WinRM.' -ForegroundColor White
    Write-Host "ENTER = use '$DefaultUser'." -ForegroundColor Gray
    Write-Host 'You can cancel on the next screen with ESC.' -ForegroundColor Gray
    Write-Host 'Account: ' -NoNewline -ForegroundColor White
    try {
        [Console]::CursorVisible = $true
    } catch {}
    try {
        $enteredUser = Read-Host
    } finally {
        try {
            [Console]::CursorVisible = $false
        } catch {}
    }

    $selectedUser = if ([string]::IsNullOrWhiteSpace($enteredUser)) {
        $DefaultUser
    } else {
        $enteredUser.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($selectedUser)) {
        return $null
    }

    Write-Host ''
    Write-Host "Account selected: $selectedUser" -ForegroundColor Cyan
    Write-Host 'Choose authentication mode:' -ForegroundColor White
    Write-Host '  ENTER / P = saved DPAPI credential or secure credential prompt' -ForegroundColor Gray
    Write-Host '  B         = intentionally blank password (not saved)' -ForegroundColor Yellow
    Write-Host '  ESC       = cancel and return' -ForegroundColor Red

    while ($true) {
        $authKey = Read-ConsoleKey
        switch ($authKey.Key) {
            'Enter' {
                return [PSCustomObject]@{
                    UserName      = $selectedUser
                    Credential    = $null
                    BlankPassword = $false
                }
            }
            'P' {
                return [PSCustomObject]@{
                    UserName      = $selectedUser
                    Credential    = $null
                    BlankPassword = $false
                }
            }
            'B' {
                return [PSCustomObject]@{
                    UserName      = $selectedUser
                    Credential    = $null
                    BlankPassword = $true
                }
            }
            'Escape' { return $null }
            'ResizeEvent' {
                Write-Host ''
                Write-Host 'Window resized. ENTER/P = credential, B = blank password, ESC = cancel.' -ForegroundColor Gray
            }
        }
    }
}

function Confirm-FastStartupDisableAction {
    param(
        [Parameter(Mandatory)]
        $DiagnosticData
    )

    Clear-TuiScreen
    $targetLabel = if ([string]::IsNullOrWhiteSpace($DiagnosticData.WinRMTarget)) {
        $DiagnosticData.ComputerName
    } else {
        "$($DiagnosticData.ComputerName) via $($DiagnosticData.WinRMTarget)"
    }
    $currentPreference = if ($null -eq $DiagnosticData.FastStartup) {
        'unknown in the diagnostic snapshot'
    } else {
        [string]$DiagnosticData.FastStartup
    }

    Write-Host '=== Disable Fast Startup registry preference ===' -ForegroundColor Cyan
    Write-Host "Target: $targetLabel" -ForegroundColor Gray
    Write-Host "Snapshot HiberbootEnabled: $currentPreference" -ForegroundColor Gray
    Write-Host ''
    Write-Host 'This action reads the current value and writes 0 only when needed.' -ForegroundColor Yellow
    Write-Host 'Success requires Registry readback of HiberbootEnabled = 0.' -ForegroundColor Yellow
    Write-Host 'This does not prove Fast Startup caused or fixed the incident.' -ForegroundColor Yellow
    Write-Host 'No reboot, logoff, service restart, or WinRM interruption.' -ForegroundColor Gray
    Write-Host ''
    Write-Host 'ENTER = continue with the Registry change' -ForegroundColor Green
    Write-Host 'ESC   = cancel without changing anything' -ForegroundColor Red

    while ($true) {
        $confirmKey = Read-ConsoleKey
        switch ($confirmKey.Key) {
            'Enter' { return $true }
            'Escape' { return $false }
            'ResizeEvent' {
                Write-Host ''
                Write-Host 'Window resized. ENTER = continue; ESC = cancel.' -ForegroundColor Gray
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
            $maxVisibleLines = [Math]::Max(1, $height - 11)
            
            $rawLines = Get-FormattedDiagLines -diagData $diagData
            
            $frame = New-UiFrame
            Add-UiFrameBanner -Frame $frame -Title $Title -Subtitle "Up/Down/PgUp/PgDn scroll. E export. F disable registry preference. Esc back." -Width $width
            
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
                New-UiShortcutSegment -Text "F" -Color $_C.Info
                New-UiShortcutSegment -Text " = disable preference   " -Color $_C.Dim
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
                    if (-not (Confirm-FastStartupDisableAction -DiagnosticData $diagData)) {
                        $script:RequestForceClear = $true
                        continue
                    }

                    Clear-TuiScreen
                    Write-Host "Applying verified Fast Startup registry preference on $($diagData.ComputerName)..." -ForegroundColor Yellow
                    $isRemoteComputer = -not [string]::IsNullOrEmpty($diagData.WinRMTarget)
                    $credToUse = if ($isRemoteComputer) { $Credential } else { $null }
                    $compToUse = if ($isRemoteComputer) { $diagData.WinRMTarget } else { "" }
                    $userToUse = if ($isRemoteComputer) { $diagData.WinRMUserName } else { $UserName }
                    $blankPasswordToUse = if (
                        $isRemoteComputer -and
                        $null -ne $diagData.PSObject.Properties['WinRMBlankPassword']
                    ) {
                        [bool]$diagData.WinRMBlankPassword
                    } else {
                        $false
                    }

                    $result = Disable-FastStartupAction `
                        -TargetComputer $compToUse `
                        -TargetCred $credToUse `
                        -TargetUserName $userToUse `
                        -TargetBlankPassword:$blankPasswordToUse
                    if ($result.Verified) {
                        if ($result.Changed) {
                            Write-Host "`n✅ Registry change verified: HiberbootEnabled $($result.BeforeValue) -> $($result.AfterValue)." -ForegroundColor Green
                        } else {
                            Write-Host "`n✅ No Registry change was needed; verified HiberbootEnabled = $($result.AfterValue)." -ForegroundColor Green
                        }
                        Write-Host "   Execution path: $($result.ElevationPath)" -ForegroundColor Gray
                        $diagData.FastStartup = 0
                        $diagData.HiberbootPreference = 0
                    } else {
                        Write-Host "`n❌ Fast Startup Registry change was not verified." -ForegroundColor Red
                        Write-Host "   Path: $($result.ElevationPath)" -ForegroundColor Gray
                        Write-Host "   Error: $($result.ErrorMessage)" -ForegroundColor DarkRed
                    }
                    Write-Host '   No reboot or logoff was performed.' -ForegroundColor Gray
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
        [string]$DefaultUser,
        [string]$TargetMacAddress = 'Unknown',
        [System.Management.Automation.PSCredential]$TargetCredential,
        [switch]$TargetBlankPassword
    )
    
    Clear-TuiScreen
    Write-Host "Connecting to $TargetName ($TargetComputer) via WinRM..." -ForegroundColor Gray
    
    try {
        $data = Get-DiagnosticsData `
            -TargetComputer $TargetComputer `
            -TargetCred $TargetCredential `
            -TargetUserName $DefaultUser `
            -TargetAliases @($TargetName) `
            -TargetBlankPassword:$TargetBlankPassword
        # Canonical network-scoped history stores target metadata only, never credentials.
        $null = Add-WinRMConnectionHistoryEntry `
            -ComputerName $data.ComputerName `
            -LastIPAddress $TargetComputer `
            -MACAddress $TargetMacAddress `
            -UserName $data.WinRMUserName
        
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
    Write-Host 'ENTER on an empty target returns to the menu.' -ForegroundColor Gray
    Write-Host "Enter Target IP Address or Computer Name: " -NoNewline -ForegroundColor White
    try {
        [Console]::CursorVisible = $true
    } catch {}
    try {
        $target = Read-Host
    } finally {
        try {
            [Console]::CursorVisible = $false
        } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($target)) { return }

    $accountSelection = Read-EventViewerRemoteAccountSelection `
        -TargetName $target `
        -DefaultUser $UserName
    if ($null -eq $accountSelection) { return }

    Run-RemoteDiagFlow `
        -TargetComputer $target `
        -TargetName $target `
        -DefaultUser $accountSelection.UserName `
        -TargetCredential $accountSelection.Credential `
        -TargetBlankPassword:$accountSelection.BlankPassword
}

function Invoke-LanScanFlow {
    param([AllowEmptyString()][string]$NetworkId = '')

    Clear-TuiScreen
    Write-Host "Scanning local network for active WinRM hosts (port 5985)..." -ForegroundColor Yellow
    $hosts = @(
        Find-WinRMComputer -NetworkId $NetworkId -IncludeDiagnostics -DiagnosticsInMemoryOnly |
            Where-Object WinRMHttpOpen
    )
    
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
            $maxVisible = [Math]::Max(1, $height - 10)
            
            $frame = New-UiFrame
            Add-UiFrameBanner -Frame $frame -Title "Network Discovered WinRM Hosts" -Subtitle "Select an active host and press Enter to connect." -Width $width
            Add-UiFrameSection -Frame $frame -Title "Discovered Active WinRM Targets" -Width $width
            
            $viewTop = [Math]::Max(
                0,
                [Math]::Min(
                    $selIndex - [int]($maxVisible / 2),
                    [Math]::Max(0, $hosts.Count - $maxVisible)
                )
            )
            $viewBottom = [Math]::Min($viewTop + $maxVisible - 1, $hosts.Count - 1)

            for ($i = $viewTop; $i -le $viewBottom; $i++) {
                $h = $hosts[$i]
                $lineText = "  $($h.ComputerName) ($($h.IPAddress))"
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
                New-UiShortcutSegment -Text "$($viewTop + 1)-$($viewBottom + 1)/$($hosts.Count)   " -Color $_C.Dim
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
                    $accountSelection = Read-EventViewerRemoteAccountSelection `
                        -TargetName $selected.ComputerName `
                        -DefaultUser $UserName
                    if ($null -eq $accountSelection) {
                        $script:RequestForceClear = $true
                        continue
                    }
                    Run-RemoteDiagFlow `
                        -TargetComputer $selected.IPAddress `
                        -TargetName $selected.ComputerName `
                        -DefaultUser $accountSelection.UserName `
                        -TargetMacAddress $selected.MACAddress `
                        -TargetCredential $accountSelection.Credential `
                        -TargetBlankPassword:$accountSelection.BlankPassword
                    $scanExit = $true
                }
            }
        }
    } finally {
        $script:RequestForceClear = $true
    }
}

function Run-HistoryRemoteDiagFlow {
    param([Parameter(Mandatory)]$HistoryEntry)

    Clear-TuiScreen
    Write-Host "Resolving saved target $($HistoryEntry.ComputerName)..." -ForegroundColor Gray

    $lastIPAddress = if ($HistoryEntry.PSObject.Properties['LastIPAddress']) {
        [string]$HistoryEntry.LastIPAddress
    } else {
        [string]$HistoryEntry.IPAddress
    }
    $resolvedAddress = Resolve-WinRMHistoryTargetAddress `
        -ComputerName $HistoryEntry.ComputerName `
        -LastIPAddress $lastIPAddress `
        -MACAddress $HistoryEntry.MACAddress

    if ([string]::IsNullOrWhiteSpace($resolvedAddress)) {
        Write-Host "`n❌ The saved PC could not be verified at its current or last known address." -ForegroundColor Red
        Write-Host "Use Ctrl+L to discover it again." -ForegroundColor Yellow
        Write-Host "`nPress any key to return..." -ForegroundColor Gray
        $null = [Console]::ReadKey($true)
        return
    }

    $defaultUser = if (
        [string]::IsNullOrWhiteSpace([string]$HistoryEntry.UserName) -or
        [string]$HistoryEntry.UserName -eq 'Unknown'
    ) {
        $UserName
    } else {
        [string]$HistoryEntry.UserName
    }
    $accountSelection = Read-EventViewerRemoteAccountSelection `
        -TargetName $HistoryEntry.ComputerName `
        -DefaultUser $defaultUser
    if ($null -eq $accountSelection) { return }

    Run-RemoteDiagFlow `
        -TargetComputer $resolvedAddress `
        -TargetName $HistoryEntry.ComputerName `
        -DefaultUser $accountSelection.UserName `
        -TargetMacAddress $HistoryEntry.MACAddress `
        -TargetCredential $accountSelection.Credential `
        -TargetBlankPassword:$accountSelection.BlankPassword
}

function Clear-TuiScreen {
    [Console]::Write((Get-TuiForceClearSequence))
}

function Get-EventViewerCatalogTargetState {
    param(
        [Parameter(Mandatory)]$Entry,
        [bool]$HasFreshSnapshot
    )

    if ([bool]$Entry.HasDiscoverySnapshot) {
        if ([bool]$Entry.WinRMHttpOpen) { return 'online (fresh scan)' }
        if ([bool]$Entry.DetectedOnly) { return 'computer detected (fresh scan, management closed)' }
        if ([bool]$Entry.SMBOpen) { return 'online (fresh scan, WinRM disabled)' }
        return 'detected (fresh scan)'
    }
    if ([bool]$Entry.HasSavedHistory) {
        if ($HasFreshSnapshot) { return 'offline (fresh scan)' }
        return 'not checked'
    }
    return 'cached discovery'
}

# Main TUI Loop Control Panel
function Invoke-EventViewerTui {
    Initialize-TuiHost
    Clear-TuiScreen
    
    $selectedIndex = 0
    $netInfo = Get-WinRMNetworkIdentity
    $networkName = $netInfo.ProfileName
    $networkId = $netInfo.NetworkId
    
    try {
        while ($true) {
            Lock-ViewportToWindow
            $width = Get-UiWidth
            $height = $Host.UI.RawUI.WindowSize.Height
            
            # Rebuild Menu Options based on Connection History filtered by Network ID
            $menuOptions = [System.Collections.Generic.List[string]]::new()
            $actions = [System.Collections.Generic.List[PSCustomObject]]::new()
            
            $menuOptions.Add("Analyze Local PC Logs")
            $actions.Add([PSCustomObject]@{ Type = 'Local'; Label = "Analyze Local PC Logs" })
            
            $menuOptions.Add("Scan Local Network (Ctrl+L)")
            $actions.Add([PSCustomObject]@{ Type = 'Scan'; Label = "Scan Local Network" })
            
            $menuOptions.Add("Connect to Remote PC (IP/Name)")
            $actions.Add([PSCustomObject]@{ Type = 'ConnectNew'; Label = "Connect to Remote PC" })
            
            # Local-only target catalog: successful connection history plus a
            # short-lived snapshot from the last explicit discovery action.
            $catalog = Get-WinRMTargetCatalog -NetworkId $networkId
            $catalogTargets = @($catalog.Targets)
            $hasFreshDiscoverySnapshot = -not [string]::IsNullOrWhiteSpace([string]$catalog.SnapshotCapturedAtUtc)
            if ($catalogTargets.Count -gt 0) {
                $menuOptions.Add("--- Saved & Recent Targets ($networkName) ---")
                $actions.Add([PSCustomObject]@{ Type = 'Header'; Label = "Header" })

                foreach ($h in $catalogTargets) {
                    $historyAddress = if ([string]::IsNullOrWhiteSpace($h.IPAddress)) {
                        $h.ComputerName
                    } else {
                        $h.IPAddress
                    }
                    $targetState = Get-EventViewerCatalogTargetState -Entry $h -HasFreshSnapshot $hasFreshDiscoverySnapshot
                    $accountState = if (
                        [string]::IsNullOrWhiteSpace([string]$h.UserName) -or
                        [string]$h.UserName -eq 'Unknown'
                    ) {
                        'account: choose on connect'
                    } else {
                        "user: $($h.UserName)"
                    }
                    $displayName = if ($h.ComputerName -eq $historyAddress) {
                        "  $historyAddress ($accountState, $targetState)"
                    } else {
                        "  $($h.ComputerName) ($historyAddress) ($accountState, $targetState)"
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

            $maxVisibleMenuItems = [Math]::Max(1, $height - 10)
            $menuViewTop = [Math]::Max(
                0,
                [Math]::Min(
                    $selectedIndex - [int]($maxVisibleMenuItems / 2),
                    [Math]::Max(0, $menuOptions.Count - $maxVisibleMenuItems)
                )
            )
            $menuViewBottom = [Math]::Min(
                $menuViewTop + $maxVisibleMenuItems - 1,
                $menuOptions.Count - 1
            )

            for ($i = $menuViewTop; $i -le $menuViewBottom; $i++) {
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
                New-UiShortcutSegment -Text "$($menuViewTop + 1)-$($menuViewBottom + 1)/$($menuOptions.Count)   " -Color $_C.Dim
                New-UiShortcutSegment -Text 'Esc' -Color $_C.Fail
                New-UiShortcutSegment -Text ' = exit' -Color $_C.Dim
            )
            Add-UiFrameShortcutSegments -Frame $frame -Segments $segments -Width $width
            Write-UiFrame -Frame $frame
            
            $key = Read-ConsoleKey
            if ($key.KeyChar -eq [char]12) {
                Invoke-LanScanFlow -NetworkId $networkId
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
                        'Scan' { Invoke-LanScanFlow -NetworkId $networkId }
                        'ConnectNew' { Connect-RemotePcFlow }
                        'HistoryEntry' {
                            Run-HistoryRemoteDiagFlow -HistoryEntry $action.Data
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
        $data = Get-DiagnosticsData `
            -TargetComputer $targetName `
            -TargetCred $Credential `
            -TargetUserName $UserName `
            -TargetAliases @($ComputerName) `
            -TargetBlankPassword:$BlankPassword
        if ($isRemote) {
            $null = Add-WinRMConnectionHistoryEntry `
                -ComputerName $data.ComputerName `
                -LastIPAddress $ComputerName `
                -UserName $data.WinRMUserName
        }
        $reportLines = Get-FormattedDiagLines -diagData $data
        
        foreach ($l in $reportLines) {
            # Basic colorization for CLI stdout
            if ($l -match '⚠️🚨 WARNING|volmgr Event ID 161') {
                Write-Host $l -ForegroundColor Red
            } elseif ($l -match '===') {
                Write-Host $l -ForegroundColor Cyan
            } elseif ($l -match 'conclusion & recommendations') {
                Write-Host $l -ForegroundColor Yellow
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
        throw "❌ Error retrieving diagnostics data: $($_.Exception.Message)"
    }
}

# Main Execution Entry Point
if ($runTui) {
    Invoke-EventViewerTui
} else {
    Show-DiagnosticsCli
}
