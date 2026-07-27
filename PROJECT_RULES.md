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
* **Hiberboot Verification Guardrail:** Το `HiberbootEnabled = 1` είναι registry preference και δεν αποδεικνύει μόνο του ενεργή hibernation/Fast Startup. Πριν από συμπέρασμα, κατέγραψε `powercfg /a`, ύπαρξη/μέγεθος `hiberfil.sys` και, όπου είναι δυνατό, before/after disk state.
* **Remediation Baseline Guardrail:** Πριν από registry ή BIOS remediation, κατέγραψε τις προηγούμενες τιμές. Η επαναγραφή υπάρχουσας τιμής, όπως `TdrDelay = 10`, δεν αποτελεί αλλαγή ούτε μπορεί να πιστωθεί ως fix.
* **BIOS Update Guardrail:** ΠΟΤΕ μην εκτελείτε αυτόματα αρχεία αναβάθμισης BIOS (π.χ. `OptiPlex_7060_1.32.0.exe`) μέσω scripts. Η αναβάθμιση BIOS πρέπει να γίνεται αποκλειστικά χειροκίνητα από τον χρήστη για λόγους ασφαλείας.

---

## 🔵 3. Ιστορικό Διαγνώσεων & Troubleshooting Memory
### 🔸 LogonUI Diagnostic Runtime Guardrails
* **Ημερομηνία:** 27 Ιουλίου 2026
* **Πρόβλημα:** Το νέο `Diagnose-LogonUIFreezes.ps1` είχε parser-valid αλλά runtime-invalid `Write-Host -Bold` calls και καλούσε methods ενός `CimInstance` σαν legacy WMI object.
* **Root cause:** Η αρχική υλοποίηση δεν είχε περάσει πραγματικό PowerShell 7 smoke test και μπέρδευε τα WMI method semantics με `Invoke-CimMethod`.
* **Κανόνας:** Κάλεσε `Win32_Tpm` methods μόνο μέσω `Invoke-CimMethod`, κράτησε null-safe event message previews, έλεγξε το πλήθος Event properties πριν από indexing και διατήρησε `-NoClear` για repeatable capture.
* **Files affected:** `Diagnose-LogonUIFreezes.ps1`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
* **Validation:** PowerShell parser, PSScriptAnalyzer review, non-admin smoke και elevated smoke μέσω direct `gsudo.exe`.

### 🔸 Bounded WinRM Discovery and Authentication
* **Ημερομηνία:** 27 Ιουλίου 2026
* **Πρόβλημα:** PCs με ανοικτό WinRM μπορούσαν να αφήσουν το diagnostic workflow να περιμένει αρκετά λεπτά πριν από generic failure.
* **Root cause:** Το discovery και το authenticated `New-PSSession` path ήταν ad hoc και χωρίς κοινό timeout/retry/status contract.
* **Κανόνας:** Χρησιμοποίησε τα pinned `WinRMDiscovery` και `WinRMConnection`. Δείξε κάθε bounded attempt, retry μόνο transient session-opening failures, stop άμεσα σε credentials/TrustedHosts/name/configuration, και μη ξανατρέχεις αυτόματα remote diagnostic script block.
* **Files affected:** `Analyze-EventViewer.ps1`, `.assets\WinRMDiscovery\*`, `.assets\WinRMConnection\*`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
* **Validation:** Parser, canonical/consumer hash verification, shared PS7/Windows PowerShell 5.1 offline suites και elevated authenticated localhost smoke πέρασαν. Το προηγούμενο customer PC δεν ήταν διαθέσιμο για live retest.

### 🔸 Prompt-Once DPAPI WinRM Credentials
* **Ημερομηνία:** 27 Ιουλίου 2026
* **Πρόβλημα:** Το EventViewer ζητούσε ξανά credentials σε κάθε remote diagnostic και tracked helper scripts κατασκεύαζαν ad hoc blank-password credentials.
* **Root cause:** Το vendored `WinRMConnection` ήταν στην έκδοση `1.0.0` και το consumer flow δεν χρησιμοποιούσε τα shared DPAPI profile APIs.
* **Κανόνας:** Δοκίμασε saved profile με hostname/IP aliases πριν από prompt. Κάνε save μόνο μετά από successful session open, αφαίρεσε profile μόνο για `AuthenticationRejected`, και μην αποθηκεύεις explicit `-Credential` ή `-BlankPassword` values.
* **Files affected:** `Analyze-EventViewer.ps1`, `internal\EventViewer\Connect-EventViewerTarget.ps1`, `tests\Test-Connect-EventViewerTarget.ps1`, tracked remote helpers, `.assets\WinRMConnection\*`, `README.md`, `CHANGELOG.md`, `PROJECT_RULES.md`.
* **Validation:** PowerShell parser, offline cached-profile rejection/replacement test, vendored hash verification και shared module suites. Το bounded live probe προς `192.168.1.47` σταμάτησε στο TCP preflight ως `TcpUnavailable`, πριν από authentication ή credential/profile change.
* **Validation guardrail:** Πριν από live smoke, πάρε τα πραγματικά parameter names από `Get-Command`; το public API χρησιμοποιεί `-TcpTimeoutMs` και `-OpenTimeoutMs`. Στην εγκατεστημένη έκδοση του PSScriptAnalyzer, κάλεσε `Invoke-ScriptAnalyzer -Path` ανά file και όχι με array.

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
* **Ημερομηνία:** 25-26 Ιουλίου 2026
* **Πρόβλημα:** Κατά το display wake επανήλθε μόνο μία από δύο οθόνες, η taskbar ήταν frozen και δεν ανταποκρίνονταν `Ctrl+Alt+Del`, DisplayPort ή USB reconnect. Ο χρήστης προκάλεσε το Kernel-Power 41 με forced shutdown. Στη συνέχεια το Normal Mode έδινε black screen, ενώ το σκόπιμο Safe Mode λειτουργούσε.
* **Root cause:** Δεν αποδείχθηκε. Το Safe Mode ➔ Normal Mode cycle είναι η πιθανότερη εξήγηση για την αποκατάσταση του black screen, με πιθανή αλλά μη αποδεδειγμένη συμβολή του `powercfg /h off`.
* **Evidence guardrails:**
  1. Το Event 41 επιβεβαιώνει το forced shutdown, όχι την αιτία του αρχικού freeze.
  2. Τα ιστορικά `nvlddmkm` Event 153 ήταν ασυμπτωματικά και δεν συνέπεσαν χρονικά με το incident.
  3. Το PSP Code 22 ήταν σκόπιμο disabled state και δεν αποδεικνύει C-state/idle root cause.
  4. Το `HiberbootEnabled = 1` δεν απέδειξε ενεργό `hiberfil.sys`.
  5. Τα `TdrDelay = 10` / `TdrDdiDelay = 10` προϋπήρχαν και απλώς ξαναγράφτηκαν.
* **Preventive configuration μετά την αποκατάσταση:**
  - PSP/fTPM απενεργοποιήθηκαν ξανά από τον χρήστη.
  - `Power Supply Idle Control`: `Auto` ➔ `Typical Current Idle`.
  - `Memory Context Restore = Enabled` και `Power Down Enable = Enabled`.
  - `Curve Optimizer = Negative 30` διατηρήθηκε, με Curve Shaper `Positive 5` μόνο στα `Min Frequency - Low/Med Temperature` bands και `Low Frequency - Low/Med Temperature = Disabled/0`.
* **Validation/monitoring:** Δεν έχει υπάρξει ακόμη νέο συγκρίσιμο incident. Αν επανέλθει, συλλογή live WinRM/display/input evidence πριν από forced shutdown.
* **Files affected:** `doc/DIAGNOSIS_NEOS.md`, `NEOS/DIAGNOSIS_NEOS.md`, `PROJECT_RULES.md`, `CHANGELOG.md`.
