# CHANGELOG - eventviewer

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
