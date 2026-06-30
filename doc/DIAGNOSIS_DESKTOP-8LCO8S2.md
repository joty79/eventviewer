# System Diagnostics & Resolution Report: DESKTOP-8LCO8S2

This report documents the diagnosis and software modifications performed on the remote machine **`DESKTOP-8LCO8S2`** (IP: `192.168.1.68`) to resolve boot-looping/hanging issues related to disk errors.

---

## 🔵 1. System Context & Specifications
* **Motherboard:** MSI B85M-G43 (MS-7823)
* **BIOS Version:** V3.5 (Dated 12/03/2013 - Outdated)
* **OS:** Windows 11 Pro (Version 10.0.26200 - Run on unsupported CPU Haswell Pentium G3220)
* **Disk 0 (System SSD):** ADATA SU650 (240GB - GPT) -> Status: **Healthy** (0% Wear, SMART clean)
* **Disk 1 (External USB HDD):** WDC WD5000LPCX-24C6HT0 (500GB - GPT) -> Connected via USB enclosure

---

## 🔵 2. Problem Diagnosis (Root Cause)
* **Boot Delay/Hang Symptom:** 
  During boot, Windows regularly executed a disk check screen: `Scanning and repairing drive (E:)` or similar volume paths. If I/O errors occurred on the drive, the boot process would freeze completely, leading to hard restarts (recorded as `Kernel-Power ID 41` with `BugcheckCode 0`).
* **Repeating NTFS Errors:** 
  Analysis of the System Event log revealed repeating **`NTFS Event ID 98`** errors at every startup (15-20 seconds post-boot) for these three volumes on the USB drive:
  1. `E:` (HarddiskVolume9, partition 5, labeled `425gbNik` - dynamic disk registry signature `DMIO:ID:`)
  2. `WINRE_DRV` (HarddiskVolume5, partition 1)
  3. `PBR_DRV` (HarddiskVolume11, partition 7, ~13GB OEM recovery)
* **Dirty Bit Status:** 
  `fsutil dirty query` confirmed that all three volumes were marked as **Dirty** (likely due to previous unsafe USB removals or power cuts).

---

## 🔵 3. Resolution Actions Applied

### 🔧 1. NTFS File System Repairs
* Mounted the hidden volumes (`Volume5` and `Volume11`) to temporary letters (`X:` and `Y:`).
* Executed remote repair commands:
  ```powershell
  Repair-Volume -DriveLetter E -OfflineScanAndFix
  Repair-Volume -DriveLetter X -OfflineScanAndFix
  Repair-Volume -DriveLetter Y -OfflineScanAndFix
  ```
* **Verification:** Verified all three partitions now report `Volume is NOT Dirty` (Clean). Unmounted `X:` and `Y:`.

### 🔧 2. USB Selective Suspend Disabled (System-wide)
* To prevent USB drives from dropping connection during idle states (which causes NTFS dirty flags), selective suspend was deactivated at the driver level:
  * Registry path: `HKLM\SYSTEM\CurrentControlSet\Services\USBHUB3\Parameters` -> Set `DisableSelectiveSuspend = 1` (DWORD)
  * Registry path: `HKLM\SYSTEM\CurrentControlSet\Services\usbhub\Parameters` -> Set `DisableSelectiveSuspend = 1` (DWORD)

### 🔧 3. Fast Startup Disabled
* Registry path: `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power` -> Set `HiberbootEnabled = 0` (DWORD)
* **Verification:** `powercfg /a` confirms Fast Startup is disabled by system policy. This prevents metadata locking on external volumes during shutdown.

### 🔧 4. Hibernate State
* Verified Hibernate is inactive (`hiberfil.sys` does not exist on `C:\`).

---

## 🔵 4. Handoff & Recommendations for Codex / Next Steps
1. **User Action:** The user has been advised to change the USB selective suspend setting to "Disabled" inside the Windows Power Plan UI (Balanced settings) to mirror the registry changes.
2. **Physical Issues:** Since the drive SMART status is Healthy, if corruption occurs again, focus on:
   - Ensuring the user uses "Safe Hardware Removal" before unplugging the drive.
   - Replacing the USB cable or enclosure.
   - Moving the USB connection to the motherboard's rear USB ports.
3. **No further software configurations are needed.**

---

## 🔵 5. Codex Verification - 2026-06-30

### ✅ Τρέχουσα κατάσταση
* WinRM verified προς `192.168.1.68` ως `DESKTOP-8LCO8S2\user` με admin rights.
* Το remote boot που ελέγχθηκε ήταν στις **2026-06-30 14:08:41**.
* `Verify-DiagnosticsFixes.ps1` εκτελέστηκε μέσω WinRM στο remote target και επέστρεψε:
  * Fast Startup: **DISABLED**
  * USB Selective Suspend driver overrides: **DISABLED / healthy**
  * Hibernate: **DISABLED**
  * NTFS dirty state: **ALL NTFS DRIVES CLEAN**
  * Physical disks: `ADATA SU650` και `WDC WD5000LPCX-24C6HT0` **Healthy / OK**
* Read-only `Repair-Volume -Scan` επέστρεψε `NoErrorsFound` για `C:`, `E:`, `F:`, `WINRE_DRV`, `PBR_DRV` και το local recovery volume.

### 🔧 Event Log συμπέρασμα
* Τα παλιά επαναλαμβανόμενα `NTFS Event ID 98` errors αφορούσαν τα USB HDD volumes:
  * `E:` / `HarddiskVolume9`
  * `WINRE_DRV` / `HarddiskVolume5`
  * `PBR_DRV` / `HarddiskVolume11`
* Το τελευταίο boot στις **2026-06-30 14:08-14:09** δείχνει πλέον `NTFS Event ID 98` ως πληροφοριακό health check: οι τόμοι είναι σε καλή κατάσταση και δεν απαιτείται ενέργεια.
* Δεν βρέθηκαν `volmgr Event ID 161`, `BugCheck 1001`, WHEA hardware errors, disk bad block events, ή storage controller reset events στο ελεγμένο παράθυρο.
* Υπάρχουν `Kernel-Power Event ID 41` / `EventLog 6008` για μη αναμενόμενα shutdowns, με `BugcheckCode = 0`, στις:
  * 2026-06-30 13:11:12
  * 2026-06-16 13:06:52
  * 2026-06-10 13:16:15
  Αυτό δείχνει hard reset/power loss/hang, όχι recorded BSOD.

### ⚠️ Παραμένει ύποπτο
* Το βασικό root cause παραμένει ο εξωτερικός USB HDD ή η USB σύνδεσή του, όχι ο system SSD.
* Το active power plan έχει USB selective suspend **AC = disabled** και **DC = enabled**. Για desktop αυτό συνήθως δεν επηρεάζει plugged-in χρήση, ενώ τα driver overrides είναι ήδη disabled. Αν επανεμφανιστεί το πρόβλημα, κλείσε και το DC setting ή άλλαξε το από Power Plan UI.
* Υπάρχει ένα `Unknown USB Device (Device Descriptor Request Failed)` στο device list. Αν εμφανιστούν ξανά dirty volumes ή boot repair, δοκίμασε άλλο USB cable/enclosure και rear motherboard USB port.

### ✅ Τελική εκτίμηση
Η Gemini διάγνωση επιβεβαιώνεται. Μετά τα repairs και τα power/USB changes, η τρέχουσα κατάσταση είναι καθαρή. Δεν προτείνεται άλλο software fix τώρα. Αν το boot error εμφανιστεί ξανά, προτεραιότητα έχει physical USB path: cable, enclosure, port, και safe removal.
