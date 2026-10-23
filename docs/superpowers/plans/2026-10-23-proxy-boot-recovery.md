# NAS Proxy Boot Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover the existing NAS proxy containers after a boot-time TUN/Docker race without relying on Git, DNS or image pulls.

**Architecture:** A standalone Bash script prepares/checks TUN and waits a bounded time for Docker, then starts only stopped existing `tailscale`, `adguardhome` and `traefik` containers in that order. DSM runs the same script at boot and every five minutes; the existing deploy lock prevents overlapping recovery and deployment runs. This repairs an early Docker startup failure rather than claiming DSM's boot scheduler runs before Container Manager.

**Tech Stack:** Bash, flock, DSM's existing insmod and Docker CLI; existing shell test runner.

**Spec:** Option A approved in this conversation and `claude-todo show bad2796d`.

## Global Constraints

- Repository edits/tests only; no NAS/host changes, restarts, installs, reboot tests or git writes without separate authorization.
- Preserve tailnet DNS choice, access rules, persisted Tailscale identity and other NAS containers.
- Never recreate containers, pull images, run Compose up, change restart policies or restart healthy containers.
- No new dependencies, manifests, automatic one-time operations or deployment hooks.
- Recovery jobs deliberately restart stopped proxy containers; disable both jobs before intentionally stopping them.

## Review Focus

- TUN or Docker readiness arrives late: bounded retries and no premature container starts.
- TUN stays absent or module loading fails: actionable nonzero failure, no fake device or permission changes.
- Existing container is missing or belongs to another project: refuse to create or start it.
- A parent start fails: no dependent starts, nonzero exit; a later scheduled run retries.
- Deployment/recovery overlap or containers already run: no concurrent mutation and no unnecessary starts.

---

### Task 1: Implement and regression-test ordered recovery

**Files:**
- Create: `scripts/recover_proxy.sh`
- Create: `scripts/tests/recover_proxy_test.sh`
- Reuse unchanged: `scripts/lib.sh`, `scripts/tests/lib.sh`

**Interfaces:**
- Consumes: `log()` from `scripts/lib.sh`; `.deploy.lock` used by `scripts/deploy.sh`; Docker inspect/info/start; `/dev/net/tun`, `/sys/module/tun`, `/lib/modules/tun.ko`.
- Produces: `bash scripts/recover_proxy.sh`, no arguments or secrets. Exit zero after all three containers report running (or another lock holder makes this run unnecessary); nonzero for unsafe state or readiness/start failure. Running state is not DNS/HTTPS health.

- [ ] **Step 1: Write failing entry-point tests.** Run the real script in a temporary repository using stub commands and Bash environment fixtures for device/module checks. Assert exact mutation logs for ordered recovery, already-running containers, delayed TUN/Docker, module failure, readiness timeout, missing/wrong-project containers, start failures, verification failure and lock contention. Stub sleeping so timeout tests are fast; never touch the real module loader or Docker daemon.
- [ ] **Step 2: Verify red.** Run `bash scripts/tests/recover_proxy_test.sh`; confirm failure because the recovery script does not exist.
- [ ] **Step 3: Implement recovery.** Append `/usr/local/bin` to PATH as existing DSM scripts do. Acquire `.deploy.lock` nonblocking before mutations. If TUN is missing and the module is not loaded, load `/lib/modules/tun.ko`, reporting loader errors. Poll TUN and Docker readiness up to 24 attempts at five-second intervals. Preflight all three existing container identities using Compose project/service labels before any starts. Skip running containers; only start stopped/created containers, fail loudly on other lifecycle states. Check running state after each start before progressing. Do not silently suppress inspect/start errors.
- [ ] **Step 4: Verify green.** Rerun the new tests, Bash syntax checks and available relevant existing tests. Record exact results and unavailable tools; no install/build commands. Existing CI automatically discovers the new `*_test.sh` file.

### Task 2: Document safe rollout and limitations

**Files:**
- Modify: `README.md` (proxy recovery section, scripts table, TUN troubleshooting).

**Interfaces:**
- Consumes: Task 1's recovery entry point and exit contract.
- Produces: rollout, validation and rollback instructions; no automatic scheduler installation.

- [ ] **Step 1: Document scheduling.** Root DSM boot task plus independent five-minute task, email on failure, both invoking `bash /volume1/docker/homelab/scripts/recover_proxy.sh`. Describe bounded readiness retries and later periodic recovery, lack of strict pre-Docker boot ordering, intentional-stop opt-out, shared lock and no Git/DNS dependency.
- [ ] **Step 2: Document approval-gated rollout.** Inspect current TUN setup and scheduled tasks first; obtain separate approval before running recovery or changing tasks. Explain no-op validation when containers are healthy, container identity/mount checks, tailnet DNS query and Glance HTTPS checks. Reserve stopped-container simulations and reboot tests for explicit approval. Disable both tasks to roll back; no identity/state deletion or Compose recreation.
- [ ] **Step 3: Review scope.** Show diff stat; confirm Compose, routes, env files, persisted state and existing deployment behavior remain unchanged. Explicitly identify the new root-run NAS script. Keep the todo in progress until rollout/live verification is complete or Theo agrees to a repository-only handoff.

No commits or other git writes are authorized by this plan.
