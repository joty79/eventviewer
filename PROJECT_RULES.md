# PROJECT_RULES.md — EventViewer current contract

Last reviewed: 2026-07-31

## 1. Purpose

`Analyze-EventViewer.ps1` is the primary Windows PowerShell 7 tool for local and
remote investigation of system crashes, WHEA events, `volmgr` Event ID 161,
dump/pagefile state and related hardware evidence. It supports an interactive
TUI and a headless CLI path.

`Diagnose-LogonUIFreezes.ps1` is a separate read-only diagnostic for TPM,
Windows Hello/authentication logs and unexpected shutdown evidence.

Codex, Gemini and automation use the direct headless CLI documented in
`docs\AGENT_RUNBOOK.md`. There is no second agent-specific runner.

## 2. Current load map

```text
Analyze-EventViewer.ps1
├─ .agent-shared/templates/PS_UI_Blueprint.psm1   TUI rendering/input
├─ .assets/WinRMDiscovery                         discovery + target history
├─ .assets/WinRMWorkshop                          exact TrustedHosts preparation
├─ .assets/WinRMConnection                        authentication + session lifecycle
└─ internal/EventViewer/Connect-EventViewerTarget.ps1
                                                   EventViewer connection adapter
```

The three `.assets\WinRM*` folders are pinned, generated consumer copies. Their
canonical owner is under the resolved `.agent-shared` root; they must be updated
there and synchronized into this repository.

## 3. Canonical runtime flow

1. Accept an explicit `-ComputerName` or let the user invoke `Ctrl+L` discovery.
2. `WinRMDiscovery` returns structured same-LAN computer evidence and owns
   network-scoped successful-connection history. It does not authenticate.
3. Explicit target selection authorizes `WinRMWorkshop` to prepare only that
   exact hostname/IP in client `TrustedHosts`, without a second prompt.
4. The EventViewer adapter resolves an explicit credential, a saved DPAPI
   profile, a one-time prompt, or a deliberately blank local-account credential.
5. `WinRMConnection` performs TCP preflight and bounded authenticated session
   opening with visible status. Retry is only for transient opening failures.
6. EventViewer reuses one session for the read-only diagnostic batch, records
   successful targeting metadata, and closes the session in `finally`.

An open TCP 5985 port is discovery evidence, not proof of authentication.

## 4. Ownership boundaries

| Detail | Canonical owner |
| --- | --- |
| LAN enumeration, PC evidence, network identity, saved target metadata and stale-IP resolution | `WinRMDiscovery` |
| Client exact-target add/remove/readback for `TrustedHosts` | `WinRMWorkshop` |
| Credential profiles, blank-password credential construction, error classification, retries and PSSession opening | `WinRMConnection` |
| TUI keys, layout, target selection, diagnostic queries and export presentation | EventViewer |
| Agent/headless invocation, evidence labels and mutation boundary | `docs\AGENT_RUNBOOK.md` |
| Remote WinRM enablement, Private network, firewall, `LocalAccountTokenFilterPolicy` and blank-password target policy | explicit target-side setup/restore tool |

Do not recreate any of these responsibilities ad hoc in the consumer.

Old generic remote-test/remediation helpers and the tool-specific Antigravity
relay contract are preserved under `docs\history\retired-agent-assets\` as
non-executable evidence. They are not supported entry points.

## 5. Interactive and diagnostic behavior

- `Ctrl+L` opens LAN target selection; ordinary CLI use with `-ComputerName`
  remains available.
- `E` exports Markdown and CSV reports under `exports\`.
- `F` is the explicit Fast Startup quick action. Local mutation uses narrow
  elevation; remote mutation uses the already authenticated session.
- Common actions belong in the TUI. CLI switches remain available for automation
  and advanced use.
- Agents use the CLI path directly. They must supply an explicit target and must
  never inherit a historical IP, username or blank-password assumption.
- TUI rendering follows the shared `PS_UI_Blueprint.psm1`; terminal behavior is
  not considered verified by a headless text-only test.

## 6. Security and verification guardrails

- The workshop profile prioritizes speed on a controlled private LAN. WinRM
  HTTP/NTLM does not provide certificate-backed server identity and must not be
  described as an enterprise-secure default.
- Never use a wildcard or subnet wildcard in `TrustedHosts`. Preserve unrelated
  exact entries and verify readback after every mutation.
- Blank-password accounts and persistent Private-network/firewall/remote-UAC
  relaxations are intentional only when explicitly prepared on the target.
  EventViewer does not silently create or enable them.
- Store nonblank credentials only through the canonical DPAPI API and only after
  successful authentication. Never store blank passwords or plaintext secrets.
- Before Registry or BIOS remediation, capture the before-state. Rewriting an
  existing value is not a fix.
- `HiberbootEnabled = 1` alone does not prove active Fast Startup. Corroborate it
  with `powercfg /a`, `hiberfil.sys` state and, where practical, before/after
  evidence.
- A failed hardware/event query must render as `unknown` or `unavailable`, never
  as an empty/healthy result.
- PnP Code 22 means disabled state and may be intentional. Do not recommend
  enabling a device until its intended state and incident relevance are known.
- `volmgr` Event ID 161 proves dump-creation failure. Attribute a storage-path
  problem only when decoded status and correlated evidence support it; do not
  name a specific SSD/controller from Event 161 alone.
- Generic diagnostics must not contain a hardcoded “latest BIOS” version or
  infer an outdated BIOS from version-number shape. Verify the exact model
  against current official support data before making a recommendation.
- Never run BIOS update executables automatically.
- A parser, dry run, TCP probe or non-admin result is not proof of elevated or
  live end-to-end success.

## 7. Verification contract

Minimum checks for affected code:

- PowerShell AST/parser check for all changed `.ps1`, `.psm1` and `.psd1` files.
- `tests\Test-EventViewerAgentContract.ps1`
- `tests\Test-EventViewerWinRMWorkshop.ps1`
- `tests\Test-Connect-EventViewerTarget.ps1`
- `tests\Test-EventViewerFormatting.ps1` in PowerShell 7 and Windows PowerShell
  5.1 when deserialized WinRM objects are affected.
- Relevant `.agent-shared\tests\Test-WinRM*.ps1` suites.
- `PSScriptAnalyzer` Error review per changed PowerShell file.
- Relevant `.agent-shared\scripts\Sync-WinRM*.ps1 -VerifyOnly`.
- `git diff --check`.

Live validation must identify the exact target and account type, show connection
attempt status, distinguish read-only observation from mutation, and list every
path that remains unverified. No reboot, logoff or deliberate remote-access
interruption without immediate confirmation for that machine.

## 8. Documentation and memory

- `README.md` owns user-facing usage, security disclosure and project structure.
- `CHANGELOG.md` owns dated release changes and validation notes.
- This file owns only current architecture, boundaries and test expectations.
- [docs/history/INDEX.md](docs/history/INDEX.md) routes to the lossless legacy
  rules snapshot and case-specific evidence. Historical incidents are searchable
  evidence, not automatically active rules.
