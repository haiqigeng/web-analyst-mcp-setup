---
name: web-analyst-mcp-setup
description: Set up, authenticate, verify, troubleshoot, reconnect, hand over, or safely remove selected web-analyst MCP integrations on Windows for Codex, Claude Code, Gemini CLI, and similar agents. Use for first-day setup on personal or organization-managed PCs; connecting Gmail, Google Workspace/Drive, GTM, GA4, BigQuery, browser QA/debugging, and cataloged analytics tools to intended personal or organizational accounts or resources; or diagnosing and maintaining an existing web-analyst MCP connection.
---

# Web Analyst MCP Setup

## North Star

**Achieve first-day setup success on any Windows PC: with minimal user effort, install only the required prerequisites, configure the selected web-analyst tools, and verify access to the intended accounts or resources through a working route approved by the user and, when organizational data or accounts are involved, permitted by the organization.**

Treat device ownership and account or data governance separately. A personal PC may access organizational accounts, and an organization-managed PC may access personal accounts. Use neutral defaults and ask about organizational policy only when the selected account, data, or provider makes it relevant.

Optimize for first-day utility: minimal questions, minimal credentials, no unintended changes, and one clear next action when a tool cannot be completed. The visible journey is **Select → Connect → Done**.

## Sources Of Truth

- Use `config/mcp-catalog.json` for provider, runtime, trust, authentication, scope, risk, endpoint, package, and smoke-test details. Read only entries selected by the user unless maintaining the catalog.
- Use `config/client-capabilities.json` for client targets and reload behavior.
- Use `scripts/WebAnalystSetup.ps1 -Action Connect` for the normal setup path.
- Use `docs/data-and-credential-safety.md` before connecting a third-party remote provider or handling high-risk credentials.

Do not copy provider details into this file. Update the catalog when a provider changes.

## Non-Negotiable Safety

- Preview before installing prerequisites or changing client configuration. Run `Connect -Confirmed` only after the user approves the displayed plan.
- Before connection, disclose third-party data routing, non-first-party providers, high risk, write capability, IAM, or cost exposure when applicable.
- Never overwrite an unowned MCP server name. Preserve unrelated configuration, create backups, and mutate only kit-owned entries.
- Keep credentials in ignored local files or approved stores. Never print, commit, reuse outside their intended account or organization, or pass unrelated keys to an MCP process.
- Verification is target-first and read-only. Never enumerate broad inventories when a known account, property, container, project, dataset, site, or workspace can be checked directly.
- Never send, delete, move, publish, deploy, revoke, edit vendor settings, or run broad/costly queries without separate explicit approval for the exact action and target.
- A credential or token file is not success. Mark a tool verified only after a read-only call proves access to the intended target.

## Activation

Ask which tools the user needs now. Ask which AI client only when it cannot be detected or the user wants more than one. Accept friendly names such as `gtm`, `ga4`, and `playwright`; never ask the user to edit selection JSON.

Run all PowerShell commands and internal evidence updates for the user. Ask the user only for plan approval, browser sign-in, account or target choices, and unavoidable credential, organizational-policy, or vendor-console decisions.

If the user asks for "everything" or does not know which tools they need, ask what work they need to accomplish today and recommend the smallest relevant selection. Never interpret "everything" as the entire catalog or install a preset bundle.

Defer organizational-policy, provider, project, scope, IAM, and credential questions until a selected tool actually requires them. Do not collect secrets in chat when browser OAuth or an approved local or vault route is available.

## Select → Connect → Done

1. Preview the exact selection:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Connect -Tools gtm,ga4,playwright -Client Codex
   ```

   `Connect` maps friendly names, scopes the ignored credential file to selected tools, detects required runtimes, and displays provider/data-routing risks. Without `-Confirmed`, it does not install prerequisites or change MCP client configuration.

2. Ask for one approval covering the displayed prerequisite installs and kit-owned client changes. If the plan contains a third-party route, high-risk provider, write-capable connector, IAM work, or cost exposure, name it plainly before requesting approval.

3. After approval, resume the same action:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Connect -Tools gtm,ga4,playwright -Client Codex -Confirmed
   ```

   Let ready tools finish even when another tool is blocked. The script installs only selected prerequisites, locks exact MCP versions, protects existing configuration, and writes `generated/setup-summary.md`.

4. Complete only the remaining next actions from the summary. Finish no-auth and browser-OAuth tools before longer IAM or vendor-admin work. Open browser OAuth directly when possible; ask for a credential, IAM change, or vendor-console step only when it is the current blocker. Reload a client only when its capabilities file says discovery requires it.

5. For each tool, run the catalog `testPrompt` against the user-confirmed target. Record Authenticated, Visible, and Verified evidence internally as facts are observed; do not make the user run evidence commands. Refresh the setup summary after evidence changes.

6. Return the concise result: **Verified**, **Ready to verify**, or **Blocked**, with the connected target and one precise next action. Do not expose internal JSON, package reports, or evidence state unless asked.

## Provider Decisions

- **Catalog default** means the maintained preferred route for this skill after balancing utility, auth friction, support, and risk. It is not automatically first-party or automatically permitted for organizational data.
- **First-party** means the service or tool owner maintains the route. Prefer it when applicable organizational policy requires it or its extra setup cost is justified.
- **Fallback** means a cataloged alternative whose `fallbackWhen` condition matches the actual blocker. Do not present every provider to the user.
- Do not install an uncataloged provider during onboarding. Verify primary sources and update the catalog first.

## Completion And Resume

A tool is complete only when it is configured, authenticated when required, visible in the active client, and verified against the intended target. The user may still move on when every selected tool is either **Verified** or has one precise blocker, owner, and next action.

Resume from `generated/onboarding-state.json`; do not restart completed stages. Preserve passed evidence. A provider change invalidates that tool's old evidence and requires configuration, authentication, visibility, and verification to be checked again.

## Reset Boundaries

Do not reset after successful real onboarding.

- Use `ResetMcpConfig` only with explicit approval to remove entries proven to be owned by this kit. It preserves unowned and user-modified entries and creates backups.
- Use `ResetKit` after a simulation, before sharing the folder, when leaving an organization or client, when handing off a personal PC, or when intentionally removing local credentials and generated state. It does not silently delete MCP client configuration.
- Run `ResetMcpConfig` before `ResetKit` when both disconnection and local cleanup are intended.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action ResetMcpConfig -Client Selected -ConfirmedMcpEndpointDeletion
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action ResetKit
```
