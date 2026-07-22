# Web Analyst MCP Setup

[![Validate kit](https://github.com/haiqigeng/web-analyst-mcp-setup/actions/workflows/validate.yml/badge.svg)](https://github.com/haiqigeng/web-analyst-mcp-setup/actions/workflows/validate.yml)
[![Latest release](https://img.shields.io/github/v/release/haiqigeng/web-analyst-mcp-setup?sort=semver)](https://github.com/haiqigeng/web-analyst-mcp-setup/releases/latest)
[![License](https://img.shields.io/github/license/haiqigeng/web-analyst-mcp-setup)](LICENSE)

Version: 1.6.0-dev

A Windows-first skill for connecting the tools a web analyst needs on a personal or organization-managed PC.

Its North Star is explicit: **Achieve first-day setup success on any Windows PC: with minimal user effort, install only the required prerequisites, configure the selected web-analyst tools, and verify access to the intended accounts or resources through a working route approved by the user and, when organizational data or accounts are involved, permitted by the organization.**

Device ownership and account governance are separate: a personal PC can access organizational accounts, and an organization-managed PC can access personal accounts. Organizational-policy questions are asked only when the selected account, data, or provider makes them relevant.

## Start

Ask naturally:

```text
Use $web-analyst-mcp-setup to connect GTM, GA4, and Playwright in Codex.
```

Codex can also discover the repository as a skill when it is installed under its skills directory:

```powershell
git clone https://github.com/haiqigeng/web-analyst-mcp-setup.git "$env:USERPROFILE\.codex\skills\web-analyst-mcp-setup"
```

The agent runs the PowerShell commands and handles internal selection, configuration, and evidence files. The user approves one compact connection plan, completes browser login or unavoidable account-side steps when required, and receives one result summary. If the user asks for "everything," the agent recommends the smallest set for the work needed today rather than installing the full catalog.

For direct PowerShell use, preview first:

```powershell
.\scripts\WebAnalystSetup.ps1 -Action Connect -Tools gtm,ga4,playwright -Client Codex
```

After approving the displayed provider, prerequisite, and configuration plan:

```powershell
.\scripts\WebAnalystSetup.ps1 -Action Connect -Tools gtm,ga4,playwright -Client Codex -Confirmed
```

Without `-Confirmed`, Connect does not install prerequisites or change MCP client configuration.

## What It Does

The guided first-day flow:

1. Accepts friendly tool names and detects the target AI client.
2. Shows the selected provider, data route, authentication method, risk, prerequisites, and intended client changes.
3. Installs only selected prerequisites after confirmation and records exact MCP versions.
4. Backs up client configuration and changes only kit-owned entries.
5. Completes OAuth or the current credential/IAM step only when needed.
6. Verifies the intended account, property, container, project, dataset, site, or workspace with a minimal read-only call.
7. Produces one concise result with each tool's target and next action.

Near-functional MCPs are completed first. Tools requiring longer Google Cloud, IAM, or vendor-admin work remain clearly listed with their next action rather than blocking the rest of onboarding.

The current tool and provider inventory, including officialness, runtime, authentication, data exposure, write capability, risk, lifecycle, and upstream source, is maintained in [`config/mcp-catalog.json`](config/mcp-catalog.json).

### Provider terms

- **Catalog default**: the maintained preferred route after balancing utility, support, authentication friction, and risk. It may be first-party or a vetted third party.
- **First-party**: maintained by the service or tool owner. Use it when policy requires it or the additional setup is justified.
- **Fallback**: an alternative used only when its cataloged condition matches the real blocker.

## Safety Model

- Read-only smoke tests are the default.
- Delete, revoke, reset, deploy, publish, send, edit, and costly-query actions require explicit approval for the exact target.
- Connect previews client paths and MCP names before any configuration change; `-Confirmed` is required to mutate.
- Existing client files are backed up before Apply or managed reset.
- Unowned MCP names cause a collision error instead of being overwritten.
- Reset removes only entries whose ownership can be proven; user-modified or unrelated entries are preserved.
- Local MCP processes receive only the environment keys declared for their selected tool and provider.
- Credentials, tokens, package locks, evidence, reports, backups, and machine-specific paths remain ignored by Git.
- Third-party hosted MCPs must be disclosed before connecting account data; organizational permission must also be confirmed when organizational data or accounts are involved.

See [Data and Credential Safety](docs/data-and-credential-safety.md) for details.

## Result

`generated/setup-summary.md` is the single user-facing handover. It reports each selected tool as **Verified**, **Ready to verify**, or **Blocked**, plus the connected target and one next action.

Evidence state, exact package locks, catalog checks, credential guidance, BigQuery safety planning, and ownership records remain internal or on-demand. They are ignored by Git and are never release artifacts.

## Project Structure

- `SKILL.md`: installable skill workflow and safety contract.
- `agents/openai.yaml`: Codex skill-list metadata.
- `AGENTS.md`: lightweight compatibility entry for agents that discover repository instructions.
- `scripts/WebAnalystSetup.ps1`: Windows setup and configuration engine.
- `scripts/lib/`: focused connection, audit, and test helpers.
- `config/mcp-catalog.json`: provider source of truth.
- `config/client-capabilities.json`: supported client targets and client-specific MCP configuration behavior.
- `config/tool-selection.example.json`: clean template copied to ignored local selection.
- `secrets/.env.template`: catalog-maintainer defaults; Connect writes selected keys to ignored local credentials and preserves existing non-empty values rather than deleting them.
- `schemas/`: reusable and runtime JSON contracts.
- `tests/`: behavior, safety, compatibility, and first-day acceptance tests.
- `.github/workflows/validate.yml`: Windows PowerShell and PowerShell 7 validation.

## Advanced Recovery

Rerun Connect to resume; passed evidence is preserved and ready tools are not blocked by unfinished ones. Use the granular actions only for diagnosis:

```powershell
.\scripts\WebAnalystSetup.ps1 -Action Doctor
.\scripts\WebAnalystSetup.ps1 -Action Status
.\scripts\WebAnalystSetup.ps1 -Action Dashboard
.\scripts\WebAnalystSetup.ps1 -Action CredentialGuide
```

Remove MCP configuration and local state only when intentionally disconnecting or ending a test:

```powershell
.\scripts\WebAnalystSetup.ps1 -Action ResetMcpConfig -Client Selected -ConfirmedMcpEndpointDeletion
.\scripts\WebAnalystSetup.ps1 -Action ResetKit
```

`ResetKit` alone does not delete MCP client configuration. This prevents a share/compression cleanup from disconnecting a real workstation.

## Development And Releases

Before publishing:

```powershell
.\scripts\WebAnalystSetup.ps1 -Action Validate
.\scripts\WebAnalystSetup.ps1 -Action PesterTests
.\scripts\WebAnalystSetup.ps1 -Action CatalogReview
.\scripts\WebAnalystSetup.ps1 -Action ReleaseAudit
```

The release audit scans tracked files and the exact Git archive for credentials, personal paths, generated runtime state, and forbidden local files. See [Contributing](CONTRIBUTING.md), [Security](SECURITY.md), and the [Changelog](CHANGELOG.md).
