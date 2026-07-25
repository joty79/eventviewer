# DIAGNOSIS REPORT - PC NEOS (192.168.1.6)

---

## 🔵 1. Πληροφορίες Συστήματος (System Specifications)
* **Όνομα Υπολογιστή:** `NEOS` (`192.168.1.6`)
* **Μητρική Κάρτα:** Micro-Star International Co., Ltd. **MAG X870 TOMAHAWK WIFI** (MS-7E51, PCB Rev 1.0)
* **Επεξεργαστής:** AMD Ryzen 7 9700X 8-Core Processor (Granite Ridge / Zen 5, AM5 Socket)
* **Κάρτα Γραφικών:** NVIDIA GeForce RTX 4060 Ti
* **BIOS Version:** `1.A65` (Release Date: 17/07/2025)
* **Λειτουργικό Σύστημα:** Windows 10 Pro 64-bit (Build 19045)
* **Manuals Αναφοράς:** 
  - [MAGX870TOMAHAWKWIFI_English.pdf](file:///d:/Users/joty79/scripts/eventviewer/NEOS/MAGX870TOMAHAWKWIFI_English.pdf)
  - [AMDAM5800BIOS_English x870 bios.pdf](file:///d:/Users/joty79/scripts/eventviewer/NEOS/AMDAM5800BIOS_English%20x870%20%20bios.pdf)

---

## 🔵 2. Σύμπτωμα & Αρχική Κατάσταση (Symptom & Root Cause)
1. **Αρχικό Πάγωμα (Hard Freeze σε Idle):** 
   Ο υπολογιστής έμεινε αδρανής (idle) και πάγωσε πλήρως (οθόνη, πληκτρολόγιο, ποντίκι ανενεργά).
2. **Μαύρη Οθόνη κατά την εκκίνηση σε Normal Mode:**
   Μετά από αναγκαστικό hard restart (παρατεταμένο πάτημα Power Button), η εκκίνηση σε Normal Mode κατέληγε σε Μαύρη Οθόνη (Black Screen).
3. **Safe Mode με Δίκτυο:**
   Η εκκίνηση σε Safe Mode with Networking λειτουργούσε κανονικά.

---

## 🔵 3. Τεχνική Ανάλυση & Ευρήματα (Technical Analysis)

### 🔸 Αιτία 1: AMD PSP 11.0 Device Disabled (Code 22)
* **Εύρημα:** Η συσκευή `AMD PSP 11.0 Device` (Platform Security Processor / fTPM, `PCI\VEN_1022&DEV_1649...`) ήταν απενεργοποιημένη στο Device Manager (`ConfigManagerErrorCode = 22`).
* **Μηχανισμός:** Στους επεξεργαστές AMD Ryzen 9000 Series (AM5), όταν η συσκευή AMD PSP / fTPM είναι απενεργοποιημένη ή λείπει ο οδηγός chipset, οι μεταβάσεις του επεξεργαστή σε χαμηλή κατανάλωση ενέργειας κατά την αδράνεια (Idle C6 States / Display Sleep) προκαλούν ολικό ακαριαίο πάγωμα του υπολογιστή (Hard Lockup).

### 🔸 Αιτία 2: Φθαρμένη Κατάσταση Συνεδρίας (Fast Startup / Hiberboot)
* **Εύρημα:** Το Fast Startup (`HiberbootEnabled = 1`) ήταν ενεργοποιημένο.
* **Μηχανισμός:** Κατά το hard restart (Power Button timestamp `134294383680114449`), τα Windows αποθήκευσαν φθαρμένη κατάσταση στο `hiberfil.sys`. Κάθε προσπάθεια εκκίνησης σε Normal Mode προσπαθούσε να επαναφέρει τη φθαρμένη συνεδρία, προκαλώντας κατάρρευση του οδηγού κάρτας γραφικών NVIDIA (`nvlddmkm.sys`) / DWM σε Μαύρη Οθόνη.

---

## 🔵 4. Ενέργειες Επισκευής που Εκτελέστηκαν (Executed Repairs)

1. ✅ **Ενεργοποίηση της συσκευής AMD PSP 11.0:**
   * Εκτελέστηκε απομακρυσμένη ενεργοποίηση μέσω PowerShell (`Enable-PnpDevice`).
   * **Επαλήθευση:** Η συσκευή άλλαξε σε `Status: OK` (`ConfigManagerErrorCode = 0`).
2. ✅ **Πλήρης Απενεργοποίηση Fast Startup:**
   * Εκτελέστηκε `powercfg /h off` και `HiberbootEnabled = 0` στο μητρώο, διαγράφοντας τη φθαρμένη κατάσταση αδρανοποίησης.
3. ✅ **Ρύθμιση Graphics Driver TDR Delay (10s):**
   * Προστέθηκαν οι τιμές `TdrDelay = 10` & `TdrDdiDelay = 10` στο `HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers` για αποτροπή TDR timeouts της RTX 4060 Ti κατά την εκκίνηση.
4. ✅ **Επαναφορά BCD σε Normal Boot:**
   * Αφαιρέθηκε η παράμετρος safeboot από το BCD (`bcdedit /deletevalue {current} safeboot`).

---

## 🔵 5. Επαληθευμένες Ρυθμίσεις BIOS (Επίσημο Εγχειρίδιο MSI AM5 X870 BIOS)

Με βάση το επίσημο manual της MSI (`AMDAM5800BIOS_English x870 bios.pdf`), παρατίθενται οι ακριβείς διαδρομές BIOS για τη διατήρηση 100% σταθερότητας:

### 1. **fTPM 2.0 / AMD PSP Switch**
* **EZ Mode (Page 6 / 25):** `EZ On/Off` ➔ `fTPM 2.0` (Switch **ON**).
* **Advanced Mode (Page 62):** `Security` ➔ `Trusted Computing` ➔ `Security Device Support` [Enabled] & `AMD fTPM switch` [AMD CPU fTPM].

### 2. **Power Supply Idle Control (Αποτροπή Idle Freeze)**
* **Advanced Mode (Page 44):** `Overclocking` ➔ `Advanced CPU Configuration` ➔ `AMD CBS` ➔ `Power Supply Idle Control`.
* **Ρύθμιση:** **Typical Current Idle** (αντί για Low Current Idle).

### 3. **Global C-State Control**
* **Advanced Mode (Page 44):** `Overclocking` ➔ `Advanced CPU Configuration` ➔ `AMD CBS` ➔ `Global C-state Control` [Auto / Enabled].

### 4. **Memory Context Restore & Power Down (DDR5 EXPO)**
* **Advanced Mode (Page 49 & 53):** `Overclocking` ➔ `Memory Context Restore` [Enabled] & `Overclocking` ➔ `Advanced DRAM Configuration` ➔ `Misc item` ➔ `Power Down Enable` [Enabled]. *(Πρέπει να είναι και τα δύο Enabled μαζί).*

---

## 🔵 6. Ιστορικό Ενημερώσεων Διαγνωστικών Εργαλείων
* **[Analyze-EventViewer.ps1](file:///d:/Users/joty79/scripts/eventviewer/Analyze-EventViewer.ps1):** Ενημερώθηκε με αυτόματο εντοπισμό PnP Device Errors (Code 22/31), dynamic dump path resolution (`D:\Temp\CrashDumps`), και XML parsing του Kernel-Power 41.
* **[PROJECT_RULES.md](file:///d:/Users/joty79/scripts/eventviewer/PROJECT_RULES.md):** Ενημερώθηκε με το στιγμιότυπο διάγνωσης του `NEOS`.
