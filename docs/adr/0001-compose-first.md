# ADR 0001 — Docker Compose first

Status: accepted for initial infrastructure recovery.

**Context:** We operate multiple projects on constrained self-managed infrastructure and aim to eliminate recurring CI and code-quality subscriptions.

**Decision:** Retain GitHub source control, adopt isolated self-hosted runners, use Docker Compose for server workloads, and treat infrastructure definitions as reviewed desired state. Only add Kubernetes and Flux or Argo CD when documented operational requirements outweigh the cost of complexity.

**Consequences:** Lower initial maintenance cost and a gradual migration path; weaker native reconciliation than Kubernetes-focused GitOps tools. We must still engineer controlled deployments, versioning, health checks, backups, and rollbacks.
