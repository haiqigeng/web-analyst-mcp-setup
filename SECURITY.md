# Security Policy

## Supported Versions

Security fixes are considered for the latest public release.

## Reporting A Vulnerability

Please use the repository's **Security** tab and choose **Report a
vulnerability** so credentials, reproduction details, and affected paths stay
private. Do not open a public issue containing secrets or client data.

Include:

- the affected repository, file, or workflow;
- a short reproduction or explanation;
- whether credentials, tokens, personal data, or client data could be exposed;
- any suggested mitigation.

## Scope

This project is a setup kit for analytics and AI-agent tooling. Treat credential
handling, OAuth flows, generated config files, local caches, and vendor-console
instructions as security-sensitive areas.

Do not commit secrets, exported client data, private screenshots, tokens,
cookies, `.env` files, or generated local configuration containing credentials.
Local MCP launchers must receive only the credential and configuration keys
declared for their selected tool/provider, never the complete local secret map.
