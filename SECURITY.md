# Security policy

This public repository contains example configurations and sanitized operating procedures, **never production credentials**.

Do not commit tokens, passwords, environment values, certificates, SSH keys, SOPS/age private keys, private repository contents, customer data, sensitive host topology, or production IP addresses.

Treat fork and pull-request builds as untrusted. Never expose production secrets, SSH agents, privileged mounts, or a Docker socket to pull-request jobs. A CI runner must not also be the production deployment authority.

Use GitHub's private vulnerability reporting where enabled. Do not publish sensitive disclosures in an issue.

Before each release: verify CI and scanner results, immutable artifacts, backup freshness, and rollback capability.
