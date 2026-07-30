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
| 🔐 | **[Diagnose-LogonUIFreezes.ps1](#diagnose-logonuifreezesps1)** | Read-only έλεγχος TPM, Windows Hello, authentication logs και unexpected shutdowns. |

---

## 🔍 Analyze-EventViewer.ps1

> Διαγνωστικό εργαλείο που αναλύει τα Windows Event Logs για τον εντοπισμό αιτιών κατάρρευσης (BSOD), WHEA σφαλμάτων και προβλημάτων εγγραφής dump αρχείων.

### The Problem

- **Αποτυχία Εγγραφής Dump (volmgr 161):** Το event αποδεικνύει ότι απέτυχε η δημιουργία dump. Μόνο συγκεκριμένα decoded status codes και χρονικά συσχετισμένα storage events μπορούν να στηρίξουν υπόθεση storage I/O failure.
- **BIOS context:** Η έκδοση BIOS είναι χρήσιμο evidence, αλλά δεν αποδεικνύει από μόνη της TPM/PTT, PCIe ή WHEA root cause. Η current έκδοση ελέγχεται στο επίσημο support page του ακριβούς μοντέλου.
- **Fast Startup (Hiberboot):** Η registry preference είναι ένα στοιχείο του power-state investigation, όχι από μόνη της απόδειξη ότι το τελευταίο boot χρησιμοποίησε Fast Startup ή ότι αυτό προκάλεσε το incident.

### The Solution

Το script αναλύει ταυτόχρονα το System Log, το `Microsoft-Windows-Kernel-WHEA/Operational` log, τη διαμόρφωση του Pagefile και την κατάσταση των δίσκων. Επίσης, αποκωδικοποιεί τα hex parameters του `volmgr` Event 161 (π.χ. `0xC00000A1` και `0xC00001AC`) και διαχωρίζει το απλό dump failure από ισχυρότερο decoded storage-path evidence.

Το `Ctrl+L` discovery και το network-scoped connection history χρησιμοποιούν το pinned shared `WinRMDiscovery`. Τα saved targets επιλύονται ξανά με hostname/MAC/last-IP evidence πριν από σύνδεση, ώστε ένα παλιό IP να μη θεωρείται αυτόματα το ίδιο PC. Μετά την explicit επιλογή στόχου, το pinned `WinRMWorkshop` προσθέτει και επαληθεύει μόνο το exact hostname/IP στο client `TrustedHosts`, χωρίς δεύτερο prompt. Το authenticated session opening ανήκει στο pinned `WinRMConnection`: TCP preflight, έως τρεις bounded προσπάθειες με άμεσο status, transient-only retry και σαφή κατηγορία αποτυχίας. Μετά την πρώτη επιτυχημένη σύνδεση, το credential αποθηκεύεται ως Windows DPAPI profile για τον ίδιο Windows user και installation.

Αυτό είναι convenience-oriented profile για ελεγχόμενο workshop LAN, όχι enterprise-secure default για public/shared/untrusted networks. Σε workgroup/IP connections το WinRM HTTP/NTLM δημιουργεί encrypted session μετά το authentication, αλλά δεν παρέχει certificate-backed server identity. Blank-password, Private-network, firewall και remote-UAC ρυθμίσεις ανήκουν στο explicit target-side setup/restore workflow, όχι στο EventViewer.

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
.\Analyze-EventViewer.ps1 -ComputerName 192.168.1.47 -UserName 'TARGET\user'

# Διάγνωση με συγκεκριμένα credentials
.\Analyze-EventViewer.ps1 -ComputerName 192.168.1.47 -Credential $cred

# Ρητά γνωστό local account με κενό password (δεν αποθηκεύεται profile)
.\Analyze-EventViewer.ps1 -ComputerName 192.168.1.47 -UserName 'cbx_t' -BlankPassword
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-ComputerName` | `string` | `$null` | Το όνομα ή η IP του απομακρυσμένου υπολογιστή. |
| `-Credential` | `PSCredential` | `$null` | Τα credentials σύνδεσης για το απομακρυσμένο PC. |
| `-UserName` | `string` | `Administrator` | Προτεινόμενο username όταν δεν υπάρχει saved DPAPI profile. |
| `-BlankPassword` | `switch` | `$false` | Χρήση ρητά γνωστού blank-password local account χωρίς αποθήκευση profile. |
| `-Interactive` | `switch` | `$false` | Αναγκαστική εκκίνηση σε TUI Mode. |

### Agent / Automation Usage

Codex, Gemini και automation χρησιμοποιούν απευθείας το CLI του
`Analyze-EventViewer.ps1` — δεν υπάρχει δεύτερο remote wrapper με αποθηκευμένο
target ή account. Το canonical execution και verification contract βρίσκεται
στο [docs/AGENT_RUNBOOK.md](docs/AGENT_RUNBOOK.md).

Τα scripts κάτω από `docs/history/retired-agent-assets/` είναι ιστορικό evidence
και δεν πρέπει να εκτελούνται. Τα ignored `scratch*` αρχεία είναι προσωπικά
experiments και όχι supported project entry points.

---

## 🔐 Diagnose-LogonUIFreezes.ps1

> Read-only diagnostic για τυχαία LogonUI/MSA freezes και προβλήματα Windows Hello.

### The Problem

- Τα LogonUI freezes συχνά δεν αφήνουν crash dump.
- TPM, Windows Hello, WAM/AAD και shutdown evidence βρίσκονται σε διαφορετικά logs και namespaces.
- Non-admin execution μπορεί να δώσει ελλιπές αποτέλεσμα χωρίς να είναι σαφές ποιο evidence λείπει.

### The Solution

Το script συγκεντρώνει TPM/CIM state, NGC metadata, authentication-related events, Fast Startup preference και τα τελευταία Kernel-Power 41/EventLog 6008 records. Δεν αλλάζει Registry, TPM, NGC ή Windows Hello configuration.

```text
[Local PC] -> TPM/NGC checks -> Authentication logs -> Shutdown evidence -> Console report
```

### Usage

```powershell
# Πλήρης read-only διάγνωση
.\Diagnose-LogonUIFreezes.ps1

# Χωρίς Clear-Host, κατάλληλο για capture και smoke testing
.\Diagnose-LogonUIFreezes.ps1 -NoClear

# Automation: exit 2 αν ένα ή περισσότερα checks είναι unavailable
pwsh.exe -NoProfile -File .\Diagnose-LogonUIFreezes.ps1 -NoClear -FailOnUnavailable
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-NoClear` | `switch` | `$false` | Διατηρεί το υπάρχον terminal output. |
| `-FailOnUnavailable` | `switch` | `$false` | Για ξεχωριστό automation process: επιστρέφει exit code `2` όταν το scan ολοκληρώθηκε με partial query coverage. Τα diagnostic findings δεν θεωρούνται execution failure. |

Για πληρέστερη πρόσβαση στα System logs και στο protected NGC folder χρησιμοποίησε per-command elevation, π.χ. `gsudo.exe pwsh -NoProfile -File .\Diagnose-LogonUIFreezes.ps1 -NoClear`.

Το elevated run βελτιώνει την πρόσβαση, αλλά δεν εγγυάται ότι κάθε protected
NGC subfolder ή optional Event Log υπάρχει/διαβάζεται. Το τελικό
`full query coverage` ή `partial query coverage` είναι το canonical completion
status. `Access denied`, missing log και query failure εμφανίζονται ως
`unavailable`· δεν μετατρέπονται σε «δεν βρέθηκε πρόβλημα». Οι TPM/Hello events,
το `HiberbootEnabled` και το Event 41 είναι evidence προς συσχέτιση, όχι αυτόματο
root-cause verdict.

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
├── AGENTS.md                            # Compact project router για agents
├── .assets/
│   ├── WinRMConnection/                 # Pinned shared authenticated WinRM connector
│   ├── WinRMDiscovery/                  # Pinned shared LAN PC discovery module
│   └── WinRMWorkshop/                   # Pinned exact-target TrustedHosts preparation
├── docs/history/                        # Searchable lossless project-memory archive/index
├── docs/AGENT_RUNBOOK.md                # Canonical Codex/Gemini headless workflow
├── internal/EventViewer/                 # EventViewer credential/session adapter
├── tests/                                # Agent contract, Discovery, Workshop, connection and formatting tests
├── exports/                             # Φάκελος εξαγωγής αναφορών
├── Analyze-EventViewer.ps1              # Κεντρικό script διάγνωσης
├── Diagnose-LogonUIFreezes.ps1          # Read-only LogonUI/MSA/Windows Hello diagnostic
├── doc/                                 # Case reports και diagnostic handoff contracts
├── NEOS/                                # NEOS case report, manuals και guarded remediation helper
├── OptiPlex_7060_1.32.0.exe             # BIOS Update (Λήφθηκε & Επαληθεύτηκε)
├── PROJECT_RULES.md                     # Compact current architecture/contract
├── CHANGELOG.md                         # Καταγραφή εκδόσεων
└── README.md                            # Αυτό το αρχείο
```

---

## 🧠 Technical Notes

<details>
<summary><b>Πού αποθηκεύεται το WinRM password;</b></summary>

Το EventViewer δεν γράφει plaintext password. Το shared connector χρησιμοποιεί Windows DPAPI-backed `Export-Clixml` κάτω από `%LOCALAPPDATA%\WinRMConnection\credentials` και κάνει save μόνο μετά από successful authentication. Το profile ανοίγει μόνο από τον ίδιο Windows user στην ίδια Windows installation· μετά από format χρειάζεται νέα εισαγωγή.

</details>

<details>
<summary><b>Γιατί αποτυγχάνει η εγγραφή Dump (volmgr 161);</b></summary>

Όταν αποτυγχάνει η δημιουργία dump μπορεί να καταγραφεί `volmgr 161`. Το event μόνο του δεν ταυτοποιεί την αιτία. Decoded status όπως `0xC00000A1` ή `0xC00001AC` υποστηρίζουν πρόβλημα στο storage I/O path, αλλά χρειάζονται timestamps, controller/disk events και πραγματικό dump configuration πριν αποδοθεί ευθύνη σε συγκεκριμένο SSD, controller ή τροφοδοσία.

</details>

<details>
<summary><b>Πώς επηρεάζει το BIOS το TPM και τα κρασαρίσματα;</b></summary>

Η έκδοση BIOS, το microcode και το TPM firmware μπορούν να είναι σχετικά με stability investigations, αλλά δεν αποτελούν αυτόματο causal verdict. Ελέγχεται πρώτα το ακριβές μοντέλο, η current επίσημη έκδοση, τα release notes και το incident-correlated evidence. BIOS update εκτελείται μόνο χειροκίνητα από τον χρήστη.

</details>

---

<p align="center">
  <sub>eventviewer · Diagnostics Tool · Run BIOS updates manually only</sub>
</p>
