# Samloryx Infrastructure

Open-source, subscription-minimizing infrastructure standards for Samloryx projects.

**Scope:** shared CI/CD, GitOps/DevSecOps, repeatable server provisioning, deployment policy, observability, backups and disaster recovery.

**Not hosted here:** product features, client data, credentials, production inventories or other confidential information.

## Principles

- GitHub stays the source-code and pull-request platform.
- Verified isolated self-hosted GitHub Actions runners carry out builds, tests and scans where supported.
- Production deployment identities and credentials stay separate from untrusted pull-request runners.
- Docker Compose first; only introduce Kubernetes and Flux or Argo CD when justified.
- Adopt and configure established open-source tools instead of maintaining custom platforms.

## Getting started

Run local read-only diagnostics on your trusted Ubuntu workstation after cloning this repository:

```bash
bash scripts/runner-doctor.sh
bash scripts/github-audit.sh
```

The audit output is stored locally and ignored by Git. Do not publish host details, credentials or real environment files.

## Roadmap

1. Audit all existing GitHub workflows and deployment dependencies.
2. Validate `samloryx-ci` VM, Actions runner and serial execution gate.
3. Recover a single secret-free, non-deploying CI workflow as a canary.
4. Standardize CI gates across product repositories without interrupting product development.
5. Harden deploy runners, monitoring, backup restoration and disaster recovery.

This is a public infrastructure standards and automation repository, not an inventory of production secrets.

See [Security policy](SECURITY.md), [architecture](docs/ARCHITECTURE.md), [rollout](docs/ROLLOUT.md), and [open-source tool choices](docs/TOOLS.md).
