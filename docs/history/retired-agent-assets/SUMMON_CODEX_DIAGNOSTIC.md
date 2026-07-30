# Summon Codex — Generic Diagnostic Moderator Contract

## Trigger

For the remainder of this Antigravity chat, interpret the user phrase `Summon Codex` as an instruction to execute this contract for the current diagnostic case.

## Evidence Boundary

Before calling Codex:

1. Read the complete current Antigravity chat.
2. Resolve the diagnostic workspace explicitly named by the user. Read its `PROJECT_RULES.md` and only the case-relevant reports/exports referenced by the current chat or selected in the IDE.
3. Treat only commands, Event Viewer records, screenshots, workspace files and observations actually available in this case as evidence. Record the source path and timestamp for file evidence.
4. Do not scan or import unrelated historical case folders merely because they share the same workspace.
5. Separate:
   - verified facts,
   - user observations,
   - agent inferences,
   - unknown state.
6. Do not import evidence, thread IDs or conclusions from another repair case.
7. Do not include passwords, tokens or credentials.

## Case Packet

Prepare a compact packet containing:

- user goal and time constraints,
- machine identity and operating system, when known,
- exact symptoms and when they occur,
- recent hardware/software changes,
- exact Event Viewer provider, event ID, timestamp, exception/error code and message,
- commands already executed and their exact results,
- evidence already collected,
- exact workspace artifact paths and timestamps used,
- current hypotheses and what would disprove each one,
- the narrow question Codex should help answer.

Missing facts must be labelled `unknown`; never guess them.

## MCP Invocation

Use only MCP server `codex-reviewer`.

- If this Antigravity chat does not yet contain an active Codex `threadId` for the current case, call `codex` with the case packet and capture the returned visible `{threadId,content}`.
- If a current-case `threadId` already exists, call `codex-reply` with that exact ID.
- If `codex-reply` returns `Session not found`, call `codex` with the full current case packet, capture the new `threadId`, and continue only with that new ID.
- Never reuse the hardcoded thread ID or handoff from the previous Windows repair case.
- Never invent, transform or pre-fill a thread ID or tool result.

Ask Codex to:

- independently diagnose the evidence,
- identify the strongest causal chain rather than merely listing events,
- distinguish primary faults from shutdown artifacts and secondary errors,
- ask Gemini precise questions about missing context,
- challenge unsupported assumptions from either agent,
- rank the next read-only checks by information value,
- clearly gate any action that changes the machine.

## Multi-Turn Relay

Act as the moderator of a real technical dialogue, not as a one-call summarizer.

For up to six relay turns:

1. Show the exact Codex response visibly.
2. Answer Codex questions only from the current chat evidence.
3. When evidence conflicts, quote the exact conflicting record and ask Codex to revise.
4. Ask targeted follow-up questions when a conclusion lacks evidence.
5. Preserve the same current-case `threadId`.
6. Stop early when both agents reach a joint diagnosis or an explicit blocker.

If a required fact is unavailable, stop and ask the user only for that specific fact.

## Safety

- Diagnostic discussion and read-only evidence review are allowed.
- Do not execute commands or modify the target machine under this contract.
- Do not install/uninstall drivers, firmware or software.
- Do not change Registry, services, startup, BIOS/UEFI settings, disks or files.
- Do not reboot, shut down, reset, restore or format a machine.
- Before proposing any future major action, state the exact command/tool, target, expected change, risks, rollback/recovery behavior and estimated duration.
- Wait for explicit user approval immediately before any major action.
- Use only the narrow permission `mcp(codex-reviewer/*)`.

## Return Channel

After the dialogue finishes, create exactly one new Markdown file under:

```text
D:\Users\joty79\scripts\AgentBridge\returns\
```

Use the actual local timestamp:

```text
DIAGNOSTIC_RETURN_yyyyMMdd-HHmmss.md
```

Never overwrite, rename or delete an existing return file.

The return file must contain:

1. Local timestamp and a short case label.
2. Active Codex `threadId`.
3. Evidence packet sent to Codex.
4. Exact Codex questions.
5. Gemini answers with supporting evidence.
6. Exact Codex responses.
7. Agreed verified facts.
8. Remaining unknown or conflicting claims.
9. Ranked diagnosis with confidence and disproof criteria.
10. Safest next diagnostic step.
11. Whether explicit user approval is required.

Do not include passwords, tokens or credentials.

After writing the file, show its absolute path and tell the user:

```text
Return to the Codex Desktop chat and send: Sync Gemini evidence
```

## Completion

Finish with:

- active Codex `threadId`,
- agreed verified facts,
- ranked likely causes with confidence,
- evidence against each leading cause,
- remaining blocker,
- safest next step,
- whether user approval is required.
