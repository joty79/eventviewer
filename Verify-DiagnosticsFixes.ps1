# Verify-DiagnosticsFixes.ps1
# Script to verify the status of disk stability settings: Fast Startup, USB Selective Suspend, Hibernate, and Dirty Volumes.
# Can be run locally or remote (using Invoke-Command).

function Get-ValidationStatus {
    $report = [System.Collections.Generic.List[PSCustomObject]]::new()

    # 1. Fast Startup (Hiberboot)
    $hbPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
    $hbVal = $null
    if (Test-Path $hbPath) {
        $hbVal = (Get-ItemProperty -Path $hbPath -Name "HiberbootEnabled" -ErrorAction SilentlyContinue).HiberbootEnabled
    }
    $fastStartupStatus = "Unknown"
    $fastStartupColor = "Yellow"
    if ($hbVal -eq 0) {
        $fastStartupStatus = "DISABLED (Healthy - Prevents NTFS metadata corruption)"
        $fastStartupColor = "Green"
    } elseif ($hbVal -eq 1) {
        $fastStartupStatus = "ENABLED (Warning - Can cause dirty volume states on shutdown)"
        $fastStartupColor = "Red"
    } else {
        $fastStartupStatus = "Not Configured / Default"
    }

    $report.Add([PSCustomObject]@{
        Setting = "Fast Startup (Registry)"
        Status  = $fastStartupStatus
        Color   = $fastStartupColor
    })

    # 2. USB Selective Suspend (Driver Overrides)
    $usb3Path = "HKLM:\SYSTEM\CurrentControlSet\Services\USBHUB3\Parameters"
    $usb2Path = "HKLM:\SYSTEM\CurrentControlSet\Services\usbhub\Parameters"
    
    $u3Val = $null
    if (Test-Path $usb3Path) {
        $u3Val = (Get-ItemProperty -Path $usb3Path -Name "DisableSelectiveSuspend" -ErrorAction SilentlyContinue).DisableSelectiveSuspend
    }
    $u2Val = $null
    if (Test-Path $usb2Path) {
        $u2Val = (Get-ItemProperty -Path $usb2Path -Name "DisableSelectiveSuspend" -ErrorAction SilentlyContinue).DisableSelectiveSuspend
    }

    $usbStatus = "Unknown"
    $usbColor = "Yellow"
    if ($u3Val -eq 1 -and $u2Val -eq 1) {
        $usbStatus = "DISABLED (Healthy - Prevented system-wide on drivers level)"
        $usbColor = "Green"
    } elseif ($u3Val -eq 1 -or $u2Val -eq 1) {
        $usbStatus = "PARTIALLY DISABLED (Warning - Check USBHUB3 and usbhub services)"
        $usbColor = "Yellow"
    } else {
        $usbStatus = "ENABLED (Warning - May cause external USB drives to disconnect on idle)"
        $usbColor = "Red"
    }

    $report.Add([PSCustomObject]@{
        Setting = "USB Selective Suspend (Drivers)"
        Status  = $usbStatus
        Color   = $usbColor
    })

    # 3. USB Selective Suspend (Active Power Plan)
    # Look up active scheme registry
    $activeScheme = $null
    try {
        $schemes = powercfg.exe /getactivescheme
        if ($schemes -match "GUID:\s*([0-9A-Fa-f-]+)") {
            $activeScheme = $Matches[1]
        }
    } catch {}

    $powerPlanStatus = "Unknown"
    $powerPlanColor = "Yellow"
    if ($activeScheme) {
        $planPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$activeScheme\2a737441-1930-4402-8d77-b2bebba308a3\d430b239-d4d5-454f-8413-ee4e7e588656"
        if (Test-Path $planPath) {
            $ac = (Get-ItemProperty -Path $planPath -Name "ACSettingIndex" -ErrorAction SilentlyContinue).ACSettingIndex
            $dc = (Get-ItemProperty -Path $planPath -Name "DCSettingIndex" -ErrorAction SilentlyContinue).DCSettingIndex
            if ($ac -eq 0 -and $dc -eq 0) {
                $powerPlanStatus = "DISABLED (Healthy - Both Plugged-in & Battery set to 0)"
                $powerPlanColor = "Green"
            } elseif ($ac -eq 0 -or $dc -eq 0) {
                $powerPlanStatus = "PARTIALLY DISABLED (Warning - Check battery vs plugged-in setting)"
                $powerPlanColor = "Yellow"
            } else {
                $powerPlanStatus = "ENABLED (Warning - Configured to sleep in active power scheme)"
                $powerPlanColor = "Red"
            }
        } else {
            $powerPlanStatus = "Not defined in current scheme registry (uses Windows default)"
        }
    }

    $report.Add([PSCustomObject]@{
        Setting = "USB Selective Suspend (Power Plan)"
        Status  = $powerPlanStatus
        Color   = $powerPlanColor
    })

    # 4. Hibernate Status
    $hibPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Power"
    $hibVal = $null
    if (Test-Path $hibPath) {
        $hibVal = (Get-ItemProperty -Path $hibPath -Name "HibernateEnabled" -ErrorAction SilentlyContinue).HibernateEnabled
    }
    $hiberFileExists = Test-Path "C:\hiberfil.sys" -ErrorAction SilentlyContinue

    $hibStatus = "Unknown"
    $hibColor = "Yellow"
    if ($hibVal -eq 0 -and -not $hiberFileExists) {
        $hibStatus = "DISABLED (Healthy - hiberfil.sys removed, saves write cycles/SSD wear)"
        $hibColor = "Green"
    } elseif ($hibVal -eq 1 -or $hiberFileExists) {
        $hibStatus = "ENABLED (Warning - hiberfil.sys exists, check if required)"
        $hibColor = "Yellow"
    } else {
        $hibStatus = "Disabled (Hiberfil missing, HibernateEnabled is $hibVal)"
        $hibColor = "Green"
    }

    $report.Add([PSCustomObject]@{
        Setting = "Hibernate (Registry & File)"
        Status  = $hibStatus
        Color   = $hibColor
    })

    # 5. Connected Drives Dirty Status Check
    $outDrives = [System.Collections.Generic.List[string]]::new()
    $volumes = Get-Volume | Where-Object { $_.FileSystemType -eq 'NTFS' -and $_.DriveLetter }
    $dirtyCount = 0
    foreach ($v in $volumes) {
        try {
            $dirtyQuery = fsutil.exe dirty query "$($v.DriveLetter):"
            if ($dirtyQuery -match "is Dirty") {
                $outDrives.Add(("$($v.DriveLetter): (Dirty - REQUIRES REPAIR)") -join " ")
                $dirtyCount++
            } else {
                $outDrives.Add(("$($v.DriveLetter): (Clean)") -join " ")
            }
        } catch {
            $outDrives.Add(("$($v.DriveLetter): (Error querying)") -join " ")
        }
    }
    $dirtyStatus = if ($dirtyCount -eq 0) { "ALL NTFS DRIVES CLEAN" } else { "$dirtyCount DRIVES ARE DIRTY: " + ($outDrives -join " | ") }
    $dirtyColor = if ($dirtyCount -eq 0) { "Green" } else { "Red" }

    $report.Add([PSCustomObject]@{
        Setting = "NTFS Volume Dirty State"
        Status  = $dirtyStatus
        Color   = $dirtyColor
    })

    # 6. Physical Drive Health and Bus Connection
    $outDrivesHealth = [System.Collections.Generic.List[string]]::new()
    try {
        $disks = Get-PhysicalDisk
        foreach ($d in $disks) {
            $outDrivesHealth.Add(("[Disk {0}] {1} (Bus: {2}) -> Health: {3}, Status: {4}" -f $d.DeviceId, $d.FriendlyName, $d.BusType, $d.HealthStatus, $d.OperationalStatus))
        }
    } catch {}
    
    $report.Add([PSCustomObject]@{
        Setting = "Physical Disks Status"
        Status  = $outDrivesHealth -join " | "
        Color   = "Green"
    })

    return $report
}

# Run diagnostics and format output
$results = Get-ValidationStatus

Write-Host "`n========================================================" -ForegroundColor Cyan
Write-Host "         SYSTEM STABILITY SETTINGS VALIDATOR            " -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "Target Host: $env:COMPUTERNAME" -ForegroundColor Gray
Write-Host "Local Time:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n" -ForegroundColor Gray

foreach ($r in $results) {
    Write-Host ("{0,-32} : " -f $r.Setting) -NoNewline
    switch ($r.Color) {
        "Green"  { Write-Host $r.Status -ForegroundColor Green }
        "Red"    { Write-Host $r.Status -ForegroundColor Red -Bold }
        "Yellow" { Write-Host $r.Status -ForegroundColor Yellow }
        default  { Write-Host $r.Status }
    }
}
Write-Host "========================================================`n" -ForegroundColor Cyan
