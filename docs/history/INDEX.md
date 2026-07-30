# EventViewer historical knowledge index

This directory preserves project memory that is useful for diagnosis and
decision archaeology but is not part of the always-loaded active contract.

## Lossless rules snapshot

- Snapshot:
  [PROJECT_RULES-legacy-through-2026-07-30.md](PROJECT_RULES-legacy-through-2026-07-30.md)
- Source at capture time: root `PROJECT_RULES.md`
- Captured: 2026-07-30, before the rules-audit refactor
- SHA-256:
  `FAE54FC25D39AB27E8A8F2C2880DD4401D10DF9B66E539759E0148D3261652B4`
- Integrity: the source and archive hashes matched at capture time.

## Classification

| Classification | Material | Current owner |
| --- | --- | --- |
| Active contract | WinRM owner split, exact-target trust, TUI/export behavior, Hiberboot evidence, remediation before-state and manual-only BIOS updates | root `PROJECT_RULES.md` |
| Release evidence | Completed changes, versions and validation notes | root `CHANGELOG.md` |
| Historical evidence | LogonUI runtime incident, bounded WinRM/DPAPI migration, parser inspection pitfall, DESKTOP-CONSTRU RAM snapshot, OptiPlex 7060 case and NEOS case | lossless snapshot and case documents |
| Superseded/dead weight | Dated implementation detail, transient IP/version state and one-off command-wrapper advice treated as universal project rules | archive only |

## Retired agent assets

[retired-agent-assets/README.md](retired-agent-assets/README.md) indexes the
lossless copies and SHA-256 hashes of:

- stale hardcoded remote-test and remediation helpers;
- the case-specific verifier and NEOS remediation script;
- the old Antigravity `codex-reviewer` relay contract.

They are retained for search and incident reconstruction, not execution. The
current replacement is [../AGENT_RUNBOOK.md](../AGENT_RUNBOOK.md).

## Search map

Use targeted search instead of loading the full snapshot:

```powershell
rg -n "LogonUI|CimInstance|Invoke-CimMethod" docs/history
rg -n "WinRM|DPAPI|TrustedHosts|192\\.168\\.1\\.47" docs/history CHANGELOG.md
rg -n "DESKTOP-CONSTRU|DIMM2|Micron" docs/history
rg -n "OptiPlex|volmgr|0xC00000A1|0xC00001AC" docs/history doc
rg -n "NEOS|nvlddmkm|Curve Optimizer|Hiberboot" docs/history doc NEOS
```

When historical evidence changes a current safety or architecture decision,
promote only the durable conclusion to root `PROJECT_RULES.md`; keep the incident
record here.
