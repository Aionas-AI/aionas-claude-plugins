# Security

This plugin runs on the computers of Aionas customers. Please report a
vulnerability privately through **Security → Report a vulnerability** on this
repository. Do not open a public issue.

How a change reaches customer computers:

- `main` accepts changes only through a reviewed pull request (ruleset
  `main-protected`: a code-owner approval from someone other than the last
  pusher, the `ci` checks, no force push, no deletion).
- Release tags `aionas-savings-v*` cannot be moved or deleted.
