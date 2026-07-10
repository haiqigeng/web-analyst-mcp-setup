# Data and Credential Safety

This kit is designed for first-day onboarding on a new company PC. Its default posture is to connect only the tools the user chooses, prefer approved company credentials, and keep generated tokens out of the reusable repository.

## Local Versus Remote MCPs

Local MCPs run on the PC and call vendor APIs from that machine. They can still access account data after OAuth, but data is not intentionally routed through a third-party hosted MCP server.

Remote MCPs are hosted by the vendor or a third party. They are easier to connect when OAuth is handled by the provider, but the MCP provider may process request metadata, prompts, tool calls, or returned data according to its own terms.

Before connecting a company account to a remote MCP, confirm whether the provider is first-party, third-party, or an approved managed-auth broker.

## Credential Rules

- Use credentials explicitly approved for the current company or client.
- Do not reuse credentials from a previous employer, agency, or client.
- Prefer browser OAuth when available because the user can see and revoke the connection.
- Store local secrets only in ignored files such as `secrets/.env.local`.
- If a team prefers not to place raw values in `secrets/.env.local`, use the supported `KEY_FILE` pattern from `secrets/.env.template`. Keep the main key empty, point `KEY_FILE` to an ignored local file, and let the helper read the secret at runtime.
- Never commit OAuth client secrets, access tokens, refresh tokens, API keys, service-account JSON files, or generated MCP config containing machine paths.
- Treat token-file presence as incomplete. A connection is ready only after a harmless read-only smoke test passes.
- Resolve floating package metadata into `generated/mcp-version-lock.json` before launching local MCPs. Reuse the exact locked version until the next deliberate update check.
- Preview Apply targets, preserve unrelated configuration, and keep the generated backup until the connection has been verified.
- During MCP setup, never delete, reset, revoke, publish, deploy, or otherwise change MCP endpoint/server/container/project-facing state without explicit approval. State the exact target ID/name and action before doing it.

## Scope Rules

Ask for the narrowest practical scope:

- Drive: prefer read-only unless file creation or editing is explicitly needed.
- Gmail: avoid send/delete flows unless the user explicitly asks for them.
- GTM: read/list and preview first; publish only after explicit confirmation.
- GA4: read-only reporting/admin discovery by default.
- BigQuery: metadata or limited read-only queries first; confirm cost and dataset scope before broad SQL.
- Browser tools: warn before using logged-in, internal, or sensitive pages.

## Company IT Talking Points

For IT or data teams, explain the request in terms of:

- Which tools need access.
- Whether the MCP is local, first-party remote, third-party remote, or direct API.
- The minimum OAuth scopes or IAM roles needed.
- Whether write actions are possible and how the user will confirm them.
- Where tokens are stored and how they can be revoked.
- Whether the setup is for one user, one client, or a team-wide onboarding pattern.

## Revocation

Most OAuth connections can be revoked from the vendor account security page. Remove kit-owned MCP client entries only after explicit approval:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action ResetMcpConfig -Client Selected -ConfirmedMcpEndpointDeletion
```

Then remove local ignored credentials and generated state with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action ResetKit
```

Do not run either reset immediately after real onboarding. `ResetKit` does not delete MCP client configuration; this prevents a share/compression cleanup from silently disconnecting a real workstation.

## Release Safety

Before sharing or publishing the reusable kit, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action ReleaseAudit
```

The audit validates reusable files, checks tracked files for common token and machine-specific patterns, and builds a git archive from tracked files. It does not include ignored local setup files.
