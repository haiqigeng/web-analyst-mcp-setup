---
name: web-analyst-mcp-setup
description: Set up, authenticate, verify, troubleshoot, reconnect, hand over, or safely remove web-analyst MCP integrations on Windows for Codex, Claude Code, Gemini CLI, and similar agents. Use for first-day company PC onboarding, selected-tool setup for Gmail, Google Workspace/Drive, GTM, GA4, BigQuery, browser QA/debugging, and cataloged analytics tools, or when an existing web analyst MCP connection needs diagnosis or maintenance.
---

# Web Analyst MCP Setup

Guide the user through a conversational, Windows-first onboarding. Use the repository scripts for deterministic machine changes and keep the user in the conversation except for browser login, approval, or vendor-console steps that cannot be automated.

## Source Of Truth

- Use `config/mcp-catalog.json` for provider, runtime, trust, authentication, scope, risk, endpoint, package, and smoke-test details. Read only entries selected by the user unless maintaining the catalog.
- Use `config/client-capabilities.json` for client targets and reload behavior.
- Use `scripts/WebAnalystSetup.ps1` for setup operations.
- Use `docs/data-and-credential-safety.md` before connecting a third-party remote provider or handling high-risk credentials.
- Treat `config/tool-profiles.json` as dormant/manual scaffolding. Do not use profiles in normal onboarding unless explicitly requested.

Do not copy provider details into this file. Update the catalog when a provider changes.

## Non-Negotiable Safety

- Start with harmless read-only smoke tests.
- Never send email, delete or move files, edit vendor settings, publish GTM, deploy, revoke access, reset MCP endpoints, or run broad/costly SQL without explicit approval for the exact target and action.
- During setup, use `Apply -Preview` before changing MCP client configuration.
- Do not overwrite an unowned MCP server name. Preserve unrelated client configuration and keep generated backups.
- Never print, commit, or place secrets in reusable files. Use ignored `secrets/.env.local` or the documented `KEY_FILE` pattern.
- Never reuse credentials from a previous employer, agency, or client.
- Tell the user when company data will pass through a third-party hosted MCP or broker.
- Treat credentials or token-file presence as incomplete. A tool is ready only after it is configured, authenticated, visible in the current client, and verified by a read-only call.

## Activation

Ask one compact intake group:

1. Which AI clients should be configured?
2. Which cataloged tools should be enabled now?
3. Is this personal, one company/project, or an agency/team context?
4. Are approved company credentials, OAuth clients, vault items, IAM access, or managed brokers available?
5. Does company policy require first-party providers, or are catalog defaults allowed?

Ask tool-specific credential questions only after selection. Do not make profiles part of the default flow.

## Onboarding Workflow

1. Prepare ignored local files:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Prepare
   ```

   Update `config/tool-selection.json` and `secrets/.env.local` for the user. Do not ask the user to edit them unless they prefer not to share a secret in conversation.

2. Inspect the machine before installing anything:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Doctor
   ```

3. If credentials are missing, generate direct setup URLs:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action CredentialGuide
   ```

   Prefer company credentials, vendor OAuth, approved brokers, vendor tokens, then a new cloud project only with permission.

4. Install only selected-provider prerequisites:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Prereqs
   ```

5. Resolve current packages and write an exact local version lock before MCP launch:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action CheckMcpUpdates
   ```

6. Preview and apply configuration only to clients selected in `tool-selection.json`:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Apply -Client Selected -Preview
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Apply -Client Selected
   ```

7. Show authentication commands and complete the easiest routes first:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Dashboard
   ```

   Prioritize no-auth and browser-OAuth tools before tools requiring cloud/IAM work. Open login flows directly when possible.

8. Reload only clients that cannot discover newly applied MCPs, then inspect status:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Status
   ```

9. Run the selected catalog entry's `testPrompt`. Identify the connected account, property, container, project, dataset, site, or workspace without exposing unnecessary data.

10. Record factual evidence after each successful stage:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action RecordEvidence -ToolName <catalog-key> -Stage Authenticated -Outcome Passed -Target "<account or project>" -Evidence "Browser OAuth completed with the intended company account"
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action RecordEvidence -ToolName <catalog-key> -Stage Visible -Outcome Passed -Target "<AI client>" -Evidence "Expected MCP tools are callable in the current session"
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action RecordEvidence -ToolName <catalog-key> -Stage Verified -Outcome Passed -Target "<resource>" -Evidence "Read-only call returned the expected resource identity"
   ```

   Record failures too. Never put tokens, raw client data, or secrets in evidence.

11. Generate the user handover:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action OnboardingReport
   ```

   Present `generated/onboarding-report.md` and `generated/first-day-checklist.md`. Keep `generated/onboarding-state.json` internal unless asked.

## Provider Decisions

For every selected tool, compare only the catalog's default and applicable fallbacks:

1. Follow company first-party or approved-vendor requirements.
2. Otherwise use the catalog default when its risk and data-exposure metadata are acceptable.
3. Use a fallback only when its `fallbackWhen` condition matches.
4. Explain third-party hosting, write capability, scopes, IAM, and cost exposure before authentication.
5. Do not invent or install an uncataloged provider during onboarding. Verify current primary sources, then update the catalog first.

## Evidence And Resume

Use `Status`, `Dashboard`, and the internal onboarding state to continue from the nearest incomplete stage. Do not restart the entire setup when only a login, client reload, or smoke test is missing.

Treat a provider change as invalidating old evidence. Re-run Apply, authentication where required, visibility checks, and the read-only proof.

## Reset Boundaries

Do not reset after successful real onboarding.

- Use `ResetMcpConfig` only with explicit approval to remove entries proven to be owned by this kit. It preserves unowned and user-modified entries and creates backups.
- Use `ResetKit` after a simulation, before sharing the folder, when leaving a company/client, or when intentionally removing local credentials and generated state. It does not silently delete MCP client configuration.
- Run `ResetMcpConfig` before `ResetKit` when both disconnection and local cleanup are intended.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action ResetMcpConfig -Client Selected -ConfirmedMcpEndpointDeletion
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action ResetKit
```

## Maintenance

Keep provider maintenance catalog-driven. Before a release, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Validate
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action TestFixtures
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action PesterTests
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action CatalogReview
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action ReleaseAudit
```

Inspect the tracked release archive for credentials, personal paths, local IDs, and generated state before publishing.
