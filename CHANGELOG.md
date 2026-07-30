# CHANGELOG - eventviewer

## [Unreleased]

### Changed
- Routed exact-target client `TrustedHosts` preparation through the pinned canonical `WinRMWorkshop` before credential lookup or authenticated session opening.
- Removed the EventViewer-specific WinRM service and `TrustedHosts` mutation helpers, including acceptance of legacy wildcard `*` as ready state.
- Routed network identity, LAN discovery, connection history and saved-target resolution through the canonical `WinRMDiscovery` public APIs.
- Removed the legacy repo-local subnet/TCP scanner and duplicate `history.json` runtime implementation.
- Split the project rules into a compact `AGENTS.md` router, a current `PROJECT_RULES.md` contract and a lossless searchable historical archive/index.
- Made the direct `Analyze-EventViewer.ps1` CLI the single Codex/Gemini automation path and added a canonical agent runbook.
- Retired stale hardcoded test/remediation helpers and the tool-specific Antigravity relay contract into a lossless, hash-indexed, non-executable archive.

### Security
- Explicit UI/CLI target selection now authorizes only a verified exact hostname/IP entry; wildcard and comma-list targets are rejected, and legacy `*` is narrowed to the selected target.

### Fixed
- Treated empty WinRM-deserialized dump-file objects as absent, preventing remote diagnostics without `MEMORY.DMP` or minidumps from failing on a missing `FullName` property.
- Preserved unavailable Fast Startup, disk, PnP and event-query evidence as `unknown/unavailable` instead of silently converting it to disabled, empty or healthy state.
- Reclassified PnP Code 22 as context-dependent disabled state, bounded `volmgr 161` to dump-failure evidence, and removed the hardcoded OptiPlex BIOS-version verdict from generic diagnostics.
- Made the focused LogonUI diagnostic distinguish failed/protected TPM, NGC and Event Log queries from clean results, and removed causal Fast Startup/Event 41 wording.

### Tests
- Added offline consumer coverage for idempotent preparation, preservation of existing entries, wildcard narrowing, invalid-target rejection, failure-before-connection on readback mismatch, and empty remote dump-object formatting.
- Added a focused ownership guard that rejects reintroduction of EventViewer-specific discovery/history implementations.
- Added an agent-contract guard for the single CLI entry point, retired paths, archive hashes and ad-hoc `New-PSSession` regressions.
- Expanded PowerShell 7/5.1 formatting tests for unknown query state, intentional Code 22, decoded versus undecoded `volmgr 161`, and removal of unsupported causal conclusions.
- Added a focused read-only/evidence contract test plus real non-admin and per-command elevated LogonUI diagnostic smoke coverage.
- Completed a read-only live smoke on `PALIOS` (`192.168.1.7`) with its local blank-password account: discovery, exact-target elevated `TrustedHosts` readback, first-attempt authentication, full CLI diagnostics/export, canonical history resolution and bounded PTY open/exit all passed.

## [1.6.0] - 2026-07-27

### Added
- Added prompt-once DPAPI credential profiles for EventViewer WinRM targets, keyed by both hostname and IP aliases.
- Added explicit `-UserName` and `-BlankPassword` CLI parameters and an offline stale-credential replacement test.

### Changed
- Updated the pinned `WinRMConnection` runtime from `1.0.0` to `1.1.0`.
- Routed the main diagnostics and tracked remote helper scripts through the shared EventViewer connection adapter instead of constructing credentials ad hoc.

### Fixed
- Removed unsupported `Write-Host -Bold` arguments from the CLI report and diagnostics verifier paths.

### Security
- New prompted credentials are saved only after successful authenticated session opening.
- A saved profile is removed only after an `AuthenticationRejected` result; TCP, timeout, and transport failures preserve it.
- Explicit `-Credential` and `-BlankPassword` values are never persisted automatically.

## [1.5.1] - 2026-07-27

### Fixed
- Removed invalid `Write-Host -Bold` arguments from `Diagnose-LogonUIFreezes.ps1`.
- Invoked `Win32_Tpm` CIM methods through `Invoke-CimMethod` and made event collection/message previews scalar- and null-safe.
- Added `-NoClear` for repeatable smoke captures and guarded Kernel-Power property indexing.

### Documentation
- Documented the LogonUI/MSA diagnostic workflow and its read-only/elevation boundaries in `README.md`.

## [1.5.0] - 2026-07-27

### Changed
- Routed `Ctrl+L` discovery through the pinned shared `WinRMDiscovery` module and authenticated session opening through `WinRMConnection`.
- Added TCP preflight, three bounded connection attempts, visible retry status, transient-only retry, and categorized failure reporting instead of an unbounded silent wait.

### Tests
- Passed parser validation, vendored hash verification, the shared PS7/Windows PowerShell 5.1 offline suites, and an elevated authenticated localhost smoke.

## [1.4.0] - 2026-07-25
### Added
- **PnP Hardware Device Error Detection:** Integrated `Win32_PnPEntity` queries for `ConfigManagerErrorCode != 0` to flag disabled/failing devices (e.g. AMD PSP 11.0 / Code 22 fTPM errors and Code 31 driver loading failures).
- **Dynamic Memory Dump Path Resolution:** Updated `Analyze-EventViewer.ps1` to resolve `$crashControl.DumpFile` and `$crashControl.MinidumpDir` from CrashControl registry keys instead of hardcoding `C:\Windows\Minidump`.
- **Event ID 41 XML Parameter Decoding:** Added XML payload parsing to distinguish BSOD BugCheck codes from physical Power Button forced hard-reboots (`BugcheckCode = 0`, `PowerButtonTimestamp > 0`).
- **SafeBoot Environment Reporting:** Added `SafeBootStatus` inspection to flag whether a target PC is booted in Safe Mode (Minimal or With Networking) vs Normal Boot.

### Changed
- **NEOS Incident Report Correction:** Rewrote both `doc/DIAGNOSIS_NEOS.md` and `NEOS/DIAGNOSIS_NEOS.md` with the exact dual-monitor display-wake freeze timeline and separated the user-induced Event 41 from the original failure.
- **Recovery vs Prevention:** Documented that the Normal Mode black screen was most likely cleared by the Safe Mode cycle, with hibernation reset remaining possible but unproven. BIOS and Curve Shaper changes occurred afterward as prevention.
- **Evidence Corrections:** Recorded that PSP Code 22 was intentional, historical `nvlddmkm` Event 153 entries were symptomless and unrelated in time, hibernation was not proven by `HiberbootEnabled` alone, and the TDR values already existed at decimal `10`.
- **Preventive BIOS/CPU Configuration:** Recorded `Typical Current Idle`, `Memory Context Restore + Power Down Enable`, retained `CO -30`, and Curve Shaper `Positive 5` at the minimum-frequency low/medium-temperature bands.

## [1.3.0] - 2026-07-09

### Added
- **Διαγνωστικό Script LogonUI Freezes (`Diagnose-LogonUIFreezes.ps1`):**
  - Δημιουργία ολοκληρωμένου διαγνωστικού script PowerShell 7 για τον εντοπισμό τυχαίων παγωμάτων στην οθόνη Logon (LogonUI.exe) και προβλημάτων σύνδεσης με Microsoft Account (MSA).
  - TPM & Hardware Security Verification (Get-Tpm, Win32_Tpm CIM checks, System/TPM logs scan).
  - NGC Folder & Windows Hello Integrity verification (Permissions, non-destructive file modification scan).
  - Authentication & Token Broker Logging extraction (User Device Registration, AAD Operational, Application logs).
  - System Configuration Audit (Registry HiberbootEnabled check, 5 last unexpected/dirty shutdowns).
  - Πλήρως συμβατό με PowerShell 7 και με μορφοποιημένη έξοδο για το Windows Terminal.

## [1.2.0] - 2026-06-30
### Added
- **Διάγνωση & Επισκευή DESKTOP-8LCO8S2 (192.168.1.68):** 
  - Εντοπισμός dirty flags στα partitions του εξωτερικού USB δίσκου (`WDC WD50 00LPCX-24C6HT0`) που προκαλούσαν σφάλματα NTFS Event ID 98 και boot-loops/hangs.
  - Επιτυχής εκτέλεση `Repair-Volume` σε 3 προβληματικούς τόμους.
  - Απενεργοποίηση του USB Selective Suspend μέσω Registry (`DisableSelectiveSuspend = 1` για `USBHUB3` & `usbhub` parameters).
  - Απενεργοποίηση του Fast Startup (`HiberbootEnabled = 0`) για την αποτροπή μελλοντικού NTFS corruption.
  - Δημιουργία αναλυτικής αναφοράς `DIAGNOSIS_DESKTOP-8LCO8S2.md` στο root του αποθετηρίου για κοινή χρήση με Codex.
  - Δημιουργία του verifier script `Verify-DiagnosticsFixes.ps1` για τον εύκολο έλεγχο όλων των ρυθμίσεων σταθερότητας δίσκων/USB.

## [1.1.2] - 2026-06-21
### Fixed
- **Διόρθωση σφάλματος εκκίνησης TUI:** Διορθώθηκε το στιγμιαίο σφάλμα (red flash) κατά την εκκίνηση του TUI, αντικαθιστώντας το λανθασμένο όνομα συνάρτησης `Init-TuiHost` με το σωστό `Initialize-TuiHost`.

## [1.1.1] - 2026-06-21
### Fixed
- **Διόρθωση σφάλματος Color binding:** Διορθώθηκε το σφάλμα `Cannot bind argument to parameter 'Color' because it is an empty string` στο TUI αντικαθιστώντας το μη υπαρκτό `$_C.Cyan` με το `$_C.Info`.

## [1.1.0] - 2026-06-19
### Added
- **Οργάνωση Documentation:** Δημιουργία φακέλου `doc/` και μεταφορά των αρχείων αναφοράς συστήματος (`MySystemInformation.xml`) και απομακρυσμένων διαγνωστικών.
- **Αποκλεισμός Windows Update Drivers:** Προσθήκη πολιτικής registry `ExcludeWUDriversInQualityUpdate = 1` στο remote PC για την αποτροπή αντικατάστασης του storage driver.
- **Καθαρισμός Intel RST:** Απεγκατάσταση των `oem39.inf`/`oem48.inf` (Intel RST) από το Driver Store του remote PC και απενεργοποίηση της υπηρεσίας `RstMwService`.

## [1.0.0] - 2026-06-19
### Added
- **Αρχική Έκδοση:** Δημιουργία του διαγνωστικού εργαλείου `Analyze-EventViewer.ps1`.
- **Υποστήριξη TUI Mode:** Διαδραστικό μενού βασισμένο στο `PS_UI_Blueprint.psm1` με υποστήριξη scrolling, resizing και key shortcuts.
- **Υποστήριξη CLI Mode:** Εκτέλεση από κονσόλα με παραμέτρους `-ComputerName` και `-Credential`.
- **Αποκωδικοποίηση volmgr 161:** Ανάλυση σφαλμάτων εγγραφής dump αρχείων (`0xC00000A1` και `0xC00001AC`).
- **WHEA Diagnostics:** Έλεγχος των operational logs και system event log για WHEA/Hardware warnings & errors.
- **Fast Startup Quick Action:** Δυνατότητα απενεργοποίησης του Fast Startup τοπικά ή απομακρυσμένα μέσω του TUI (`F` key).
- **Exports:** Εξαγωγή αναφοράς διάγνωσης σε Markdown (`report_*.md`) και CSV (`crashes_*.csv`, `specs_*.csv`) πατώντας το `E` στο TUI.
- **Connection History:** Αποθήκευση ιστορικού συνδέσεων ανά δίκτυο (Network ID) στο `history.json`.
- **BIOS Update File:** Λήψη και επαλήθευση (MD5 match) του επίσημου αρχείου `OptiPlex_7060_1.32.0.exe` για χειροκίνητη εγκατάσταση από τον χρήστη.
