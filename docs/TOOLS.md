# Open-source building blocks

Install tools only when they solve an observed problem; do not deploy the entire list at once.

| Capability | Upstream |
|---|---|
| Self-hosted CI | https://github.com/actions/runner |
| Vulnerability scans | https://github.com/aquasecurity/trivy |
| Server provisioning | https://github.com/ansible/ansible |
| Dependency update PRs | https://github.com/renovatebot/renovate |
| Encrypted config | https://github.com/getsops/sops |
| Infrastructure as code | https://github.com/opentofu/opentofu |
| Optional self-hosted PaaS | https://github.com/coollabsio/coolify |
| Kubernetes GitOps (later) | https://github.com/fluxcd/flux2 |
| Alternative Kubernetes GitOps | https://github.com/argoproj/argo-cd |
| Independent CI fallback | https://github.com/woodpecker-ci/woodpecker |

Keep deployment workflows credential-isolated; pin externally sourced actions and images to audited versions where appropriate.
