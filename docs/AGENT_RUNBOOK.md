# EventViewer agent runbook

## Purpose

This is the canonical operating contract for Codex, Gemini and other automated
operators that use EventViewer. The supported agent path is the headless CLI of
`Analyze-EventViewer.ps1`; do not create or revive a second remote-diagnostic
wrapper.

The TUI is a user-facing optional surface. Agents do not need it for ordinary
diagnostics.

## Canonical read-only flow

1. Resolve this repository as the active workspace.
2. If the target is not already explicit, use the vendored `WinRMDiscovery`
   module and select one structured result with computer-specific evidence.
3. Treat the explicit hostname/IP selection as authorization for exact-target
   client `TrustedHosts` preparation. Do not ask a second trust question.
4. Run `Analyze-EventViewer.ps1` with an explicit target and account identity.
5. Show the `WinRMWorkshop` and `WinRMConnection` status stream, including
   `attempt 1/3`.
6. Let EventViewer reuse one authenticated session for the diagnostic batch and
   export the report locally.
7. Report the exact target, account type, connection outcome, report path and
   any unverified path. Never include a password.

### Known blank-password local account

Use `-BlankPassword` only when the user has explicitly identified that account
as having no password:

```powershell
& .\Analyze-EventViewer.ps1 `
    -ComputerName '<exact hostname or IP>' `
    -UserName '<TARGET\local-user>' `
    -BlankPassword
```

This constructs a one-time empty `SecureString`; it does not save a credential
profile.

### Nonblank account

Omit `-BlankPassword`. EventViewer may reuse a previously authenticated DPAPI
profile. If none exists, credential entry is an interactive user boundary:

```powershell
& .\Analyze-EventViewer.ps1 `
    -ComputerName '<exact hostname or IP>' `
    -UserName '<TARGET\local-user>'
```

An explicit `PSCredential` may be passed with `-Credential`, but agents must not
write its password into source, command history, logs, reports or chat.

## Discovery-only command

Discovery is read-only and must remain separate from authentication:

```powershell
Import-Module .\.assets\WinRMDiscovery\WinRMDiscovery.psd1 -Force
Find-WinRMComputer -IncludeDiagnostics -DiagnosticsInMemoryOnly |
    Select-Object ComputerName, IPAddress, MACAddress, WinRMHttpOpen, Status
```

An open TCP 5985 port is not authentication proof.

## Mutation boundary

The headless EventViewer diagnostic reads the remote PC and writes reports only
under the local `exports\` directory. Its expected client-side mutation is the
idempotent addition of the explicitly selected exact target to `TrustedHosts`,
with elevation and readback verification when required.

Do not use EventViewer history or old case scripts as permission to change the
remote PC. Target-side WinRM enablement, Registry, services, firewall, accounts,
drivers, power configuration and repairs require a separate explicit plan:

- identify the exact target and current user impact;
- capture before-state;
- state the exact proposed command and rollback;
- obtain approval for the mutation;
- execute the real privileged path;
- verify the resulting state and label partial failures honestly.

Reboot, logoff and management-service interruption always require immediate
confirmation that the exact target is free for disruption.

## Evidence and failure reporting

Minimum successful handoff:

- target hostname/IP and observed OS identity;
- account name/type without its password;
- exact-target `TrustedHosts` result;
- actual authentication attempt count and elapsed time;
- report/export paths;
- whether elevation was required;
- what was not exercised.

Classify TCP availability, authentication and diagnostic execution separately.
A parser pass, TCP probe, cached history entry or non-admin check is never a
substitute for a live authenticated result.

## Retired and scratch assets

- Files under `docs\history\retired-agent-assets\` are searchable evidence only.
  They are intentionally non-canonical and must not be executed.
- Ignored files matching `scratch*` are user-owned experiments. They are not
  reviewed project entry points and must not be used unless the user explicitly
  places that exact file in scope.
- Historical reports can explain why an action happened; they do not authorize
  repeating it on the same or another PC.

## Cross-agent handoff

Pass a compact evidence packet containing verified facts, user observations,
agent inferences, unknowns, exact artifact paths and the narrow unresolved
question. Do not assume a particular MCP server, tool name or thread ID exists.
Use the current environment's supported handoff mechanism and never reuse an ID
from another case.
