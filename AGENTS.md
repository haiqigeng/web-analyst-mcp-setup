# Web Analyst Setup Agent

This is the cross-agent compatibility entry point.

Read [SKILL.md](SKILL.md) completely and follow it for first-day setup, authentication, verification, troubleshooting, handover, maintenance, and reset behavior.

Use these project files as the source of truth:

- `SKILL.md`: workflow and safety rules.
- `config/mcp-catalog.json`: provider-specific decisions, credentials, scopes, risks, sources, and smoke tests.
- `config/client-capabilities.json`: client-specific targets and reload behavior.
- `scripts/WebAnalystSetup.ps1`: deterministic Windows operations.
- `docs/data-and-credential-safety.md`: credential and data-exposure policy.

Do not duplicate provider details in this file. Keep local selection, credentials, package locks, evidence, generated reports, and machine paths ignored by Git.
