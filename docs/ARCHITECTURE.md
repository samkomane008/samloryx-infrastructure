# Reference architecture

```text
Private product repositories (GitHub)
   | PR or push events
   v
Isolated unprivileged self-hosted CI runners
   | Build, test, vulnerability and secret scans
   v
Verified, versioned artifact / container digest
   | Controlled promotion, approvals and credentials
   v
Trusted deployment identity, separate from PR runner
   | Declarative Docker Compose desired state
   v
Production Linux host
   | Health checks and monitoring
   v
Backup + disaster recovery validation
```

This adopts GitOps principles (reviewed desired state and reconciled deployments) without requiring Kubernetes. GitHub Actions runners are registered for their specific repositories or organizations; a personal GitHub account does not automatically share a runner across every repository.

Security: no production tokens, Docker socket, or privileged mounts on untrusted PR runners. Never expose real host addresses or private inventories in this public repository.
