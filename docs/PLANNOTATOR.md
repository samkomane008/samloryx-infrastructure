# Plannotator: shared AI review workflow

Status: **opt-in pilot** (14 November 2026). This is a human review tool, not a deploy/merge gate.

## Purpose

Use [Plannotator](https://github.com/backnotprop/plannotator) locally to review AI-produced plans, documents, HTML artifacts and Git diffs across product repositories. Keep GitHub PRs and the existing repo-specific tests/security requirements as the durable source of truth. Do not make a live deployment depend on a personal laptop or an interactive browser session.

## Installation (trusted Ubuntu workstation only)

Review the upstream installer before running it; do **not** install this tool on production servers, GitHub runners or deploy identities.

```bash
curl -fsSL https://plannotator.ai/install.sh -o /tmp/plannotator-install.sh
less /tmp/plannotator-install.sh
bash /tmp/plannotator-install.sh
command -v plannotator
plannotator inbox
```

The full installer detects compatible locally installed agents and configures their supported integrations. Changes to agent hooks are opt-in; verify existing settings and use `--minimal` if you prefer to install only the binary. For Codex Inbox, see `plannotator inbox --help` and configure an MCP entry only after validating local Codex compatibility.

## Workflow

1. Plan: have the coding agent produce a Markdown implementation plan with scope, risks, affected files, test strategy and rollback. Review it locally with `plannotator` / the agent's installed annotate command. Approval is advisory; follow the repository's existing PR policy.
2. Build: use an isolated branch/worktree. Never allow agent-generated annotations to override the repository's secure coding, privacy or quality requirements.
3. Review: inspect the actual diff with `plannotator review` from that worktree, or a GitHub PR via `plannotator review https://github.com/OWNER/REPO/pull/NUMBER`. Record actionable outcomes in PR comments or checked-in documentation.
4. Validate: execute the **existing repository-specific** tests, linters, type checks, security scans and any deployment checks; attach evidence to the PR. Plannotator approval is not CI evidence.
5. Merge/release: use the repository's approved process and existing release gates. No auto-merge, runner changes or deployment permission changes are implied by this document.

## Privacy and limitations

- Do not put tokens, .env files, customer data, production host inventories, private keys or personal records into annotations, shared links, AI-provider queries or publicly committed documentation.
- Default to local reviews. Set `PLANNOTATOR_SHARE=disabled` in the shell that launches Plannotator to prevent share links. Review upstream release notes and privacy documentation before enabling AI or cloud features.
- Browser UI, Inbox and tool hooks require an installed local binary and supported local agent. A ChatGPT cloud automation does **not** automatically see a local Plannotator Inbox.
- Do not invoke this tool in headless CI or production deploy jobs. Existing branch protections and build/security gates must continue to function when Plannotator is unavailable.
- Upstream: https://github.com/backnotprop/plannotator ; documentation: https://docs.plannotator.ai/open-source/start/installation

## Initial rollout acceptance

- [ ] Owner has inspected and installed the CLI on the trusted Ubuntu workstation
- [ ] Existing agent configuration backed up and inspected before automatic hook changes
- [ ] Local Inbox opens and one non-sensitive document can be annotated
- [ ] Samloryx OS PR diff opens in read-only review without affecting checks/merge
- [ ] Nabor PR diff opens in read-only review without affecting checks/merge
- [ ] Feedback is carried into a PR comment or decision record, not lost in the local UI
- [ ] Existing local CI validation and production deployment policies remain unchanged
