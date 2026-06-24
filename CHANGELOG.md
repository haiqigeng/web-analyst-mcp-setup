# Changelog

## v1.3.0 - Setup guidance, safety, and maintainability

- Added on-demand `CredentialGuide` output with direct setup URLs and selected-tool credential requirements.
- Expanded `CheckMcpUpdates` to report npm/PyPI freshness, remote MCP endpoint reachability, and catalog verification age.
- Added `BigQuerySafetyPlan` for dry-run, max-bytes, project/dataset, and approval guardrails before query work.
- Added provider lifecycle metadata for default, fallback, optional, candidate, private-beta, and API-fallback decisions.
- Added Pester maintainability tests and wired them into CI and release audit.

## v1.2.0 - Cleaner first-day setup flow

- Changed the default onboarding flow to direct tool selection; reusable profiles remain dormant/manual until profile-to-MCP choices are designed.
- Removed the generated access-request helper flow; access requests should now be drafted in conversation only when the user asks.
- Improved MCP status handover with clearer user-facing generated files, configuration status, setup order, and read-only smoke-test reminders.
- Added safer local auth helpers for Drive/Gmail token refresh and BigQuery short-lived bearer-token fallback.
- Clarified reset behavior: keep local credentials after real onboarding, and reset only after tests, client exits, sharing, or fresh simulations.
- Removed stale test-specific safety wording and dead helper code.

## v1.1.1 - First-day checklist patch

- Added `FirstDayChecklist` output in ignored `generated/first-day-checklist.md`.
- Updated `OnboardingReport` to generate the first-day checklist automatically.
- Tightened `ReleaseAudit` so releases fail when reusable files have uncommitted changes.

## v1.1.0 - Release readiness and scalable onboarding

- Added client capability metadata for Codex, Claude Code, and Gemini CLI.
- Added `ReleaseAudit`, `CatalogReview`, and `TestFixtures` actions.
- Added profile fixture checks for expected MCP server names.
- Added generated `onboarding-state.json` alongside the human onboarding report.
- Added optional `KEY_FILE` secret loading so local env files can point to ignored secret files.
- Expanded validation to parse all PowerShell modules and check the new support files.
- Expanded GitHub Actions validation with fixture, catalog, and release-audit checks.

## v1.0.0 - First stable release

- Added self-validation for reusable kit files, catalog metadata, profile references, and secret hygiene.
- Added `Doctor` diagnostics for first-day machine readiness and selected tool state.
- Added `OnboardingReport` generation in ignored `generated/onboarding-report.md`.
- Added reusable tool profiles: `minimal`, `google-workspace`, `analytics-core`, `browser-testing`, and `full-web-analyst`.
- Added catalog decision metadata for maintainability: officialness, auth friction, runtime, data exposure, write capability, risk level, and verification date.
- Added JSON schemas for catalog, tool selection, and profiles.
- Added data/credential safety guidance.
- Added GitHub Actions validation workflow.

## v0.1.0 - Initial release

- Added AGENTS workflow, README quick start, MCP catalog, tool-selection example, secret template, and Windows setup helper.
