# Contributing

Thanks for improving Web Analyst MCP Setup.

This repository is meant to stay practical, safe, and useful for first-day web
analyst onboarding with AI agents. Good contributions usually improve setup
clarity, credential safety, validation scripts, documentation, or compatibility
with analytics tooling.

## Guidelines

- Keep reusable instructions free of client data, credentials, private URLs, and
  company-specific secrets.
- Prefer read-only smoke tests and explicit user approval before any destructive
  or publishing action.
- Keep Windows support strong; note any PowerShell 7 or cross-platform behavior
  clearly.
- Keep provider-specific metadata in `config/mcp-catalog.json`; do not duplicate
  it in `SKILL.md`, `AGENTS.md`, or `README.md`.
- Update `SKILL.md` when changing agent behavior and `README.md` when changing
  user-facing behavior. Keep `AGENTS.md` as a small compatibility entry point.
- Add first-day acceptance tests for selection, partial completion, scoped
  credentials, config ownership, evidence resume, and client output whenever
  those areas change.

## Pull Requests

Before opening a pull request:

- Run `Validate`, `PesterTests`, `CatalogReview`, and `ReleaseAudit`.
- Explain the setup scenario the change improves.
- Call out any new dependency, permission, credential, or vendor-console
  requirement.
- For provider changes, include the primary upstream source, officialness,
  runtime, auth route, risk, and verification date.
