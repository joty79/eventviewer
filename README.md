<p align="center">
  <img src="https://img.shields.io/badge/Platform-Windows-0078D6?style=for-the-badge&logo=windows&logoColor=white" alt="Platform">
  <img src="https://img.shields.io/badge/Language-PowerShell-5391FE?style=for-the-badge&logo=powershell&logoColor=white" alt="Language">
  <img src="https://img.shields.io/badge/License-MIT-green?style=for-the-badge" alt="License">
</p>

<h1 align="center">🔍 EventViewer Diagnostics Tool</h1>

<p align="center">
  <b>Ένα προηγμένο εργαλείο διάγνωσης σφαλμάτων συστήματος, WHEA crashes και volmgr failures</b><br>
  <sub>Διαδραστικό TUI & CLI εργαλείο για τοπικό και απομακρυσμένο έλεγχο μέσω WinRM.</sub>
</p>

---

## ✨ What's Inside

| # | Tool | Description |
|:-:|------|-------------|
| 🔍 | **[Analyze-EventViewer.ps1](#analyze-eventviewerps1)** | Κεντρικό script διάγνωσης και ανάλυσης σφαλμάτων. |

---

## 🔍 Analyze-EventViewer.ps1

> Διαγνωστικό εργαλείο που αναλύει τα Windows Event Logs για τον εντοπισμό αιτιών κατάρρευσης (BSOD), WHEA σφαλμάτων και προβλημάτων εγγραφής dump αρχείων.

### The Problem

- **Αποτυχία Εγγραφής Dump (volmgr 161):** Τα ξαφνικά κρασαρίσματα συχνά δεν αφήνουν minidumps επειδή ο δίσκος αποσυνδέεται κατά τη στιγμή του crash.
- **Outdated BIOS:** Μετά από αλλαγή μητρικής, η παλιά έκδοση BIOS προκαλεί αστάθεια στο TPM/PTT και PCIe Link States (WHEA 0x124).
- **Fast Startup (Hiberboot):** Προκαλεί κολλήματα κατά το login ή shutdown.

### The Solution

Το script αναλύει ταυτόχρονα το System Log, το `Microsoft-Windows-Kernel-WHEA/Operational` log, τη διαμόρφωση του Pagefile και την κατάσταση των δίσκων. Επίσης, αποκωδικοποιεί τα hex parameters του `volmgr` Event 161 (π.χ. `0xC00000A1` και `0xC00001AC`).

```
[Local/Remote PC] ──► WinRM / Local Query ──► Gather Event Logs ──► Decode volmgr Hex
                                                                     │
  Exports (report.md / CSV) ◄─── TUI Screen Viewer ◄─── Auto Diag ◄──┘
```

### Usage

**Από το Terminal (TUI Mode):**
*Εκτελέστε το script χωρίς παραμέτρους για να ανοίξει το διαδραστικό μενού.*

```powershell
# Εκκίνηση TUI
.\Analyze-EventViewer.ps1
```

**Από το Terminal (CLI Mode):**
*Εκτελέστε το script ορίζοντας ComputerName για CLI output και αυτόματη εξαγωγή.*

```powershell
# Διάγνωση απομακρυσμένου PC
.\Analyze-EventViewer.ps1 -ComputerName 192.168.1.47

# Διάγνωση με συγκεκριμένα credentials
.\Analyze-EventViewer.ps1 -ComputerName 192.168.1.47 -Credential $cred
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-ComputerName` | `string` | `$null` | Το όνομα ή η IP του απομακρυσμένου υπολογιστή. |
| `-Credential` | `PSCredential` | `$null` | Τα credentials σύνδεσης για το απομακρυσμένο PC. |
| `-Interactive` | `switch` | `$false` | Αναγκαστική εκκίνηση σε TUI Mode. |

---

## 📦 Installation

### Quick Setup

```powershell
# Μεταβείτε στο φάκελο του project
cd d:\Users\joty79\scripts\eventviewer

# Εκτελέστε το εργαλείο
.\Analyze-EventViewer.ps1
```

### Requirements

| Requirement | Details |
|-------------|---------|
| **OS** | Windows 10 / 11 |
| **Shell** | PowerShell 7.x (PS7) |
| **WinRM** | Ενεργοποιημένο στο remote PC για απομακρυσμένο έλεγχο. |
| **Helper** | `C:\Users\joty79\.agent-shared\templates\PS_UI_Blueprint.psm1` |

---

## 📁 Project Structure

```
eventviewer/
├── exports/                             # Φάκελος εξαγωγής αναφορών
├── Analyze-EventViewer.ps1              # Κεντρικό script διάγνωσης
├── OptiPlex_7060_1.32.0.exe             # BIOS Update (Λήφθηκε & Επαληθεύτηκε)
├── PROJECT_RULES.md                     # Κανόνες & Ιστορικό διαγνώσεων
├── CHANGELOG.md                         # Καταγραφή εκδόσεων
└── README.md                            # Αυτό το αρχείο
```

---

## 🧠 Technical Notes

<details>
<summary><b>Γιατί αποτυγχάνει η εγγραφή Dump (volmgr 161);</b></summary>

Όταν το σύστημα κρασάρει, χρησιμοποιείται ένας απλοποιημένος mini-driver (crash-dump driver) για την εγγραφή της μνήμης στο Pagefile. Αν ο δίσκος ή ο controller παρουσιάσει σφάλμα πρωτοκόλλου (status `0xC00000A1`) ή σφάλμα δεδομένων (status `0xC00001AC`), η εγγραφή αποτυγχάνει ακαριαία, αφήνοντας το Event 161 χωρίς να δημιουργηθεί minidump.

</details>

<details>
<summary><b>Πώς επηρεάζει το BIOS το TPM και τα κρασαρίσματα;</b></summary>

Μετά από αλλαγή μητρικής, οι ασυμβατότητες microcode της CPU με το BIOS και το firmware του TPM (PTT) προκαλούν PCIe Link State errors (WHEA 0x124) κατά το login ή shutdown. Η αναβάθμιση στην έκδοση 1.32.0 σταθεροποιεί τις τάσεις και τις καταστάσεις ενέργειας.

</details>

---

<p align="center">
  <sub>eventviewer · Diagnostics Tool · Run BIOS updates manually only</sub>
</p>
