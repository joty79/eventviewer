# System Diagnostics & Resolution Report: DESKTOP-CONSTRU

This report details the diagnostics, event log analysis, and system modifications performed on the remote machine **`DESKTOP-CONSTRU`** (IP: `192.168.1.108`) to resolve frequent system freezes (occurring 2–5 minutes post-login).

---

## 🔵 1. System Specifications
* **Computer Name:** DESKTOP-CONSTRU
* **Motherboard:** Dell Inc. 088DT1 (H81 Chipset, OptiPlex 3020 class)
* **Processor:** Intel(R) Core(TM) i7-4790 CPU @ 3.60GHz (Haswell, 4 cores / 8 threads)
* **RAM:** 1x 8GB DDR3 1600MHz (Reduced from 2 modules by user during diagnostics)
* **BIOS Version:** A10 (Dated 05/10/2018 - Older BIOS)
* **OS:** Windows 11 Pro (Version 10.0.26200 - Run on unsupported Haswell CPU)
* **Disk 0 (System SSD):** KIOXIA-EXCERIA SATA SSD (960GB class) -> Status: **Healthy** (0% Wear, SMART clean, ~34°C)

---

## 🔵 2. Problem Diagnosis (Symptom & Timeline)
* **Frequent System Freezes:**
  The remote machine was freezing completely within **2 to 5 minutes** of user interaction post-login.
* **Event Log History:**
  * Multiple repeating **`Kernel-Power Event ID 41`** (unexpected reboot) and **`EventLog Event ID 6008`** (unexpected shutdown) entries recorded today at:
    * 14:32, 14:45, 14:51, 14:56, 15:02, 15:10, 15:18 (remote system time).
  * **No BugCheck / Blue Screen (BSOD) code:** All events reported `BugcheckCode = 0`, meaning the OS locked up instantly before the kernel could execute a dump routine.
  * A past **`volmgr Event ID 161`** was recorded on 07/06/2026:
    * `Dump file creation failed due to error during dump creation. BugCheckProgress: 0x00040042` (indicates a storage protocol or PCIe link loss during crash).
* **Extreme CPU Load (Pre-Uninstall):**
  * Immediately post-boot, Bitdefender's **`bdservicehost`** was running two processes consuming **80% to 110% CPU** and over **760MB RAM** continuously.
* **Windows Update Service Conflict:**
  * Just before the freeze loop started today, a **`WindowsUpdateClient Event ID 20`** failed with error **`0xC1800109`** for a preview update (KB5092427), followed by service termination delay logs for `explorer.exe` and `wuauserv`.

---

## 🔵 3. Interventions Applied

### 🔧 1. Fast Startup Disabled
* Registry path modified remotely: `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power` -> Set `HiberbootEnabled = 0`.
* *Rationale:* Avoids partial hibernation state conflicts during shutdown on older H81/Dell motherboard firmware running Windows 11.

### 🔧 2. Windows Update Service Suspended
* Remote service `wuauserv` stopped successfully to prevent the update loop from causing background deadlocks.

### 🔧 3. Hardware / Memory Diagnostic
* User physically removed one RAM module (leaving 1x 8GB DDR3) to isolate dual-channel memory instability.

### 🔧 4. Antivirus Driver Removal
* User uninstalled Bitdefender to eliminate driver conflicts (`gzflt.sys` / `trufos.sys`) and remove the heavy CPU load (~110% CPU usage) at boot.

---

## 🔵 4. Current Status (Handoff & Next Steps)
* **Status:** The system has booted successfully with **1x 8GB RAM** and **no Bitdefender**.
* **Uptime:** Stable for **4+ minutes** post-boot. CPU utilization has returned to normal (no `bdservicehost` processes running).
* **Recommendations for Codex / Next Steps:**
  1. Monitor system stability for another 15 minutes.
  2. If the freeze does not reoccur:
     - The issue was likely due to either a **faulty RAM module** or **Bitdefender driver deadlock** under Windows 11 (Haswell compatibility).
     - Test the removed RAM module in a different slot or run memtest86.
     - Run `sfc /scannow` and `DISM` to repair any corrupt system files caused by the repeated hard lockups.
  3. If freezes resume:
     - Check for storage link loss (ASPM settings in BIOS or SATA power saving overrides in Windows).
     - Consider updating the BIOS from A10 to the latest available from Dell for the motherboard.

---

## 🔵 5. Codex Follow-up Diagnostics (2026-07-08)

### ✅ Remote Access / Baseline
* WinRM authenticated successfully with `DESKTOP-CONSTRU\dcadmin`.
* DeviceCheck quick snapshot completed against `192.168.1.108`:
  * `QuickMode = true`
  * `DeviceCount = 123`
  * Snapshot path: `D:\Users\joty79\scripts\DeviceCheck\.devicecheck-data\snapshots\DESKTOP-CONSTRU-5177c5c1350d4e7ad55aa705\latest.json`
* EventViewer diagnostic export completed:
  * `exports\report_DESKTOP-CONSTRU_2026-07-08_150632.md`
  * `exports\crashes_DESKTOP-CONSTRU_2026-07-08_150632.csv`
  * `exports\specs_DESKTOP-CONSTRU_2026-07-08_150632.csv`

### 🔧 Current Hardware State Observed
* Current RAM configuration reported by WMI:
  * Slot/device locator: `DIMM2`
  * Module: Micron `16KTF1G64AZ-1G6E1`
  * Serial: `15221016`
  * Capacity: 8 GB DDR3 1600
* User test context:
  * Previous run: reseated RAM, tested one module in first slot, freeze reproduced.
  * Current run: testing only the second module in the second slot.

### 🔍 Stability / Event Findings
* Six lightweight WinRM heartbeat samples over roughly 3 minutes all returned successfully.
* Uptime progressed from about 17.3 to 20.1 minutes during monitoring.
* CPU load stayed low/moderate in heartbeat samples (`4%` to `15%`).
* Memory commit stayed stable around `55.8%` to `57.1%`.
* `Kernel-Power 41` entries still show `BugcheckCode = 0`, matching hard freeze / forced reboot behavior rather than a normal BSOD.
* `Fast Startup` remains disabled.
* NTFS dirty check reported all NTFS volumes clean.
* SSD still reports healthy: KIOXIA SATA SSD, health `Healthy`, operational status `OK`, temperature about `34°C`, wear `0%`.
* No System-log WHEA hardware errors were found by the diagnostic script.

### 🟡 OCCT / CPU-Z Clarification
* OCCT and CPU-Z processes were still open, but the stress workload was stopped.
* A 5-second CPU delta check showed they were effectively idle:
  * `cpuz_x64`: `0.094` CPU seconds
  * `OCCTGUI`: `0.344` CPU seconds
  * combined: `0.438` CPU seconds over 5 seconds
  * processor load at the sample: `17%`

### 💡 Working Interpretation
* Current evidence does not prove the SSD is failing; SMART/storage counters look clean during live checks.
* The active test is now mainly isolating RAM module vs RAM slot vs board stability.
* If the current `DIMM2` / Micron module configuration remains stable, the earlier freeze with one module in the first slot increases suspicion on the first slot, the other module, seating/contact, or board memory-channel stability.
* If freezes continue even with this second module in `DIMM2`, broaden focus again to motherboard/BIOS/power/Windows 11 unsupported-platform instability rather than blaming one RAM stick.
