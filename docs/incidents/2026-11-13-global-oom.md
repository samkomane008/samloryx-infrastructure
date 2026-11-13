# 2026-11-13 — Shared CI VM global OOM

Status: **diagnosed, not recovered**. Evidence was supplied from the owner's private VM. This public summary intentionally omits host addresses, logs, secrets, runner tokens and internal inventories.

## Evidence

- The shared Multipass VM had approximately 5.8 GiB RAM and 4 GiB swap.
- At 11:38 SAST the kernel logged `global_oom` and killed a `MainThread` process in Nabor's runner service cgroup (approximately 1.62 GiB resident anonymous memory).
- At 11:47 SAST the kernel again logged `global_oom` and killed a Java process in Samloryx OS runner service cgroup (approximately 2.54 GiB resident anonymous memory).
- Nabor's runner service was then failed with `Result=oom-kill` and its GitHub runner was offline.
- For Nabor's runner service, `MemoryMax`, `MemoryHigh`, and `MemorySwapMax` were all `infinity`. The OOM was **global**, not evidence of a per-unit memory cap.
- A serial-gate installer was present and a `90-infra-recovery.conf` drop-in existed, but correct cross-repository serialization was not demonstrated.
- Nabor's existing GitHub quality and SonarCloud workflows still defaulted to `ubuntu-latest`, a separate runner-selection problem.

`Swap: 0B used` was observed *after* the incident; it alone does not prove that swap was unavailable during the incident.

## Safe recovery procedure

1. **Do not reboot the VM or stop other repositories' actively running jobs.** Inspect jobs first.
2. `bash scripts/ci-serial-gate-state.sh` on the trusted host to verify configuration without printing sensitive values.
3. Review `ci-oom-gate-diagnose.sh` output and validate which jobs / processes shared the VM during each global OOM.
4. Establish **one heavy build/scan at a time across all repositories on this VM**, not merely GitHub workflow-level `concurrency` (which does not provide a cross-repository lock).
5. Add bounded heap/concurrency to Java, Node and security scanners based on observed per-job peak memory, with unit/service resource ceilings so exhaustion fails an individual job rather than the VM.
6. Only when competing heavy workers have exited and memory is adequate, recover the affected Nabor listener service **only** with the owner's trusted VM credentials. Do not blindly restart all runner services.
7. Verify the Nabor runner comes online with expected labels and run an isolated secret-free canary.
8. Migrate Nabor quality and scanner workflows from `ubuntu-latest` to `nabor-ci` through a reviewed PR; ensure privileged production credentials are not exposed on the PR runner.
9. Run a bounded build and security scan sequentially. Verify runner availability, completed workflow steps, peak memory and no new OOM log lines.
10. Roll out tested policy across the remaining repositories. Keep this incident open until the recovery acceptance checks pass.

## Long-term position

Existing hardware is sufficient to attempt sequential CI without subscriptions, but the 5.8 GiB VM is not proven to support multiple simultaneous Java, Node and security scans. Do not deploy Kubernetes, add new orchestration layers or buy hardware until workload measurements justify doing so.
