# Web Analyst MCP Setup

[![Validate kit](https://github.com/haiqigeng/web-analyst-mcp-setup/actions/workflows/validate.yml/badge.svg)](https://github.com/haiqigeng/web-analyst-mcp-setup/actions/workflows/validate.yml)
[![Latest release](https://img.shields.io/github/v/release/haiqigeng/web-analyst-mcp-setup?sort=semver)](https://github.com/haiqigeng/web-analyst-mcp-setup/releases/latest)
[![License](https://img.shields.io/github/license/haiqigeng/web-analyst-mcp-setup)](LICENSE)

Version: 1.5.0

A Windows-first onboarding skill that helps Codex, Claude Code, Gemini CLI, and similar agents connect and verify the tools a web analyst needs on a new company PC.

The project handles tool selection, machine checks, provider decisions, prerequisites, credential guidance, MCP configuration, browser authentication, session reloads, read-only verification, handover, and safe cleanup. Provider-specific requirements live in the [MCP catalog](config/mcp-catalog.json), so the workflow can evolve without duplicating instructions.

## Start

Open the project folder in an AI coding agent and say:

```text
Read AGENTS.md and guide me through the web analyst setup.
```

Codex can also discover the repository as a skill when it is installed under its skills directory:

```powershell
git clone https://github.com/haiqigeng/web-analyst-mcp-setup.git "$env:USERPROFILE\.codex\skills\web-analyst-mcp-setup"
```

Then invoke it with:

```text
Use $web-analyst-mcp-setup to configure my selected web analyst tools.
```

The latest ZIP is also available from [GitHub Releases](https://github.com/haiqigeng/web-analyst-mcp-setup/releases/latest).

## What It Does

The guided first-day flow:

1. Selects AI clients and only the tools needed now.
2. Inspects Windows, installed prerequisites, browsers, and existing MCP configuration.
3. Chooses an approved provider and credential route from the catalog.
4. Installs only prerequisites required by those choices.
5. Checks current MCP packages and records exact local versions for reproducible launches.
6. Previews configuration changes, backs up existing files, and applies only kit-owned entries.
7. Opens or guides the required login flows.
8. Verifies configuration, authentication, current-session visibility, and a harmless read-only call separately.
9. Records human-verifiable evidence and produces a concise handover report and checklist.

Near-functional MCPs are completed first. Tools requiring longer Google Cloud, IAM, or vendor-admin work remain clearly listed with their next action rather than blocking the rest of onboarding.

The current tool and provider inventory, including officialness, runtime, authentication, data exposure, write capability, risk, lifecycle, and upstream source, is maintained in [`config/mcp-catalog.json`](config/mcp-catalog.json).

## Safety Model

- Read-only smoke tests are the default.
- Delete, revoke, reset, deploy, publish, send, edit, and costly-query actions require explicit approval for the exact target.
- `Apply -Preview` shows client paths and MCP names before configuration changes.
- Existing client files are backed up before Apply or managed reset.
- Unowned MCP names cause a collision error instead of being overwritten.
- Reset removes only entries whose ownership can be proven; user-modified or unrelated entries are preserved.
- Local MCP processes receive only the environment keys declared for their selected tool and provider.
- Credentials, tokens, package locks, evidence, reports, backups, and machine-specific paths remain ignored by Git.
- Third-party hosted MCPs must be disclosed before connecting company data.

See [Data and Credential Safety](docs/data-and-credential-safety.md) for details.

## User-Facing Outputs

- `generated/onboarding-report.md`: configuration status, credential-key state, recorded verification proof, and handover notes.
- `generated/first-day-checklist.md`: prioritized next actions and safe smoke tests.
- `generated/credential-guide.md`: direct setup URLs generated only when credentials are missing.
- `generated/bigquery-safety-plan.md`: optional dry-run and cost-safety checklist.
- `generated/mcp-update-check.md`: package resolution, endpoint reachability, and catalog freshness evidence.

Internal runtime files such as `generated/onboarding-state.json`, `generated/mcp-version-lock.json`, and the external ownership record are for agents and scripts. They are not primary user documents and are never released.

## Project Structure

- `SKILL.md`: installable skill workflow and safety contract.
- `agents/openai.yaml`: Codex skill-list metadata.
- `AGENTS.md`: lightweight compatibility entry for agents that discover repository instructions.
- `scripts/WebAnalystSetup.ps1`: Windows setup and configuration engine.
- `scripts/lib/`: focused reporting, audit, checklist, and test helpers.
- `config/mcp-catalog.json`: provider source of truth.
- `config/client-capabilities.json`: supported client targets and client-specific MCP configuration behavior.
- `config/tool-selection.example.json`: clean template copied to ignored local selection.
- `config/tool-profiles.json`: dormant/manual profile scaffolding, not used by default onboarding.
- `secrets/.env.template`: clean template copied to ignored local credentials.
- `schemas/`: reusable and runtime JSON contracts.
- `tests/`: behavior, safety, compatibility, and fixture tests.
- `.github/workflows/validate.yml`: Windows PowerShell and PowerShell 7 validation.

## Manual Recovery Commands

The agent normally runs these commands. They remain available for debugging or recovery:

```powershell
# Prepare, inspect, and guide credentials
.\scripts\WebAnalystSetup.ps1 -Action Prepare
.\scripts\WebAnalystSetup.ps1 -Action Doctor
.\scripts\WebAnalystSetup.ps1 -Action CredentialGuide

# Install prerequisites and resolve exact MCP versions
.\scripts\WebAnalystSetup.ps1 -Action Prereqs
.\scripts\WebAnalystSetup.ps1 -Action CheckMcpUpdates

# Preview and apply only to clients selected locally
.\scripts\WebAnalystSetup.ps1 -Action Apply -Client Selected -Preview
.\scripts\WebAnalystSetup.ps1 -Action Apply -Client Selected

# Authenticate, inspect, and report
.\scripts\WebAnalystSetup.ps1 -Action Dashboard
.\scripts\WebAnalystSetup.ps1 -Action Status
.\scripts\WebAnalystSetup.ps1 -Action OnboardingReport
```

Record a successful read-only proof:

```powershell
.\scripts\WebAnalystSetup.ps1 -Action RecordEvidence `
  -ToolName googleAnalytics `
  -Stage Verified `
  -Outcome Passed `
  -Target "Company GA4 property" `
  -Evidence "Account summaries returned the intended property"
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
.\scripts\WebAnalystSetup.ps1 -Action TestFixtures
.\scripts\WebAnalystSetup.ps1 -Action PesterTests
.\scripts\WebAnalystSetup.ps1 -Action CatalogReview
.\scripts\WebAnalystSetup.ps1 -Action ReleaseAudit
```

The release audit scans tracked files and the exact Git archive for credentials, personal paths, generated runtime state, and forbidden local files. See [Contributing](CONTRIBUTING.md), [Security](SECURITY.md), and the [Changelog](CHANGELOG.md).
