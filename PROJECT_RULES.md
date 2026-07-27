# PROJECT_RULES.md - eventviewer

## 🔵 1. Σκοπός και Πεδίο Εφαρμογής
🔸 Αυτό το αποθετήριο περιέχει το εργαλείο **`Analyze-EventViewer.ps1`** για τη διάγνωση και ανάλυση σφαλμάτων συστήματος, WHEA crashes και volmgr failures (Event ID 161) σε τοπικούς και απομακρυσμένους υπολογιστές.

---

## 🔵 2. Τεχνικές Προδιαγραφές & Κανόνες
* **WinRM Remote Connection:** Σύνδεση με απομακρυσμένα συστήματα μέσω WinRM (παραμετροποίηση TrustedHosts αν απαιτείται). Υποστήριξη λογαριασμών με κενό κωδικό πρόσβασης (π.χ. `cbx_t` στο remote PC).
* **Shared WinRM Runtime:** Το `Ctrl+L` discovery ανήκει στο pinned `.assets\WinRMDiscovery`, ενώ κάθε authenticated session ανοίγει μέσω pinned `.assets\WinRMConnection`. Το open TCP 5985 δεν ισοδυναμεί με επιτυχημένο authentication.
* **TUI Mode:** Διαδραστική διεπαφή με χρήση του `PS_UI_Blueprint.psm1` και υποστήριξη της συντόμευσης `Ctrl+L` για LAN scan (θύρα 5985).
* **Exports:** Εξαγωγή αναφορών σε Markdown και CSV στο φάκελο `exports/` πατώντας το πλήκτρο `E` στο TUI.
* **Hiberboot (Fast Startup):** Υποστήριξη Quick Action στο TUI (`F` key) για απενεργοποίηση του Fast Startup locally (μέσω `gsudo`) ή remotely (μέσω της WinRM PSSession).
* **BIOS Update Guardrail:** ΠΟΤΕ μην εκτελείτε αυτόματα αρχεία αναβάθμισης BIOS (π.χ. `OptiPlex_7060_1.32.0.exe`) μέσω scripts. Η αναβάθμιση BIOS πρέπει να γίνεται αποκλειστικά χειροκίνητα από τον χρήστη για λόγους ασφαλείας.

---

## 🔵 3. Ιστορικό Διαγνώσεων & Troubleshooting Memory
### 🔸 Bounded WinRM Discovery and Authentication
* **Ημερομηνία:** 27 Ιουλίου 2026
* **Πρόβλημα:** PCs με ανοικτό WinRM μπορούσαν να αφήσουν το diagnostic workflow να περιμένει αρκετά λεπτά πριν από generic failure.
* **Root cause:** Το discovery και το authenticated `New-PSSession` path ήταν ad hoc και χωρίς κοινό timeout/retry/status contract.
* **Κανόνας:** Χρησιμοποίησε τα pinned `WinRMDiscovery` και `WinRMConnection`. Δείξε κάθε bounded attempt, retry μόνο transient session-opening failures, stop άμεσα σε credentials/TrustedHosts/name/configuration, και μη ξανατρέχεις αυτόματα remote diagnostic script block.
* **Files affected:** `Analyze-EventViewer.ps1`, `.assets\WinRMDiscovery\*`, `.assets\WinRMConnection\*`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
* **Validation:** Parser, canonical/consumer hash verification, shared PS7/Windows PowerShell 5.1 offline suites και elevated authenticated localhost smoke πέρασαν. Το προηγούμενο customer PC δεν ήταν διαθέσιμο για live retest.

### 🔸 PowerShell Inspection Parser Guardrail
* **Ημερομηνία:** 8 Ιουλίου 2026
* **Πρόβλημα:** Σε ad hoc inspection command ξαναχρησιμοποιήθηκε `} | Format-List` αμέσως μετά από `foreach` statement και έδωσε `An empty pipe element is not allowed`.
* **Root cause:** Τα PowerShell statements όπως `foreach (...) { ... }` δεν πρέπει να γίνονται pipe έτσι σαν expression.
* **Κανόνας:** Για inspection commands, πρώτα ανάθεση (`$items = foreach (...) { ... }`) και μετά pipe (`$items | Format-List`). Αυτό κρατάει τα diagnostics γρήγορα και parser-safe.

### 🔸 DESKTOP-CONSTRU RAM/Slot Isolation Snapshot
* **Ημερομηνία:** 8 Ιουλίου 2026
* **Πρόβλημα:** Το `DESKTOP-CONSTRU` πάγωνε σε 2-5 λεπτά μετά το login, με repeated `Kernel-Power 41` / `BugcheckCode = 0` και χωρίς καθαρό BSOD dump.
* **Root cause υπό διερεύνηση:** Δεν έχει αποδειχθεί ακόμη. Το SSD δείχνει healthy στα live checks, Bitdefender αφαιρέθηκε, Fast Startup είναι disabled, και τώρα απομονώνεται RAM module/slot.
* **Κανόνας:** Μην υπερεστιάζεις μόνο στο RAM χωρίς evidence, αλλά κράτα ξεκάθαρο test matrix. Γνωστό: ένα module στο πρώτο slot πάγωσε ξανά. Τρέχον test: μόνο το δεύτερο module στο `DIMM2`, Micron `16KTF1G64AZ-1G6E1`, serial `15221016`, 8 GB DDR3 1600.
* **Validation:** WinRM/DeviceCheck/EventViewer diagnostics πέρασαν μετά τη διακοπή του stress workload. Έξι ελαφριά heartbeat samples επέστρεψαν OK από περίπου 17.3 έως 20.1 λεπτά uptime. OCCT/CPU-Z παρέμεναν open αλλά idle, όχι active stress.

### 🔸 Διάγνωση στο Remote PC 192.168.1.47 (Dell OptiPlex 7060)
* **Ημερομηνία:** 19 Ιουνίου 2026
* **Πρόβλημα:** Ξαφνικά κρασαρίσματα (BSOD/Freezes) κατά το login ή τη διάρκεια λειτουργίας μετά από αντικατάσταση μητρικής.
* **Βασικά Ευρήματα:**
  1. **volmgr Event ID 161:** Αποτυχία εγγραφής dump αρχείου λόγω σφαλμάτων **`0xC00000A1`** (STATUS_DEVICE_PROTOCOL_ERROR) και **`0xC00001AC`** (STATUS_DEVICE_DATA_ERROR). Αυτό σημαίνει ότι ο SSD ή ο storage controller αποσυνδέεται ακαριαία κατά τη διάρκεια του κρασαρίσματος.
  2. **BIOS Outdated:** Η νέα μητρική τρέχει την έκδοση BIOS **1.24.0 (2022)**. Η τελευταία έκδοση είναι η **1.32.0 (2024)**. Οι παλαιότερες εκδόσεις έχουν γνωστά θέματα με τη σταθερότητα του TPM (PTT) και τη διαχείριση ενέργειας του PCIe (ASPM).
  3. **Fast Startup:** Ήταν ενεργοποιημένο (HiberbootEnabled = 1).
* **Προτεινόμενες Ενέργειες:**
  - Χειροκίνητη εγκατάσταση του BIOS Update `1.32.0` (το αρχείο λήφθηκε και επαληθεύτηκε στο `d:\Users\joty79\scripts\eventviewer\OptiPlex_7060_1.32.0.exe`).
  - Απενεργοποίηση του Fast Startup (HiberbootEnabled = 0).

### 🔸 Διάγνωση στο PC NEOS / 192.168.1.6 (AMD Ryzen 7 9700X / MSI X870 Tomahawk)
* **Ημερομηνία:** 25 Ιουλίου 2026
* **Πρόβλημα:** Πάγωμα υπολογιστή (Hard Freeze) κατά την επιστροφή του χρήστη (idle status), χωρίς παραγωγή BSOD dump file.
* **Βασικά Ευρήματα:**
  1. **AMD PSP 11.0 Device Error (Code 22):** Η συσκευή AMD PSP (Platform Security Processor / fTPM) ήταν απενεργοποιημένη στο Device Manager / BIOS. Στους επεξεργαστές AMD Ryzen, η απουσία ή απενεργοποίηση του AMD PSP προκαλεί ολικό πάγωμα κατά τις μεταβάσεις χαμηλής ισχύος (Idle/Sleep C-States).
  2. **Kernel-Power Event ID 41 (`BugcheckCode = 0`, `PowerButtonTimestamp > 0`):** Επιβεβαιώθηκε ότι ο χρήστης αναγκάστηκε να πατήσει παρατεταμένα το Power Button για hard restart.
  3. **Fast Startup:** Ήταν ενεργοποιημένο (HiberbootEnabled = 1).
* **Ενέργειες & Βελτιώσεις:**
  - Ενεργοποίηση/Επανεγκατάσταση του AMD Chipset Driver (AMD PSP 11.0 Device) και απενεργοποίηση Fast Startup.
  - Αναβάθμιση του `Analyze-EventViewer.ps1` με αυτόματο εντοπισμό PnP Device Errors (Code 22/31), dynamic dump path resolution (`D:\Temp\CrashDumps`), και XML parsing του Kernel-Power 41.

