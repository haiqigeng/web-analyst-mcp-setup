# Web Analyst MCP Setup

[![Latest release](https://img.shields.io/github/v/release/haiqigeng/=semver)](https://github.com/haiqigeng/web-analyst-mcp-setup/releases/latest) ![License](https://img.shields.io/github/license/haiqigeng/web-analyst-mcp-setup) ![Top language](https://img.shields.io/github/languages/top/haiqigeng/web-analyst-mcp-setup)

Version: 1.3.0

Windows-first setup kit for daily web analyst work with AI agents such as Codex, Claude Code, and Gemini CLI.

Open this folder in your agent and say:

```text
Read AGENTS.md and guide me through the web analyst setup.
```

The agent should ask a few questions, configure the local files itself, run the setup script, and pause only for browser approval, vendor-console access, or credentials it cannot create for you.

The kit is optimized for first-day setup on a new company PC: use approved company credentials when available, get connected successfully, and keep official/future MCP paths documented without letting them block onboarding.

For Google tools, the order of preference is: company-provided OAuth credentials, vendor/browser OAuth, a company-approved managed-auth broker, then a new Google Cloud project only as a last resort.

Detailed Google Console steps are handled during the setup conversation when needed, using the selected tools and current Google screens. The on-demand credential guide gives direct setup URLs for the selected tools without storing secrets in reusable files.

The kit is for onboarding and connection. One-off mailbox, Drive, or client-data cleanup tasks should stay outside the reusable setup instructions.

During MCP setup, delete/publish actions are deliberately gated: the agent must never delete, reset, revoke, publish, or deploy MCP endpoint/server/container/project-facing state without explicit approval.

## First-Day Flow

The agent should run the setup as a guided onboarding flow:

1. Identify the AI client, selected tools, company context, and credential policy.
2. Select tools directly with the user and write the local ignored `config/tool-selection.json`.
3. Inspect the PC before installing anything.
4. Choose the approved credential route for each selected tool.
5. Install only the prerequisites required by those choices.
6. Write MCP configuration, authenticate, reload the AI client if needed, and run harmless read-only smoke tests.
7. End with user-facing outputs: an onboarding report and a first-day checklist. Internal resume state is generated for agents/scripts, but it is not a primary user document.

Current default paths:

- Google Drive and Gmail: well-known local Node MCP defaults for practical first-day browser login; official Google Workspace remote MCPs remain available when the company requires first-party remote MCPs and the selected client supports custom Google OAuth credentials.
- GA4: official Google Analytics MCP through `analytics-mcp` and Google ADC/browser login.
- Google Tag Manager: Stape remote OAuth MCP.
- BigQuery: official Google Cloud remote BigQuery MCP. When a client cannot complete remote OAuth, the kit can use a short-lived ADC bearer token as a day-one bridge; Google MCP Toolbox for Databases remains the controlled fallback when local/allowlisted query tooling is required.
- Browser QA: official Playwright MCP for journey testing, consent checks, ecommerce paths, forms, screenshots, and repeatable browser interaction. The helper detects installed/default browsers and can use Microsoft Edge instead of requiring Google Chrome.
- Browser Debug: official Chrome DevTools MCP for optional advanced console, network, screenshot, and performance debugging. The helper can launch a compatible Chromium browser such as Microsoft Edge via executable path when Chrome is not installed.
- ClickUp: official remote MCP.
- Trello: current third-party candidate MCP.
- Piano Analytics: official private-beta MCP, plus a Piano API connector fallback.
- Contentsquare: official MCP.
- Tag Commander / Commanders Act: API connector.

Generated files and credentials stay local and are ignored by git. Do not reuse credentials from a previous employer or agency for a new company.

User-facing generated files:

- `generated/onboarding-report.md`: user-facing handover summary.
- `generated/first-day-checklist.md`: user-facing next actions and read-only smoke tests.
On-demand user-facing generated files:

- `generated/credential-guide.md`: direct credential/setup URLs for the selected tools.
- `generated/bigquery-safety-plan.md`: BigQuery dry-run and cost-safety checklist.
- `generated/mcp-update-check.md`: selected MCP package/endpoint freshness check.

The helper also keeps internal resume state for agents/scripts in `generated/onboarding-state.json`; you usually do not need to open it.

Browser Debug can inspect browser content. Use it deliberately on logged-in, internal, or sensitive pages.

See `docs/data-and-credential-safety.md` for the security model. If you need a request for IT, data, analytics engineering, or vendor admins, ask the agent to draft it during the conversation from the selected tools and current blockers.

## Files

Core reusable files:

- `AGENTS.md`: the conversation workflow and analyst operating rules.
- `scripts/WebAnalystSetup.ps1`: the PowerShell helper for prerequisites, MCP config, status, connection commands, Google OAuth helpers, and resets.
- `config/mcp-catalog.json`: MCP/API catalog used by the helper.
- `config/tool-selection.example.json`: default tool choices copied to local ignored `tool-selection.json`.
- `config/tool-profiles.json`: dormant reusable onboarding profiles kept for future standard bundles; the default setup flow does not use them yet.
- `config/client-capabilities.json`: client-specific config targets and reload/login guidance.
- `secrets/.env.template`: copied to local ignored `secrets/.env.local`.
- `schemas/*.schema.json`: schema documentation and validation targets for catalog/selection/profile files.
- `tests/fixtures/profile-server-names.json`: expected MCP server names for reusable profiles.
- `scripts/lib/*.ps1`: focused helper modules for release audit, catalog review, checklist generation, Pester tests, and fixture tests.
- `docs/`: security guidance.
- `.github/workflows/validate.yml`: GitHub Actions validation for releases and pull requests.
- `.gitignore`: keeps credentials and generated machine-specific files out of the reusable kit.

Local runtime files are disposable and ignored by git:

- `config/tool-selection.json`
- `secrets/.env.local`
- `generated/*`
- `.mcp.json`, `.codex/config.toml`, `.gemini/settings.json`

## Manual Commands

These commands are not required in normal use. The agent should run them for you during the conversation. They are kept here as a fallback when you want to debug, rerun a step, or understand what the agent is doing.

- `Prepare`: creates local ignored files from templates.
- `UseProfile`: dormant/manual helper that applies a reusable tool profile to local ignored `config/tool-selection.json`; the default setup flow does not use profiles yet.
- `Validate`: validates reusable kit files, JSON, PowerShell syntax, catalog metadata, profiles, lifecycle metadata, and secret hygiene.
- `Doctor`: prints a first-day readiness report for the machine, local state, prerequisites, browser, and selected tools.
- `CredentialGuide`: writes an ignored credential guide with direct setup URLs for selected tools.
- `BigQuerySafetyPlan`: writes an ignored BigQuery dry-run/cost-safety plan before query work.
- `Prereqs`: checks and installs needed prerequisites such as Node.js, Git, Python/pipx, or Google Cloud CLI depending on selected providers.
- `CheckMcpUpdates`: checks selected MCP packages, remote endpoint reachability, and catalog verification age before install/config generation.
- `Apply`: writes MCP configuration for the selected AI client.
- `Dashboard`: prints enabled tools, missing credentials, and reconnect/auth commands in the terminal.
- `Status`: checks selected tool status, visible MCP client state, and lightweight Google token scope/API reachability where possible.
- `FirstDayChecklist`: writes an ignored action checklist to `generated/first-day-checklist.md`.
- `OnboardingReport`: writes an ignored handover report to `generated/onboarding-report.md`, machine-readable state to `generated/onboarding-state.json`, and the first-day checklist.
- `CatalogReview`: writes an ignored catalog maintainability report to `generated/catalog-review.md`.
- `TestFixtures`: checks reusable profile expectations against `tests/fixtures/profile-server-names.json`.
- `PesterTests`: runs the maintainability test suite in `tests/WebAnalystSetup.Tests.ps1`.
- `ReleaseAudit`: validates the kit, checks tracked files for local state or credential patterns, and builds an audit archive from git.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Prepare
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Validate
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Doctor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action CredentialGuide
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Prereqs
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action CheckMcpUpdates
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action BigQuerySafetyPlan
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Apply -Client Codex
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Dashboard
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action FirstDayChecklist
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action OnboardingReport
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action CatalogReview
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action TestFixtures
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action PesterTests
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action ReleaseAudit
```

Google helper commands:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action GoogleOAuthFile
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action GoogleAdcLogin
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action RefreshGoogleDriveToken
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action BigQueryAdcBearerToken
```

To reset Codex MCP configuration before testing the kit again:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action ResetCodexMcp -ConfirmedMcpEndpointDeletion
```

During MCP setup, the agent should get explicit approval before running that command and state the exact MCP config targets.

To reset the kit itself after a test, before sharing/compressing the reusable folder, or when leaving a company/client:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action ResetKit
```

Do not run `ResetKit` immediately after a successful real onboarding unless you intentionally want to remove the local credentials and tokens that keep the tools working. `ResetKit` removes ignored local state, known kit-owned Google OAuth/token JSON files under `%USERPROFILE%\.web-analyst-agent`, and the short-lived `BIGQUERY_MCP_ACCESS_TOKEN` user/process environment variable, so the folder can be compressed or reused without carrying the current PC/company connection forward.

## Release Safety

Before publishing or sharing the kit, the agent should run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Validate
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action TestFixtures
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action PesterTests
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action CatalogReview
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action ReleaseAudit
```

`ReleaseAudit` checks only tracked files and a git archive, so ignored local credentials and generated reports are not included in the release artifact.
