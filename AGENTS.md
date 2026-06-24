# Web Analyst Setup Agent

This file is for the agent, not for the user. Follow it quietly.

This folder is a reusable Windows-first setup kit for daily web analyst work in Codex, Claude Code, Gemini CLI, and similar MCP-capable agents.

The goal is first-day success on a new company PC: install prerequisites, configure the selected tools, and actually connect to the accounts the user needs. Prefer a working, approved onboarding route over a theoretically cleaner MCP that cannot authenticate in the selected client yet.

Use `scripts/WebAnalystSetup.ps1` as the deterministic layer for Windows prerequisites, profiles, validation, diagnostics, MCP config generation, status checks, Google OAuth helper files, onboarding reports, and resets. Keep agent prose for choices, credentials, and guided browser/vendor-console steps.

Use `config/client-capabilities.json` when deciding where to write MCP configuration, whether project/user config is supported, and whether the selected client is likely to need a restart or MCP login command.

## User Action Policy

- If a task can be done with local tools, do it.
- If a choice, path, account name, credential, or confirmation is needed, ask briefly, then apply it yourself.
- Do not ask the user to edit JSON, TOML, Markdown, or `.env` files as the normal path.
- Manual file editing is only a privacy fallback for secrets the user does not want to paste into chat.
- Prefer browser/login auth over static secrets when a selected MCP supports it.
- Prefer well-known, easy-to-run Node.js MCP providers as the first option when trust and security are acceptable. Keep official, Python, or heavier enterprise routes as fallbacks when they are harder to authenticate on day one. GA4 is the current exception: use only the official Google Analytics MCP until the user explicitly asks to add another GA4 provider.
- Prefer credentials explicitly provided by the current company over asking the user to create a new Google Cloud project.
- If the company approves a managed-auth MCP broker, prefer that over asking the user to create a personal Google Cloud project.
- Before installing or applying MCP config, run the MCP update check and use the latest package version for npm-based MCPs unless the catalog explicitly documents a temporary pin.
- When a user or company does not want raw secrets in `secrets/.env.local`, use the supported `KEY_FILE` pattern from `secrets/.env.template`: write or receive an ignored local file path, keep the main key empty, and let the helper read the secret from that file.
- Never reuse credentials from a previous employer or agency for a new company.
- Do not ask the user to add an `iam.gserviceaccount.com` email unless they explicitly confirm an approved service-account setup for a tool outside the current GA4 flow.
- Tell the user before routing work data through third-party hosted MCPs or managed-auth brokers.
- Keep one-off mailbox, Drive, or client-data cleanup outside the reusable kit. The kit's purpose is first-day setup and successful connection to daily analyst tools.
- Treat "token file exists" as incomplete. Run the kit status check or a lightweight tool test before telling the user a connection works.
- Treat setup as four separate states: MCP config written, account authenticated, tool visible in the current AI session, and a harmless test passed.
- During setup smoke tests, stay read-only by default. Do not send email, delete files, publish containers, edit tags, move messages/files, run costly SQL, or change vendor settings unless the user explicitly asks for that action.
- During MCP setup only, never delete, remove, reset, revoke, publish, deploy, or otherwise change MCP endpoint/server/container/project-facing state unless the user explicitly approves it. State the exact target ID/name and action before execution.
- After changing MCP config, check whether the active AI client can reload MCP servers. If not, tell the user a restart is needed before the current conversation can use the new tools.
- Before relying on a hosted remote MCP URL from docs, test DNS and a basic HTTP/OAuth-discovery response. If the endpoint is dead or not an MCP endpoint, mark it unavailable instead of continuing the setup path.
- Run `Validate` before changing reusable kit files or preparing a release.
- Before a release, run `Validate`, `TestFixtures`, `CatalogReview`, and `ReleaseAudit`. Do not create a release if any command fails or if git shows unexpected tracked local state.
- Run `Doctor` at the start of first-day setup when the user wants a machine readiness check.
- End real onboarding with `OnboardingReport` unless the user says not to create local generated reports. This also writes the first-day checklist.

## First-Day Setup Model

Run the kit as an onboarding workflow, not as a package installer. Keep the user inside the conversation as much as possible.

1. Intake: identify AI client, selected tools, company/client context, policy constraints, and whether approved credentials or a vault item exist.
2. Tool selection: choose tools directly with the user and write `config/tool-selection.json`. Do not use profiles in the default execution flow yet.
3. Preflight: run `Doctor`, then inspect Windows version, shell, PATH, existing Node/npm/Git/Python/gcloud, installed/default browser, and existing MCP client config before installing anything.
4. Credential route: choose the lowest-friction approved route for each selected tool: browser OAuth, company OAuth client, vendor token, managed broker, or last-resort Google Cloud setup.
5. Minimal install: install only prerequisites required by the selected providers. Prefer Node for day-one local MCPs, but allow official non-Node providers when trust matters more than convenience.
6. Configure: write MCP config for the selected AI client, and keep generated config, secrets, tokens, and machine-specific paths out of reusable files.
7. Authenticate: open the relevant browser/login flow or guide the single external console step needed, then return to the conversation.
8. Session reload: confirm whether the current AI client can see newly configured MCPs; restart only when the client cannot reload them.
9. Verify: perform a harmless read-only smoke test per selected tool and identify the connected account, property, container, dataset, or site when possible.
10. Handover: run `OnboardingReport`, summarize the configuration status per MCP, what is ready, what still needs company approval, what needs client reload, and what not to touch without explicit permission. Treat `generated/onboarding-report.md` and `generated/first-day-checklist.md` as user-facing local files. Treat `generated/onboarding-state.json` as internal resume state for agents/scripts and do not present it as a user document unless the user asks.
11. Retention or reset: after real onboarding, keep local credentials/tokens so the tools continue working. Run reset only after a test, when leaving a company/client, or when preparing the folder for reuse on another PC.

## Connection Strategy

Use `config/mcp-catalog.json` as a living catalog. Choose the path most likely to connect successfully on day one, then keep official or future alternatives in notes. For tools with multiple providers, set `tools.<tool>.provider` in `config/tool-selection.json`; the setup script resolves that provider when generating MCP config.

Use catalog decision metadata when explaining provider choices:

- `officialness`: first-party, trusted third-party, candidate, private beta, or direct API.
- `lifecycleStatus`: default, fallback, optional, candidate, private beta, API fallback, or deprecated.
- `recommendedUse`: when this provider should be selected.
- `fallbackWhen`: conditions that justify this provider.
- `knownLimitations`: operational or trust limits to mention before setup.
- `authFriction`: expected first-day setup difficulty.
- `runtime`: Node, Python, remote, or direct API.
- `dataExposure`: where tool calls and returned data travel.
- `writeCapability`: whether write actions, browser actions, or query costs are possible.
- `riskLevel`: operational risk for company onboarding.
- `lastVerified`: date the provider entry was last checked.

- Google Drive: default to provider `google-drive-local-node-fallback` with `@piotr-agier/google-drive-mcp@latest` for a practical Node/browser-login first-day setup. Offer provider `google-drive-official-remote` when the selected client supports custom Google OAuth client credentials and the company prefers Google's official remote Developer Preview route.
- Gmail: default to provider `gmail-local-node-fallback` with `@gongrzhe/server-gmail-autoauth-mcp@latest` for a practical Node/browser-login first-day setup. Offer provider `gmail-official-remote` when the selected client supports custom Google OAuth client credentials and the company prefers Google's official remote Developer Preview route.
- Google Tag Manager: Stape remote OAuth MCP through `mcp-remote https://gtm-mcp.stape.ai/mcp`. Tell the user it is hosted by Stape before connecting sensitive accounts.
- GA4: use only the official Google Analytics MCP provider `googleanalytics-official-adc` with `analytics-mcp` through `pipx`. Authenticate with Google ADC/browser login using the user's own Google account and approved company OAuth credentials when available. Do not add another GA4 provider unless the user explicitly asks.
- Browser QA: official Playwright MCP. Use it as the default browser automation route for journeys, consent checks, ecommerce paths, forms, screenshots, and repeatable QA. The setup helper should detect the Windows default or installed browser and prefer Edge/Chrome/Brave/Firefox launch args before asking to install a new browser.
- Browser Debug: official Chrome DevTools MCP. Treat it as optional/advanced for console, network, screenshots, performance traces, and DevTools-level investigation. It can use Chrome or a compatible Chromium browser such as Edge via an executable path. Tell the user before using it on logged-in or sensitive pages because browser content is exposed to the MCP client.
- BigQuery: official Google Cloud remote BigQuery MCP when the company approves MCP/IAM access. Confirm project, dataset, region if needed, and least-privilege roles before analysis. If Codex remote OAuth cannot register dynamically, offer the short-term ADC bearer-token route from `BigQueryAdcBearerToken` and warn that it expires quickly and requires client reload. Use Google MCP Toolbox for Databases as the fallback when the company requires local control, parameterized tools, or allowlisted queries.
- ClickUp: official remote MCP when OAuth works in the selected client.
- Trello: current third-party MCP candidate because no clear first-party Trello MCP was found.
- Piano Analytics: official private-beta MCP when the user is whitelisted; otherwise use the Piano API connector option.
- Contentsquare: official MCP using the URL shown in Contentsquare > Analysis setup > Model Context Protocol.
- Tag Commander / Commanders Act: API connector until a trusted public MCP is supplied.

Provider decision rules:

1. If the company mandates first-party-only, use official providers even when they take longer.
2. If the user has no policy constraint, start with the catalog default: well-known, easy day-one, Node-first where credible.
3. If the default cannot authenticate cleanly, switch only to a documented fallback whose `fallbackWhen` condition matches the situation, then explain the tradeoff and known limitations.
4. Do not invent a new MCP during setup. Search current sources first, then update `config/mcp-catalog.json` before using it.

After each authentication step, run `Status` and one lightweight read-only test. Report the connected account/project when the tool exposes it, any missing scope/API issue, and whether the tool is local, remote, or API-token based.

For each enabled tool, report progress using this vocabulary:

- `Configured`: the MCP/API entry was written to the selected client config.
- `Authenticated`: the user completed OAuth or supplied the required approved credential.
- `Visible`: the active AI client can list or call the MCP tools in the current session.
- `Verified`: a read-only smoke test passed and the target account/project/container/site was identified.

Always prioritize the nearest-to-functional MCPs first. Complete browser-auth or no-auth tools such as GTM, Browser QA, and Browser Debug before spending time on tools that need longer Google Cloud or IAM work such as GA4 or BigQuery, unless the user asks otherwise.

## Activation Flow

Ask one compact group of questions first:

```text
Which clients should I configure: Codex, Claude Code, Gemini CLI?

Which tools do you want enabled now: Gmail, Drive, GTM, GA4, BigQuery, Browser QA, Browser Debug, ClickUp, Trello, Piano, Piano API connector, Tag Commander, Contentsquare?

Is this personal, agency/team-wide, or for one client/project?

Do you have an approved company onboarding credential pack or vault item for these tools, especially Google OAuth client ID/secret?

If there is no Google OAuth client in the company pack, are company-approved managed-auth brokers allowed for Google tools, for example Pipedream, Composio, Arcade, Workato, or StackOne?

For Google Drive/Gmail, does the company require first-party Google remote MCPs, or can I use the well-known local Node MCP defaults if they are easier to connect on day one?

For GA4, do you have an approved Google OAuth client JSON/client ID and secret for ADC browser login, or should I guide you through the Google Cloud checklist when we reach GA4?
```

After the user answers, update `config/tool-selection.json` yourself. If it does not exist, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Prepare
```

Profiles exist only as dormant/manual scaffolding for future standard bundles. Do not apply a profile during normal setup unless the user explicitly asks to test profile behavior.

## Setup Steps

### 1. Prepare Local Files

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Prepare
```

This creates or updates ignored local files:

- `config/tool-selection.json`
- `secrets/.env.local`

Tell the user which selected tools still need account login, a path, URL, or credential. Do not print secret values.

If selected tools need company approval, explain the missing credential or access in the conversation. If the user asks for a formal request, draft it directly from the selected tools and current configuration status.

If Google or vendor credentials are missing, generate the on-demand credential guide and use its direct URLs in the conversation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action CredentialGuide
```

Run diagnostics before installing prerequisites:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Doctor
```

For first-day company setup, ask for credentials in this order:

1. Company-provided Google OAuth client ID and secret.
2. Vendor OAuth login flow exposed by the MCP.
3. Company-approved managed-auth broker for Google tools when it avoids a new Cloud project.
4. Vendor API token from the company's approved vault.
5. New Google Cloud project/OAuth app only if the company has not provided credentials, no approved managed-auth route exists, and the user has permission to create one.

### 2. Install Prerequisites

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Prereqs
```

The helper checks Node.js, npm, Git, and only installs Python/pipx or Google Cloud CLI when the selected providers need them.

### 3. Check MCP Updates

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action CheckMcpUpdates
```

For local Node MCPs, the helper checks npm metadata and the catalog should use `@latest`. For remote MCPs, report that the server is updated by the provider. For Python/pipx fallbacks, verify upstream before selecting that provider.

Use the generated `generated/mcp-update-check.md` as user-facing evidence when explaining package freshness, remote endpoint reachability, or stale catalog verification dates.

When modifying reusable kit files or preparing a release, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Validate
```

### 4. Configure MCPs

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Apply -Client All
```

Use `-Client Codex`, `-Client Claude`, or `-Client Gemini` when the user chose only one client.

For Codex, remote MCPs should be written as HTTP `url` entries in `~/.codex/config.toml`. Local MCPs should use the PowerShell launcher.

### 5. Authenticate

Run this to print the dashboard in the conversation/terminal:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Dashboard
```

Then start the easiest available auth flow.

For Google Drive and Gmail local Node defaults, save the current company's approved Google OAuth client ID and secret in `secrets/.env.local` without printing the secret, run `GoogleOAuthFile`, then run the dashboard auth command and let the user sign in with their own current-company Google account in the browser.

If the company requires Google's official remote MCP route, switch the provider in `config/tool-selection.json` to `google-drive-official-remote` or `gmail-official-remote`. Confirm the selected MCP client can use custom OAuth client ID/secret with remote MCP servers, then use the client's login/custom-connector flow.

For local Google Drive and Gmail browser auth, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action GoogleOAuthFile
```

Run the local Drive/Gmail auth commands from the dashboard and let the user sign in with their own current-company Google account in the browser. If the company does not provide OAuth credentials, ask about an approved managed-auth broker or native connector before considering a new Google Cloud project.

For Codex remote MCPs, run the login command when available:

```powershell
codex mcp login bigquery
codex mcp login clickup
codex mcp login contentsquare
```

For GTM, use the Stape remote OAuth MCP. Tell the user it is hosted by Stape before connecting sensitive accounts.

For GA4, use the official Google Analytics MCP only. Prefer the same approved company Google OAuth client ID/secret used for Drive/Gmail, then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action GoogleAdcLogin
```

Save the detected credentials path as `GOOGLE_APPLICATION_CREDENTIALS` in `secrets/.env.local`, then run `Apply`, `Status`, and a minimal read-only report or `get_account_summaries` test.

For Browser QA, no account credential is required by default. Install/configure it with the selected MCP client, then test on a public page before using it on company systems. If Chrome is missing, do not install Chrome first; detect the default/installed browser and configure Playwright with `--browser msedge`, `--browser chrome`, or `--executable-path` when appropriate.

For Browser Debug, no account credential is required by default, but it can inspect pages, console logs, network requests, screenshots, and performance traces. Ask before using it on logged-in, internal, or sensitive pages. Usage statistics are disabled by default in this kit. If Chrome is missing, configure Chrome DevTools MCP with a compatible Chromium executable path such as Microsoft Edge before asking to install Chrome.

For BigQuery, use the official remote MCP first. Ask for the approved Google Cloud project ID, dataset IDs, and whether the user has these or equivalent least-privilege roles: MCP Tool User, BigQuery Job User, and BigQuery Data Viewer. Use browser OAuth from the MCP client when available. Start with metadata listing or a small read-only query; confirm before running costly or broad queries. If remote MCP is blocked by policy or the company wants allowlisted/parameterized tools, use Google MCP Toolbox for Databases as the fallback plan.

Before any real BigQuery SQL work, generate the BigQuery safety plan:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action BigQuerySafetyPlan
```

Use it to confirm project, dataset, region, date filters, dry-run/estimate behavior, and cost guardrails. Do not run broad or costly queries without explicit approval.

### Google Cloud Last-Resort Checklist

Do not start here. Use this only when the company has not provided OAuth credentials, no approved broker/native route exists, and the user has permission to create or configure a Google Cloud project.

Guide the user interactively instead of relying on frozen click-by-click console text. Google Console labels move over time; use current official Google docs/links when a screen is unclear.

1. Create or select a Google Cloud project for this company/client.
2. Enable only the APIs needed by selected tools. For local third-party Drive/Gmail MCPs, the user grants scopes during browser OAuth, but the underlying Google APIs such as Drive, Docs, Sheets, Slides, Calendar, or Gmail may still need to be enabled on the OAuth project.
3. Configure Google Auth Platform / OAuth consent for the appropriate audience. This defines who may sign in to the OAuth app and which scopes the app is allowed to request; it is different from IAM roles.
4. Create an OAuth client ID for a desktop/installed app when using local browser OAuth helpers. The MCP browser login uses the client ID/secret plus the user's own Google account.
5. Configure IAM only for tools that access Google Cloud resources such as BigQuery, or where the official MCP documentation explicitly requires IAM roles. IAM does not replace OAuth scopes for Gmail/Drive browser login.
6. Copy only the client ID and client secret into `secrets/.env.local`; do not paste them into docs or generated config.
7. Run `GoogleOAuthFile`, then run the relevant browser auth command or `GoogleAdcLogin`.
8. Run `Status` and one lightweight read-only tool test before declaring the connection ready.

If APIs can be enabled via `gcloud` and the user has the needed project permission, do that from the conversation. Otherwise ask the user to perform only the specific Console step needed, then continue setup.

For Piano Analytics, ask whether the user is whitelisted for the private beta. If yes, collect `PIANO_ACCESS_KEY` and `PIANO_SECRET_KEY` for the MCP. If no, use `pianoAnalyticsApi` and collect the API connector values.

For Contentsquare, ask the user to open Contentsquare > Analysis setup > Model Context Protocol and provide the MCP URL. Save it as `CONTENTSQUARE_MCP_URL`, then run the MCP client OAuth login.

## Reset For Testing Or Reuse

Do not run reset automatically after a successful real company onboarding. The local credentials and tokens are needed for day-to-day work.

Run reset only when the user says the test is over, they are leaving a company/client, they want to compress/share the reusable kit, or they want a fresh first-day simulation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action ResetKit
```

This removes ignored local state such as `secrets/.env.local`, `config/tool-selection.json`, generated MCP snippets, and local secret JSON/token files. It keeps the reusable docs, script, catalog, and templates.

It also removes known kit-owned Google OAuth/token JSON files under `%USERPROFILE%\.web-analyst-agent`, so the folder can be compressed or reused without carrying the current PC/company connection forward.

If the user also wants Codex MCP entries removed from the current PC, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action ResetCodexMcp -ConfirmedMcpEndpointDeletion
```

This removes only the Web Analyst MCP block and server names known to this kit, then leaves other Codex settings alone. During MCP setup, obtain explicit approval and state the exact MCP config targets before running it.

### 6. Test

Ask the user to restart the selected AI client only when the client cannot reload MCP config.

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Status
```

`Status` should check more than local file presence when possible: token scope, token expiry, and a lightweight API reachability call for Google Drive and Gmail.

Then test lightly from the active AI client:

| Tool | Lightweight test |
| --- | --- |
| Google Drive | Treat it as Google Workspace: list 5 recent files, then check one Docs item, one Sheets item, one Slides item when available, and Calendar visibility when that scope/API is selected. |
| Gmail | List labels. |
| GTM | List accounts or containers. |
| GA4 | List GA4 accounts/properties or run a minimal read-only report. |
| BigQuery | List accessible datasets or run a small metadata/read-only query. |
| Browser QA | Open a public page and report the page title. |
| Browser Debug | Open a public page and list console errors or key network requests. |
| ClickUp | List workspaces. |
| Trello | List boards. |
| Piano MCP | Ask for a simple traffic summary. |
| Piano API connector | Prepare and verify a Data Query request plan. |
| Contentsquare | List available projects. |

After verification, write a local ignored report:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action OnboardingReport
```

Use `generated/onboarding-report.md` as a handover summary for the user. Do not commit it.

`OnboardingReport` also writes `generated/onboarding-state.json`. This is internal resume state for agents/scripts, not a primary user-facing document.

`OnboardingReport` also writes `generated/first-day-checklist.md`. Use this checklist as the concise day-one action list: ready smoke tests, missing credentials, login/token checks, approval-sensitive actions, and safety reminders.

## Release And Maintenance

When changing reusable kit files, keep changes catalog-driven where possible:

- Update `config/mcp-catalog.json` for MCP/API provider choices.
- Keep `config/tool-profiles.json` dormant until profile-to-MCP choices are intentionally designed and tested.
- Update `config/client-capabilities.json` when a client adds or changes MCP config behavior.
- Update `tests/fixtures/profile-server-names.json` whenever profile MCP server names intentionally change.

Before publishing a release, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action Validate
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action TestFixtures
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action PesterTests
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action CatalogReview
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\WebAnalystSetup.ps1 -Action ReleaseAudit
```

Then check `git status --short --ignored` and scan the tracked tree for local names, credential filenames, OAuth secrets, tokens, project IDs, GTM/GA IDs, and client-specific values before committing or creating a GitHub release.

## Daily Analyst Standards

- Start from the relevant client context file before acting on a client task.
- Label facts, assumptions, and uncertain tool output.
- For GTM, prefer preview/export review before publish instructions.
- For GA4, verify property, date range, timezone, and identity settings before interpreting reports.
- For BigQuery, verify project, dataset, table, region, date partition, cost impact, and whether a read-only query is enough before running SQL.
- For Browser QA, prefer deterministic journeys with explicit URLs, test accounts, and consent state notes.
- For Browser Debug, warn before inspecting sensitive authenticated pages and summarize only what is needed.
- For Piano, check site ID, collection domain, consent state, event order, and data model before proposing fixes.
- For Tag Commander, map container, rules, vendors, consent, and environments before changes.
- For Contentsquare, clarify project, page group, device, segment, and date range before analysis.
- For Gmail drafts, use the user's style profile when available.
- Store summaries, source links, and decisions. Do not store unnecessary personal data or raw secrets.
