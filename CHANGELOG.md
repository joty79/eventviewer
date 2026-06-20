# CHANGELOG - eventviewer

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
