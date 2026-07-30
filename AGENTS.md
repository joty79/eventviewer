# AGENTS.md — EventViewer router

## Scope

This is the always-loaded project router for `D:\Users\joty79\scripts\eventviewer`.
Read [PROJECT_RULES.md](PROJECT_RULES.md) for the current architecture and active
contract. Do not load the historical archive by default; use
[docs/history/INDEX.md](docs/history/INDEX.md) only when a past incident or
decision is relevant.

For agent-operated discovery, connection and diagnostics, load
[docs/AGENT_RUNBOOK.md](docs/AGENT_RUNBOOK.md). The canonical headless entry
point is `Analyze-EventViewer.ps1`; do not add a second wrapper.

Before edits, confirm that this repository is the active Git root and preserve
unrelated user changes.

## Canonical owners

| Concern | Owner |
| --- | --- |
| App orchestration, TUI, diagnostics and exports | `Analyze-EventViewer.ps1` |
| EventViewer credential/session adaptation | `internal/EventViewer/Connect-EventViewerTarget.ps1` |
| LAN discovery and network-scoped target history | canonical `WinRMDiscovery` |
| Exact-target client `TrustedHosts` preparation | canonical `WinRMWorkshop` |
| Authentication, bounded retry, DPAPI profiles and session lifecycle | canonical `WinRMConnection` |
| Target-side WinRM/firewall/account preparation | explicit external setup/restore workflow |
| Codex/Gemini/headless operating procedure | `docs/AGENT_RUNBOOK.md` |
| User documentation | `README.md` |
| Release history | `CHANGELOG.md` |
| Old decisions and incident evidence | `docs/history/` |

The `.assets\WinRM*` directories are synchronized consumer copies. Never patch
them directly; change their canonical `.agent-shared` owner and sync them.

## Required boundaries

- Explicit UI/CLI target selection authorizes automatic preparation of that one
  exact target. Do not add a second trust prompt.
- Never accept, add or preserve `TrustedHosts = *` as ready state.
- Discovery must not authenticate or mutate configuration.
- Connection code must not discover targets or change WinRM configuration.
- EventViewer must not silently enable target-side WinRM, firewall, Registry,
  account or blank-password policy.
- Keep local and remote sessions bounded, show connection progress, reuse one
  authenticated session for a diagnostic batch, and close it in `finally`.
- Do not claim elevated, live-remote or end-to-end success unless that exact path
  actually ran and its result was verified.
- Before reboot, logoff or any action that may interrupt a live target, obtain
  immediate confirmation that the specific PC is free for disruption.
- BIOS updates are manual user actions only.
- Files under `docs\history\retired-agent-assets\` are evidence, not executable
  tools. Ignored `scratch*` files are user-owned experiments and are never
  canonical agent entry points.

## Validation route

For PowerShell changes, run parser checks, the focused project tests, relevant
canonical module tests, `PSScriptAnalyzer` Error review, vendored
`Sync-WinRM*.ps1 -VerifyOnly`, and `git diff --check`. Run live smoke only on an
authorized available target and state precisely what was not exercised.

Load the global PowerShell, UI, elevation, documentation and repository workflows
when their triggers apply.
