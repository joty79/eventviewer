# Retired EventViewer agent assets

These files are lossless historical evidence. They are not current tools and
must not be executed, copied back into the active root or treated as permission
to repeat an old remediation.

| Archived file | SHA-256 | Retirement reason |
| --- | --- | --- |
| `test_diag_remote.ps1.txt` | `1B321F417644E4E946B9535AD4A0E003B7F067F190870D3C503384E9B70BF64E` | Hardcoded an old IP/user and forced blank-password behavior. |
| `apply_software_fixes.ps1.txt` | `3059A21136C079231CFF48DFFC5A3748C8CDB5F54B96FBD13664FC6CCE910E90` | Generic name hid immediate remote Registry and power-plan mutations without before-state or an explicit action gate. |
| `Verify-DiagnosticsFixes.ps1.txt` | `E0BF2889333ED2E2F602829A75650A72BB19B8A6100CC17AD47027CA5F4AB1F0` | Case-specific checks described preferences as universal healthy/warning conclusions. |
| `Apply-NeosFixes.ps1.txt` | `766B8A3EB42E12FD8E9902CB41FA0DD1C8D69500561CB8892DA89FB08344D5FA` | Conflicted with later NEOS evidence, ignored its `-Force` switch and printed unconditional success after caught failures. |
| `SUMMON_CODEX_DIAGNOSTIC.md` | `0FEB6EC4C6E59B82E100D6C001DE4A2CB9A4861B159822065E15905CC2E615B9` | Assumed a specific Antigravity MCP server, return folder and relay mechanism that are not a durable project contract. |

Git history and these exact byte-preserved copies provide recovery. The current
replacement contract is [../../AGENT_RUNBOOK.md](../../AGENT_RUNBOOK.md).
