# A second CI machine: options and recommendation

**Status:** proposal for Samuel's decision. **Written:** 16 November 2026.
**Decision needed:** which option, and the budget for it.

## The problem, measured

All self-hosted CI runs on one Multipass VM (`samloryx-ci`: 4 vCPU, 5.8 GiB) on the development
laptop, behind a one-slot mutex. One job runs at a time across every repository.

What that costs, from successful runs since 13 November:

| Workflow | Longest job (work) | Median push-to-result | Worst push-to-result |
|---|---|---|---|
| samloryx-os `ci-gate` | 23 min (`platform-build`) | **192 min** | **471 min** |
| samloryx-os `sonarcloud` | 26 min (`scan`) | 30 min | 55 min |
| samloryx-os `security-scan` | 4 min | 33 min | 53 min |
| nabor `nabor-quality` | 18 min | 32 min | 87 min |
| consultancy `ci-gate` | 24 min (`frontend-build`) | 13 min | 45 min |

A SamloryxOS change does about 25 minutes of work and waits about 3 hours for it. On 16 November
51 runs were queued at once (35 were cancelled by hand to let urgent work through).

The laptop itself, measured on 16 November:

| Resource | Total | In use | Note |
|---|---|---|---|
| CPU | i7-1165G7, 4 cores / 8 threads | VM holds 4 vCPU | Low-power mobile chip |
| RAM | 15 GiB | ~11.8 GiB used, ~3.3 GiB available | The VM alone is ~6 GiB |
| Swap | 19 GiB | 3.7 GiB in use | Memory pressure already |
| Disk | 291 GB | 79 GB free | |

**A second VM on the laptop adds no capacity.** It splits the same 4 cores and 15 GiB, and two
Java builds at once (1.5 GiB heap each, plus Postgres containers) would push it into swap or the
OOM killer. That is why the mutex is one slot and why `FAST_SAFE_DELIVERY.md` says not to raise it.

The laptop also cannot run the full SamloryxOS suite for development while CI is busy, and when it
sleeps or is off, CI and the CI watchdog stop.

## What the new machine must do

| Need | Size it implies |
|---|---|
| 3 parallel CI slots (Java platform, Node web/mobile, scanners and small repos) | ~4 GiB RAM and 2 cores per slot, plus Testcontainers Postgres |
| Persistent Maven, pnpm and Docker caches | 100+ GB fast disk |
| Always on, unattended | Server-grade or a desktop on stable power |
| Isolated from production | **Not** the production Hetzner host: PR code must never share a host or Docker socket with production (`FAST_SAFE_DELIVERY.md`, capacity lanes) |

**Minimum:** 8 cores, 32 GiB RAM, 250 GB NVMe. **Comfortable:** 8+ cores, 64 GiB RAM, 2 × 500 GB NVMe.

### About Nabor's builder

Nabor's unattended preview deploy needs a builder that is neither the live host nor a PR runner.
The same physical machine can host it **only** as a separate VM with its own deploy identity, no
shared Docker socket, and no PR runner inside it. That needs the 64 GiB size. On a 32 GiB machine,
keep it CI-only and leave Nabor CD off.

## Options

Prices change often in 2026 (Hetzner repriced in April and June) and published figures conflict.
Treat every number below as a range to confirm on the vendor's own page before ordering. Prices
exclude VAT.

### A. Rented dedicated server (Hetzner AX42 class or a server-auction machine)

- **Specs:** AX42 is an AMD Ryzen 7 PRO 8700GE (8 cores), 64 GB DDR5 ECC, 2 × 512 GB NVMe.
- **Cost:** about **€97/month plus a one-time setup fee of about €49**, per October 2026 reports of
  Hetzner's June price list ([agentdeals PR](https://github.com/robhunter/agentdeals/pull/2259),
  [ployz.dev](https://ployz.dev/blog/hetzner-server-auction)). Older listings show roughly €47 to
  €57/month ([whtop](https://www.whtop.com/plans/hetzner.com/128296),
  [bex.co](https://bex.co/blog/2026/08/16/hetzner-2026-price-shocks-owning-hardware-pitch)). Server
  auction machines are often cheaper for similar specs, with no setup fee.
- **For:** always on, off-site, data-centre power and network, fast to provision, fits the 64 GiB size
  that also allows an isolated Nabor builder VM. Same provider you already operate.
- **Against:** a monthly bill. It is a separate account or project from production, but still a
  rented server that needs patching.

### B. A machine you own, at home or in the office

- **Specs to look for:** a used or new desktop or mini PC with 8+ cores and 32 to 64 GB RAM.
- **Cost:** one-off purchase, plus electricity. Price it locally; I have not checked South African
  prices.
- **For:** no monthly bill; you own the hardware.
- **Against:** depends on your power and internet. A power cut stops CI the same way a closed laptop
  does, so it needs a UPS. It is also physically at your premises, and needs a static setup that
  survives reboots.

### C. Rented cloud VM (for example Hetzner CCX33)

- **Cost:** about **€138/month** after the June 2026 repricing, up from about €62
  ([northflank](https://northflank.com/blog/hetzner-cloud-server-price-increases),
  [netcupvoucher](https://netcupvoucher.com/blog/hetzner-third-price-hike-june-2026)).
- **Verdict:** more money than option A for less machine (8 vCPU, 32 GB). Only worth it if you
  want to resize or delete it by the hour.

### D. Stay on the laptop

- **Cost:** nothing.
- **What helps:** cancel superseded runs (`scripts/prune-obsolete-ci-runs.sh`); don't run full suites
  locally; pause CI with `multipass suspend samloryx-ci` when you need the whole machine.
- **Verdict:** the 3-hour wait stays, and it grows with every new repository and every Dependabot burst.

### Not an option: the production Hetzner server

It has spare capacity, but running untrusted PR code next to production with live PayFast keys
breaks the isolation rule that the release gates depend on.

## Recommendation

**Option A, a rented dedicated server with 64 GB RAM**: an AX42 or an equivalent auction machine.
It removes the bottleneck without depending on the laptop or local power, and it is the only option
sized to also host Nabor's isolated builder later. If a monthly cost is not acceptable now, **option
B with a UPS** is the fallback.

## Moving CI over (about a day, no workflow changes)

The workflows already select runners through repository variables (`SAMLORYX_CI_RUNNERS`,
`NABOR_CI_RUNNERS`), so no repository needs a code change.

1. Provision Ubuntu LTS. SSH keys only, firewall, unattended security upgrades.
2. Create one CI-only service account. No production SSH keys or tokens on this machine, ever.
3. Install the runners and the job mutex. The vendored mutex already supports several slots
   (`JOB_LOCK_SLOTS`), but `scripts/install-ci-mutex-vm.sh` pins it to `1` and targets the laptop's
   Multipass VM, so it needs a small reviewed change first: take the host and slot count as
   parameters. Then install with 3 slots and register each repository with the labels it uses today.
4. Prove it with the secret-free canary (`docs/CI_CANARY.md`) in every repository, then run each
   repository's real CI once.
5. Point the CI health watchdog at the new host, so CI is monitored when the laptop is off.
6. Keep the laptop VM registered but stopped for a week as a fallback, then retire it and
   reclaim ~6 GiB RAM for development.
7. Record the before and after push-to-result times in `ROLLOUT.md`.

Later, only on the 64 GiB machine: a separate VM for the Nabor builder with its own deploy identity,
no PR runner and no shared Docker socket, then Nabor's CD can be considered.

## Decision

| Question | Answer |
|---|---|
| Option (A, B, C or D)? | |
| Monthly or one-off budget? | |
| Provision Nabor's builder VM on it later? | |
