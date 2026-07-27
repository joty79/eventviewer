# DIAGNOSIS REPORT - PC NEOS (192.168.1.6)

---

## 🔵 1. Πληροφορίες Συστήματος

* **Όνομα Υπολογιστή:** `NEOS` (`192.168.1.6`)
* **Μητρική:** MSI MAG X870 TOMAHAWK WIFI (MS-7E51, PCB Rev 1.0)
* **CPU:** AMD Ryzen 7 9700X (Granite Ridge / Zen 5)
* **GPU:** NVIDIA GeForce RTX 4060 Ti
* **BIOS:** `1.A65` (17/07/2025)
* **OS:** Windows 10 Pro 64-bit (Build 19045)
* **Manuals:**
  * [MAGX870TOMAHAWKWIFI_English.pdf](file:///d:/Users/joty79/scripts/eventviewer/NEOS/MAGX870TOMAHAWKWIFI_English.pdf)
  * [AMDAM5800BIOS_English x870 bios.pdf](file:///d:/Users/joty79/scripts/eventviewer/NEOS/AMDAM5800BIOS_English%20x870%20%20bios.pdf)

---

## 🔵 2. Ακριβές Timeline του Incident

1. **Αρχικό hard freeze κατά το display wake**
   * Ο υπολογιστής ήταν idle και οι δύο οθόνες είχαν σβήσει.
   * Με κίνηση του ποντικιού επανήλθε μόνο η μία οθόνη.
   * Η taskbar ήταν ορατή αλλά frozen.
   * `Ctrl+Alt+Del`, DisplayPort reconnect και USB reconnect πληκτρολογίου/ποντικιού δεν άλλαξαν την κατάσταση.
2. **Πρώτο αναγκαστικό shutdown**
   * Ο χρήστης κράτησε πατημένο το Power Button επειδή το σύστημα δεν ανταποκρινόταν.
   * Το μεταγενέστερο Kernel-Power Event ID 41 καταγράφει αυτή την αναγκαστική διακοπή. Δεν αποτελεί την αιτία του αρχικού freeze.
3. **Normal Mode black screen**
   * Μετά την εκκίνηση, το Normal Mode κατέληγε σε black screen.
   * Ακολούθησε δεύτερο αναγκαστικό shutdown.
4. **Σκόπιμο Safe Mode**
   * Ο χρήστης ενεργοποίησε σκόπιμα το Safe Mode with Networking για διάγνωση.
   * Το Safe Mode λειτουργούσε κανονικά. Δεν αφαιρέθηκε ο NVIDIA driver.
5. **Επιστροφή σε Normal Mode**
   * Μετά το Safe Mode cycle και τις ταυτόχρονες Windows-side ενέργειες, το Normal Mode boot αποκαταστάθηκε.
   * Δεν απομονώθηκε ποια επιμέρους ενέργεια καθάρισε το black screen.

---

## 🔵 3. Παρατηρήσεις και Όρια των Αποδείξεων

### 🔸 Kernel-Power Event ID 41

Το XML είχε `BugcheckCode = 0` και μη μηδενικό `PowerButtonTimestamp = 134294383680114449`. Αυτό επιβεβαιώνει το παρατεταμένο πάτημα του Power Button που περιέγραψε ο χρήστης, όχι την τεχνική αιτία του freeze.

### 🔸 Safe Mode έναντι Normal Mode

Το επιτυχές Safe Mode δείχνει ότι το black screen συνδεόταν με driver, service ή persisted state που δεν φορτώνεται με τον ίδιο τρόπο στο Safe Mode. Ο NVIDIA display stack είναι εύλογος ύποπτος λόγω του display-wake συμπτώματος, αλλά δεν βρέθηκε incident-correlated `nvlddmkm` event, TDR dump ή LiveKernelReport που να το αποδεικνύει.

### 🔸 Ιστορικά NVIDIA Event ID 153

Υπήρχαν παλαιότερα, ασυμπτωματικά `nvlddmkm` Event ID 153. Το παρεχόμενο παράδειγμα ήταν στις `2026-04-29` και δεν συνοδευόταν από freeze, flicker, game/app crash ή άλλο αντιληπτό σύμπτωμα. Δεν συνδέεται χρονικά με το incident της 25ης Ιουλίου.

### 🔸 AMD PSP Code 22

Το `AMD PSP 11.0 Device` είχε `ConfigManagerErrorCode = 22`, επειδή ο χρήστης το είχε απενεργοποιήσει σκόπιμα μαζί με το fTPM. Το Code 22 αποδεικνύει μόνο disabled PnP state. Δεν αποδεικνύεται ότι το PSP/fTPM προκάλεσε το idle/display-wake freeze.

### 🔸 Fast Startup / Hibernation

Καταγράφηκε μόνο `HiberbootEnabled = 1`. Το registry preference από μόνο του δεν αποδεικνύει ότι:

* υπήρχε ενεργό και χρησιμοποιήσιμο `hiberfil.sys`,
* το `powercfg /a` επέτρεπε hibernation,
* το προηγούμενο boot χρησιμοποίησε Fast Startup.

Δεν καταγράφηκε before-state για το `hiberfil.sys` ή τον διαθέσιμο χώρο δίσκου. Επομένως η προηγούμενη λειτουργική κατάσταση της hibernation παραμένει άγνωστη.

---

## 🔵 4. Windows-side Ενέργειες και Αποκατάσταση

1. **Safe Mode diagnostic cycle**
   * Το Safe Mode ενεργοποιήθηκε σκόπιμα και λειτούργησε.
   * Δεν αφαιρέθηκε ή επανεγκαταστάθηκε ο NVIDIA driver.
2. **Προσωρινή ενεργοποίηση AMD PSP 11.0**
   * Εκτελέστηκε `Enable-PnpDevice` και επιβεβαιώθηκε `ConfigManagerErrorCode = 0`.
   * Μετά την αποκατάσταση, ο χρήστης επέλεξε να απενεργοποιήσει ξανά PSP/fTPM.
   * Η προσωρινή ενεργοποίηση δεν θεωρείται αποδεδειγμένο fix.
3. **Απενεργοποίηση hibernation/Fast Startup**
   * Εκτελέστηκε `powercfg /h off` και γράφτηκε `HiberbootEnabled = 0`.
   * Δεν υπήρχε καταγεγραμμένο before-state που να αποδεικνύει ενεργό `hiberfil.sys`.
4. **Επαναγραφή προϋπαρχόντων TDR values**
   * Το remediation script έγραψε `TdrDelay = 10` και `TdrDdiDelay = 10`.
   * Οι ίδιες decimal τιμές υπήρχαν ήδη από παλαιότερο `.reg` tweak (`dword:0000000a`).
   * Δεν υπήρξε πραγματική αλλαγή στο TDR configuration και δεν μπορεί να πιστωθεί σε αυτό η αποκατάσταση.
5. **Επαναφορά BCD σε Normal Boot**
   * Αφαιρέθηκε η σκόπιμα τεθείσα παράμετρος safeboot (`bcdedit /deletevalue {current} safeboot`).

### 🔸 Πιθανότερη εξήγηση του Normal Mode black screen

Το Safe Mode ➔ Normal Mode cycle είναι η ισχυρότερη πρακτική εξήγηση: φόρτωσε minimal driver set/Microsoft display path και επέτρεψε καθαρή επόμενη αρχικοποίηση στο Normal Mode. Το `powercfg /h off` μπορεί επίσης να καθάρισε persisted hibernation/Fast Startup state, εάν τέτοιο state υπήρχε πραγματικά.

Επειδή οι ενέργειες έγιναν μαζί, δεν υπάρχει αιτιώδης απομόνωση. Το report δεν αποδίδει το black screen ως αποδεδειγμένο PSP, hibernation ή NVIDIA failure.

---

## 🔵 5. Προληπτικές BIOS/CPU Αλλαγές μετά την Αποκατάσταση

Οι ακόλουθες αλλαγές έγιναν **μετά** την επιτυχή επιστροφή σε Normal Mode. Δεν αποτελούν το fix του black screen. Είναι προληπτικές δοκιμές για μείωση της πιθανότητας νέου idle freeze.

### 1. fTPM 2.0 / AMD PSP

* Ενεργοποιήθηκε προσωρινά μετά το incident και αργότερα απενεργοποιήθηκε ξανά από τον χρήστη.
* **Τρέχουσα αναφερόμενη κατάσταση:** Disabled.
* Δεν υπάρχει τεκμηριωμένη αιτιώδης σύνδεση με το συγκεκριμένο freeze.

### 2. Power Supply Idle Control

* **Διαδρομή (BIOS manual page 44):** `Overclocking` ➔ `Advanced CPU Configuration` ➔ `AMD CBS` ➔ `Power Supply Idle Control`.
* **Αλλαγή:** `Auto` ➔ `Typical Current Idle`.
* **Σκοπός:** Αποφυγή υπερβολικά χαμηλού platform/PSU current κατά το idle. Μπορεί να βοηθήσει προληπτικά εάν το freeze προήλθε από low-current transition.

### 3. Global C-State Control

* **Διαδρομή (BIOS manual page 44):** `Overclocking` ➔ `Advanced CPU Configuration` ➔ `AMD CBS` ➔ `Global C-state Control`.
* **Κατάσταση:** Δεν ελέγχθηκε και δεν άλλαξε.

### 4. Memory Context Restore & Power Down Enable

* **Διαδρομές (BIOS manual pages 49 και 53):**
  * `Overclocking` ➔ `Memory Context Restore` [Enabled].
  * `Overclocking` ➔ `Advanced DRAM Configuration` ➔ `Misc item` ➔ `Power Down Enable` [Enabled].
* **Αλλαγή:** Το `Memory Context Restore` παρέμεινε Enabled και το `Power Down Enable` τέθηκε Enabled.
* **Σκοπός:** Συνεπής DDR5 context/low-power configuration. Μπορεί να βοηθήσει προληπτικά εάν το freeze σχετιζόταν με marginal DDR5 state.

### 5. Curve Optimizer / Curve Shaper

* **Υφιστάμενο tuning:** `Curve Optimizer = Negative 30`, αναφερόμενο ως σταθερό για περίπου 10 μήνες σε games και κανονική χρήση.
* **Νέα προληπτική αντιστάθμιση στα minimum-frequency corners:**

| Curve Shaper band | Τρέχουσα τιμή |
|---|---:|
| Min Frequency - Low Temperature | Positive 5 |
| Min Frequency - Med Temperature | Positive 5 |
| Low Frequency - Low Temperature | Disabled / 0 |
| Low Frequency - Med Temperature | Disabled / 0 |

* **Σκοπός:** Επιστροφή μικρού positive voltage offset μόνο στα minimum-frequency/low-to-medium-temperature σημεία, όπου ένα γενικό `CO -30` μπορεί να είναι οριακό κατά το idle, χωρίς να αναιρείται το tuning στα υψηλότερα frequency bands.

---

## 🔵 6. Τελικό Συμπέρασμα και Monitoring

* Το Normal Mode black screen αποκαταστάθηκε πιθανότερα από το Safe Mode ➔ Normal Mode cycle, με πιθανή αλλά μη αποδεδειγμένη συμβολή του `powercfg /h off`.
* Τα TDR values δεν άλλαξαν και οι BIOS/Curve Shaper αλλαγές έγιναν μετά την αποκατάσταση.
* Η root cause του αρχικού idle/display-wake hard freeze παραμένει μη αποδεδειγμένη.
* Πιθανές αιτίες παραμένουν NVIDIA/display-resume hang, low-current platform transition, marginal DDR5 state ή low-voltage CPU idle corner από το `CO -30`.
* Οι `Typical Current Idle`, `Power Down Enable = Enabled` και οι δύο `Curve Shaper Positive 5` αλλαγές έχουν εύλογη πιθανότητα να μειώσουν την επανάληψη εάν η αιτία ήταν low-current, DDR5-state ή low-voltage idle corner.
* Εάν το freeze επανέλθει, προτεραιότητα έχει η συλλογή live evidence από το laptop μέσω WinRM πριν από forced shutdown: ping/WinRM responsiveness, `Win+Ctrl+Shift+B`, Caps/Num Lock response και incident-correlated System/Application events.
* Η τρέχουσα απόφαση είναι monitoring χωρίς πρόσθετες αλλαγές και επανεκτίμηση μόνο εάν υπάρξει νέο πραγματικό σύμπτωμα.

---

## 🔵 7. Ιστορικό Ενημερώσεων Διαγνωστικών Εργαλείων

* **[Analyze-EventViewer.ps1](file:///d:/Users/joty79/scripts/eventviewer/Analyze-EventViewer.ps1):** Ενημερώθηκε με αυτόματο εντοπισμό PnP Device Errors (Code 22/31), dynamic dump path resolution (`D:\Temp\CrashDumps`) και XML parsing του Kernel-Power 41.
* **[PROJECT_RULES.md](file:///d:/Users/joty79/scripts/eventviewer/PROJECT_RULES.md):** Ενημερώθηκε με το διορθωμένο στιγμιότυπο διάγνωσης του `NEOS`.
