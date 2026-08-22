# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Added
- **A performance gate on provisioning (`ansible/roles/acceptance`).** The playbook used to end by declaring success; it now ends by measuring the machine. The role builds [stencil-bench](https://github.com/PoisonOakey/stencil-bench) on the node, runs its correctness test, then runs the benchmark with `--check` -- and a non-zero exit **fails the play**. That is the point: a node quietly slower than its peers is exactly what joins a fleet unnoticed, and none of the causes (memory coming up single-channel, contended vCPUs, thermal capping) appear in a boot log. The floor is 12.0 GB/s against `v0_naive`, derived from ten runs on this VM (median 15.20, minimum 14.85, σ 1.45%) rather than chosen. The ~19% margin is deliberate -- the role runs last, right after every other role has finished working the machine, and the first run through the finished role measured 14.81, already below the sampled minimum. Ordered last in `site.yml` for a second reason too: a node rejected before its monitoring stack exists is a node you cannot then investigate.
- **`StencilThroughputRegressed`, relative rather than absolute.** The gate's fixed floor catches gross faults; it cannot catch a node that passed at 16 GB/s and now manages 13.5 -- a real 15% regression still well above any sensible threshold. The rule compares against the node's own 7-day best. `for: 25h` because the benchmark runs on a daily timer, so 25 hours means two consecutive measurements had to agree and one run that landed while the node was busy pages nobody. Three test cases prove it fires, stays quiet on a single bad run, and stays quiet on ordinary variance; mutation-checked by weakening the threshold and shortening `for`, each of which turns the suite red. Its known limitation is stated in the rule and the runbook: degradation slower than seven days drags the baseline with it and never fires.
- **A seventh Grafana panel, mirroring that rule.** Bandwidth per kernel, a dashed line at 85% of the 7-day best, and a threshold at the acceptance floor -- so the alert is visible while approaching rather than only after firing. Verified through Grafana's API against the running stack, with both queries returning data, because a panel whose query resolves to nothing is precisely the silent failure `config-validate` exists to catch.
- **node_exporter's textfile collector.** Mounted explicitly rather than reached through the existing `/rootfs` mount: `--path.rootfs` is a different mechanism, and coupling them means a later change to `/rootfs` stops the metrics with no error at all.
- **Alert rules are unit-tested, not just parsed (`monitoring/tests/alert_rules_test.yml`).** `promtool check rules` proves the expressions compile; nothing proved they fire. Each rule now has a case that should page someone and a case that should not, because a rule that fires on everything is as useless as one that never fires: a scrape that fails once and recovers must not trip `TargetDown`'s `for: 2m`, tmpfs sitting near-full must not trip `DiskSpaceLow`, and -- the reason the file exists -- a disk stable at 80% must not trip `DiskWillFillIn24Hours` while one draining steadily must. Verified by mutation rather than by the suite passing: lengthening the `for`, widening the disk threshold, dropping the `fstype` exclusion and replacing `predict_linear` with a naive threshold each turn it red, and restoring the file turns it green.
- **`config-validate` CI job.** Three jobs covered the PowerShell, Compose and Ansible layers and left ten files unread -- 440 lines, including every alert rule, the Prometheus scrape config, the Alertmanager config, the autoinstall file and the Grafana dashboard. Nothing parsed them until they reached a running node. They are grouped into one job because they share a failure mode: none of them crashes anything when wrong. A malformed alert rule is a rule that never fires; an unresolvable datasource uid is a dashboard of empty panels. `promtool` and `amtool` run from the images the stack itself uses, so the validator is the version that will read the file in production.
- **The Alertmanager template is checked, not only its example.** The node runs a file rendered from `alertmanager.yml.j2`; CI was checking `alertmanager.yml.example`, and nothing stopped the two diverging. Both branches are now rendered and checked -- with a webhook it routes to Discord, without one to the `null` receiver, which is what a fresh clone gets. A template valid in one branch and broken in the other was previously found by a crash-looping container.
- **Checks for the couplings no comment can enforce.** The Grafana datasource `uid` is referenced thirteen times in the dashboard JSON and the provisioning file says "leave it alone unless you change it there too"; that is now asserted. So is the link between each alert and its runbook: five `runbook_url` values anchoring to headings in another file, maintained by hand, and a broken one means a 404 for whoever was just woken up.
- **`secrets` CI job -- gitleaks over the full history.** Three credentials live beside this repository, kept out of it by `.gitignore` alone, which a `git add -f` or a renamed file defeats silently. Scans the commit graph rather than the working tree, because a credential is public at the commit, not the merge. 112 commits clean. Worth knowing before trusting a green result: gitleaks allowlists well-known example keys upstream, so a planted `AKIAIOSFODNN7EXAMPLE` is ignored while a real-shaped token is caught.
- **Pester tests for `Get-LabConfig` (`scripts/tests/`).** The only script in `scripts/` with logic rather than side effects, and every stage calls it. Covers the missing-file error, `$HOME` expansion, and that the numeric fields survive as numbers rather than the strings `VBoxManage` would reject. The others wrap `VBoxManage`, `diskpart` and `bcdedit`, where a unit test would only be testing its own mocks. Three-argument `Join-Path` is PowerShell 6+, so the tests use nested `Split-Path` -- the lint job runs on `windows-latest` under 5.1.
- **`.github/dependabot.yml`.** Pinning without an update path just means running an old Prometheus forever.

### Changed
- **Image tags pinned** to the versions currently running -- Prometheus 3.13.2, Alertmanager 0.33.1, node_exporter 1.12.1, Grafana 13.1.3. `latest` meant CI validated the configs with one version of `promtool` while the node pulled whatever `latest` had become that day.
- **R3 reworded in `ROADMAP.md`.** It claimed to be blocked on a runner with nested virtualisation; GitHub's Linux runners have exposed `/dev/kvm` since 2023. The real constraint is that VirtualBox cannot run there, so the buildable version boots an Ubuntu cloud image under QEMU and covers the Ansible half only.
- **`README.md` shows the observability layer.** The workflow diagram stopped at the three Ansible roles, so the four layers named in the Overview appeared as two boxes. The Problem section lost the broken-display premise, which claimed the screen ruled out an interactive install while `TROUBLESHOOTING.md` tells the reader to go and look at that screen, and became a table.
- **`docs/ROADMAP.md` renamed to `docs/FUTURE-ROADMAP.md`.** The file is a tracker for what comes next, and the name now says so. Earlier entries in this changelog still call it `ROADMAP.md`, which is what it was called when they were written.

### Fixed
- **The workflow diagram had the role order wrong.** It chained `docker -> tailscale -> monitoring`; the playbook has run `docker -> monitoring -> tailscale` since `tailscale` was moved last so that a node awaiting browser device approval still gets its observability stack. The README was never updated to match.
- **`monitoring/.env.example` referred to `06-setup-monitoring.ps1`** in the present tense. That script has not existed since the Ansible migration.

### Added
- **Alertmanager, closing R4.** Alert rules were evaluated and visible at `:9090/alerts` and notified nobody. Alertmanager now groups related alerts, applies an inhibit rule so a `critical` suppresses `warning` for the same instance, holds silences, and posts to Discord. Verified end to end: `node_exporter` stopped on purpose, `TargetDown` fired after its `for: 2m`, and the message arrived in the channel with its summary, description and runbook link.
- **`docs/RUNBOOK.md`, one section per alert.** What it means, how to confirm it, what to do, and what a false positive looks like. Every rule carries a `runbook_url` annotation, so the link travels with the notification rather than living somewhere the person woken up has to go looking for.
- **Post-deploy health check.** `docker compose up` succeeding means containers were *created*, not that they stayed up. The role now checks `docker compose ps` after deploying and fails naming any service that is not `running`. It caught a crash-looping Alertmanager on its first outing.
- **Handlers for config changes.** `compose up` only recreates a container when its *definition* changes, so an edited bind-mounted `prometheus.yml` left Prometheus running its startup config -- which is why it could not see Alertmanager even though both were up. Changing `prometheus.yml` or `alert_rules.yml` now restarts Prometheus; changing the Alertmanager config restarts Alertmanager. Only on change, so a no-op run stays `changed=0`.

### Fixed
- **Alertmanager config unreadable by Alertmanager.** Rendered `0600` owned by the login user, but the container runs as `nobody` (65534) and reads the file itself, so it crash-looped on `permission denied`. Grafana's `.env` gets away with `0600` because the Docker daemon reads it as root before the container starts. Now `0400` owned by 65534 -- tighter than `0644` and readable by the process that needs it.
- **Grafana provisioned as code.** The stack deployed an empty Grafana: no datasource, no dashboard, and six manual clicks before a single panel rendered. That contradicted the pipeline's own zero-touch claim. `monitoring/grafana/` now holds a datasource definition, a dashboard provider, and one dashboard, all read on startup. Verified against the node: the API reports the Prometheus datasource as default and `Node Overview` present, with all six panel queries returning data.
- **`Node Overview` dashboard, written rather than imported.** Six panels — target up, memory available, root filesystem free, uptime, load average per core, CPU by mode — deliberately mirroring `alert_rules.yml`, so what is watched and what pages are the same signals. Hand-written at ~190 lines instead of vendoring the 6,000-line community dashboard: it is reviewable in a diff, and "dashboards as code" is a weaker claim when the code is someone else's.
- **`allowUiUpdates: false`** on the dashboard provider. Dashboards live in the repository, so an edit made by clicking in the browser would be silently overwritten on the next deploy. Rejecting the edit is better than losing it.
- **Prometheus alert rules (`monitoring/alert_rules.yml`):** the stack collected metrics and alerted on nothing, which is half an observability system. Five rules: `TargetDown`, `DiskSpaceLow`, `DiskWillFillIn24Hours`, `MemoryPressure`, `HighCpuLoad`. Two are deliberately not naive thresholds -- `DiskWillFillIn24Hours` uses `predict_linear`, because a disk sitting at 80% and stable needs nobody woken up while one filling fast does, and `HighCpuLoad` divides `node_load15` by core count so the threshold holds regardless of vCPU sizing. `MemoryPressure` uses `MemAvailable` rather than `MemFree`, which excludes reclaimable cache and reads alarmingly low on a healthy Linux host. Verified on the node: all five report `health=ok`, so the expressions evaluate rather than merely parse.
- **Alerts are evaluated, not routed.** They are visible at `:9090/alerts`; nothing is notified yet. Alertmanager is tracked as R4 in `ROADMAP.md` rather than implied.
- **Tech stack line at the top of `README.md`.** The first thing a reader saw was prose. The tools are now listed above the fold, where a skim finds them.

### Changed
- **Documentation trimmed.** `README.md` 1,518 -> 946 words and `ANSIBLE-SETUP.md` 1,593 -> 641, with no commands or warnings lost. Both had grown by answering "why" inline instead of linking to the document that already answered it. The CI section in particular described three jobs and then listed the commands that *are* those three jobs; the description is gone and the commands stayed.
- **`ROADMAP.md` restructured as a tracker.** It had become a retrospective essay about a finished migration -- `Scope` and `Requirements` described planning for work already merged, which is `CHANGELOG.md`'s job. Now three tables: what is Built, what is Planned (R1 the stage 03 timing race, R2 credentials into `ansible-vault`, R3 convergence testing in CI), and what is explicitly Not planned. 1,400 -> 768 words.
- **README states its prerequisites.** The Execution section previously said only "run `Deploy-Node.ps1`". Anyone cloning the repository would provision a VM and then hit a message about Ansible being missing, with no prior warning that a WSL control node is required. It now covers both prerequisites up front: the WSL 1 control node (and why WSL 1 rather than WSL 2), and the optional Tailscale auth key -- including how to generate your own, why it should be reusable, and that it is a credential to be given an expiry and never committed. No key ships with this repository; each user creates their own.

### Added
- **Zero-touch Tailscale enrolment:** a pre-authorised key saved to `ansible/.tailscale_auth_key` on the control node is read automatically, so a rebuilt VM joins the tailnet with no human step. The file is gitignored and follows the same pattern as the generated Grafana password -- a credential that lives beside the playbook and never enters the repository. A key passed as an extra-var still takes precedence. Without a key the role behaves as before, stopping with instructions rather than hanging on a browser prompt it cannot answer.
- **Actionable failure when a key is rejected:** the task carrying the key is `no_log`, which also censored its failure output and reported an expired key as an opaque `non-zero return code`. The task is now a `block`/`rescue` that reports the likely cause -- expired, revoked, or a one-off key already spent -- and names the file to replace, without echoing the credential.

### Fixed
- **Tailscale package not found on a freshly provisioned node:** the role added Tailscale's apt repository and then installed with `cache_valid_time: 3600`. The `docker` role runs apt with the same one-hour window seconds earlier, so by the time this role ran the cache looked fresh, the index refresh was skipped, the new repository was never indexed, and apt reported `No package matching 'tailscale' is available`. A cache optimisation that is correct in isolation and wrong the moment a repository is added.
- **The first fix could not recover from its own failure:** refreshing only when the repository definition *changed* left a run that had added the repository and then failed permanently stuck -- the next run saw no change, skipped the refresh, and failed identically. The condition now describes the state required (apt knows about the package) rather than the event expected (the repository was just added).
- **Role order blocked monitoring behind a human step:** `tailscale` ran before `monitoring`, so a node awaiting browser device approval never got its observability stack. Only `docker` is a real dependency; `tailscale` is independent and now runs last. A node that is monitored but not yet on the tailnet is a better intermediate state than the reverse.

### Added
- **CI validates the Ansible layer:** a third parallel job runs `ansible-playbook --syntax-check` and `ansible-lint`. Added as its own job rather than folded into the Compose job so a failure names its own concern. `ansible/requirements.yml` declares the `community.docker` dependency explicitly -- the Ubuntu `ansible` package bundles it, but CI installs `ansible-core` alone, which does not.
- **README states what CI does not prove:** all three jobs are static validation. Nothing in CI connects to anything, so it cannot show that the pipeline provisions a VM or that the playbook converges. Convergence is verified by hand, by running `site.yml` twice and confirming `changed=0`.

### Changed
- **README describes the current layering:** the workflow diagram now shows three Ansible roles under Configuration Management instead of two PowerShell stages, the layer table distinguishes Provisioning from Configuration, and the repository tree lists `ansible/`. Added a Key Engineering Decisions row for the provisioning/configuration split, since that boundary is the reason the migration happened.
- **`monitoring` role variables carry the role prefix** (`monitoring_grafana_password_file`, `monitoring_grafana_password_length`, `monitoring_grafana_admin_password`), which `ansible-lint`'s `var-naming[no-role-prefix]` rule requires. The password file path is deliberately unchanged, so the existing generated credential is still read rather than rotated -- confirmed by a subsequent run still reporting `changed=0`.
- **`Deploy-Node.ps1` hands off to Ansible after stage 04.** Provisioning stops once the node is booted and reachable; configuration is a separate concern and now runs as a playbook. The distro is named explicitly rather than relying on the WSL default, because Docker Desktop registers its own WSL 2 distro and a bare `wsl` invocation would start that instead and fail with `HCS_E_HYPERV_NOT_INSTALLED`. Paths are translated with `wslpath` rather than string surgery on the drive letter, so the repository can move. If WSL or Ansible is unavailable the script fails with an actionable message naming `docs/ANSIBLE-SETUP.md` -- it never skips configuration silently.
- **Ansible failures are checked like every other native call.** Verified that both failure modes cross the WSL boundary intact: a missing playbook returns exit 1 and a task-level failure returns exit 2, each tripping the guard. A successful run returns 0.

### Removed
- **`scripts/05-setup-tailscale.ps1` and `scripts/06-setup-monitoring.ps1`**, replaced by the `tailscale` and `monitoring` roles. Deleted in the same change that wires the playbook in, so there is never a state where both implementations exist and nothing tells a reader which one runs.
- Documentation referring to those scripts in the present tense was updated: `TROUBLESHOOTING.md` #8 (the `sysnative` fallback now applies only to `ssh-keygen.exe` in the provisioning stages, since Ansible runs from WSL and uses the Linux SSH client), #9, #13 and #15, plus a comment in `02-provision-node.ps1`.

### Added
- **`monitoring` role:** replaces the `scp` and `docker compose up` half of `06-setup-monitoring.ps1`. Files are listed explicitly rather than copied wholesale, so the control node's `.env.example` no longer ships to the target, and `community.docker.docker_compose_v2` reports whether the stack actually changed instead of always claiming it did. Verified: `changed=4` on first run, `changed=0` on the second, with Grafana and Prometheus both answering `200` and both scrape targets `up` afterwards.
- **Grafana password survives the port (G2):** the password is generated once via the `password` lookup and persisted to `ansible/.grafana_admin_password` on the control node, which is gitignored. Every later run reads the same value. A naive port would regenerate it each run, rotating the credential unexpectedly and breaking idempotency, since the rendered `.env` would differ every time and restart the container. The rendered file is `0600` and both the lookup and the template task are marked `no_log`.
- **`tailscale` role:** replaces `05-setup-tailscale.ps1`. Two changes beyond translation. The install no longer pipes an unverified remote script into a root shell (`curl -fsSL https://tailscale.com/install.sh | sh`) -- Tailscale's signed apt repository is added instead, with the release codename taken from gathered facts rather than hardcoded. And `tailscale up` is no longer run on every deployment: the role reads the node's backend state first and leaves an already-connected node alone. Verified: `ok=15 changed=0 skipped=3` on two consecutive runs, with both authentication paths correctly skipped on a connected node.
- **Optional non-interactive Tailscale auth:** supplying `tailscale_auth_key` joins the tailnet with no human step; the key is passed at run time, never committed, and marked `no_log`. Without one, a disconnected node fails with instructions rather than hanging -- `tailscale up` blocks until a human opens the URL it prints, and Ansible buffers task output until a task completes, so running it inside a play would hang with the URL invisible. This answers the open question of whether device approval should be a manual step or use a pre-authorised key: both are supported, and the default requires no credential.
- **`docker` role:** replaces the apt/systemctl half of `06-setup-monitoring.ps1`. Installs `docker.io` and `docker-compose-v2`, asserts the service is enabled and running, and confirms the daemon responds via `docker info` rather than `docker --version`, which reports only the client and would pass with the service stopped. Verified against the provisioned node: `ok=8 changed=0 skipped=1` on two consecutive runs.
- **Conditional dpkg repair:** the PowerShell original ran `dpkg --configure -a || true` on every deployment, discarding whatever it might have reported. The role checks `dpkg --audit` first and skips the repair on a healthy node. Noted in `ROADMAP.md` that Ansible does *not* provide this for free -- the step is still hand-written, it just gained a condition and an honest exit status.
- **Ansible control-node skeleton (`ansible/`):** `inventory.ini`, `ansible.cfg` and a `site.yml` smoke test, on the `ansible-migration` branch. No roles yet -- this is the wiring only, verified with two consecutive runs reporting `ok=3 changed=0`. Every setting in `ansible.cfg` is confirmed in effect via `ansible-config dump --type all --only-changed`; defaults are deliberately not restated.
- **`docs/ANSIBLE-SETUP.md` -- running playbooks:** Ansible ignores an `ansible.cfg` found in a world-writable directory, and everything under `/mnt/d` reports mode `0777` to WSL. The resulting failure is misleading: the inventory is never parsed, so the play reports `skipping: no hosts matched` as though the inventory were at fault. Documents the explicit `ANSIBLE_CONFIG` invocation and the `wsl.conf` `automount` alternative.

## [1.10.0] - 2026-08-05
### Fixed
- **Stages 05 and 06 reported success over failed runs:** both scripts ran their `ssh`/`scp` payload and then printed their success banner unconditionally. `$ErrorActionPreference = 'Stop'` does not apply to native executables, so a failed Tailscale install or a failed `docker compose up` still produced `[OK] Monitoring Stack Deployed!`. Stage 06's payload is a six-command chain, so a failure also gave no indication which step died. Both now check `$LASTEXITCODE` after every remote call and throw with the exit status. This is the same defect fixed in stages 02 and 03 in 1.9.0 -- the fourth hand-written instance, and a large part of the motivation for the Ansible migration in `ROADMAP.md`.
- **Transcript leak in stages 05 and 06:** neither reached `Stop-Transcript` on a failure path, which the new `throw` statements would have made routine. Both bodies are now wrapped in `try/finally`, matching stage 03.
- **Missing `.env.example` failed silently:** `06-setup-monitoring.ps1` read the template without checking it existed. On a repository missing it, `Get-Content` returned nothing and the generated `monitoring/.env` was empty, deploying Grafana on its `admin/admin` default -- the exact outcome the generation step exists to prevent. It now throws instead.

### Added
- **`docs/ROADMAP.md`:** current state of each layer, the planned move of configuration management to Ansible with its scope and requirements, the deferred stage 03 ISO patch, and explicit non-goals with reasoning.
- **`docs/ANSIBLE-SETUP.md`:** one-time control-node setup on Windows. Documents why WSL **1** is required rather than WSL 2 -- WSL 2 needs `VirtualMachinePlatform`, which `01-host-prep.ps1` disables so VirtualBox gets raw VT-x, and the two cannot coexist. Also covers the DNS failure caused by a VPN client managing host DNS, forcing APT over IPv4, and the private-key permission workaround for files under `/mnt/c`. Verified end to end against the provisioned node.

## [1.9.0] - 2026-08-05
### Fixed
- **Install wait-loop could hang forever:** `Deploy-Node.ps1`'s `while ($isInstalling)` loop polled `VBoxManage showvminfo` every 15s with no deadline and no escape, so a stalled install blocked the orchestrator indefinitely with no diagnostic. Added a parameterized deadline (`-InstallTimeoutMinutes`, default 20) and an explicit throw when `showvminfo` stops returning a state at all (VM deleted, or VirtualBox unreachable). Both errors name the VM and the transcript path.
- **Orchestrator had no transcript:** `Deploy-Node.ps1` was the only script without `Start-Transcript`, so the one file a failed run should point you at did not exist. Added it, with `Stop-Transcript` in a `finally` so it closes on the error paths too.
- **Dangling VHD on failure:** `03-autoinstall-node.ps1` mounted a FAT32 VHD and assigned it a drive letter under `$ErrorActionPreference = 'Stop'` with no `try/finally`, so any failure between `attach vdisk` and `detach vdisk` left a mounted volume holding a live drive letter alongside a half-built VM. Wrapped the mount/inject/unmount sequence and moved the detach into `finally`. The `finally` suppresses its own errors so cleanup can never mask the original exception. The pre-existing next-run cleanup is kept as a second layer.
- **Stage 03 could only ever run once:** `03-autoinstall-node.ps1` rebuilds `cidata.vhd` from scratch on every run, so the new file gets a new UUID while VirtualBox's media registry (`VirtualBox.xml`) still holds the previous one and the VM still has it attached at SATA port 1. Every run after the first died with `UUID ... does not match the value stored in the media registry` and left the VM unbootable. The script now detaches the medium and closes the stale registry entry before recreating the disk, looking the entry up by location and closing it by UUID -- closing by path makes VirtualBox reopen the file and re-run the very UUID comparison that is already failing.
- **Stage 03 reported success on a failed run:** `$ErrorActionPreference = 'Stop'` does not apply to native executables, so a failing `VBoxManage` call only set `$LASTEXITCODE` and execution continued. When the medium-registry error above aborted `startvm`, the script still slept 90 seconds, still fired `keyboardputstring` at a VM that was not running, and still printed "Automated installation has been triggered!". Added explicit `$LASTEXITCODE` checks after the `storageattach` and `startvm` calls so the run fails loudly at the point of failure.
- **`2>$null` on `VBoxManage` aborted runs instead of silencing them:** several stages suppressed expected `VBoxManage` failures (closing an unregistered medium, detaching an empty slot) with `2>$null`. In PowerShell 5.1 redirecting a native command's stderr wraps each line in an `ErrorRecord`, which `$ErrorActionPreference = 'Stop'` then promotes to a terminating error -- so the redirection did the opposite of what it looked like, and turned a tolerable failure into a fatal one. Replaced in `Deploy-Node.ps1`, `02-provision-node.ps1`, and `03-autoinstall-node.ps1` with either an explicit precondition check or a scoped `'Continue'`, so expected failures are tolerated deliberately rather than by redirection.
- **Stage 03 silently did nothing against an already-installed VM:** Subiquity ejects the install media at the end of a successful install, so re-running stage 03 standalone booted the installed OS instead of an installer -- indistinguishable, from the outside, from a hung install. Added a check that an ISO is actually attached to the IDE controller, failing with the same "run Stage 2 first" guidance the missing-VM check already gives.
- **Transcript leak in stage 03:** the script exits via `Write-Error` + `exit 1` in five places and reached `Stop-Transcript` on none of them. Wrapped the body in `try/finally`.
- **Four docstrings described code that does not exist:** `02-provision-node.ps1` claimed it "automatically detects and configures the bridged network adapter" (it configures NAT with `virtio` and three port-forwards); `04-connect-node.ps1` claimed it "queries the VirtualBox Guest Properties to discover the IP address assigned by your local DHCP server" (it polls `127.0.0.1:2222`); `05-setup-tailscale.ps1` and `06-setup-monitoring.ps1` both claimed to query the VM for its IP, and both documented a `.PARAMETER VmName` against an empty `param()`. All corrected to describe the NAT port-forwarding the code actually uses; the two phantom parameters are gone.
- **Dead IP cache:** `04-connect-node.ps1` wrote `$env:TEMP\.sre-node-ip.txt`, which nothing ever read -- its own comment admitted the other scripts hardcode `127.0.0.1`. Removed, along with the variable that fed it.
- **Mojibake in the orchestrator banner:** `Deploy-Node.ps1` printed `ðŸš€` and `ðŸŽ‰` -- emoji bytes double-encoded (UTF-8 read as Latin-1) in a file with no BOM, and the first output a user sees. Replaced with ASCII markers matching the `[OK]` / `[*]` / `[X]` convention the other stages already use, rather than re-encoding: Windows PowerShell 5.1's console host cannot render astral-plane codepoints regardless of file encoding. Emoji in `README.md` and the docs are unaffected and deliberately kept.
- **Obsolete Compose schema key:** removed `version: '3.8'` from `monitoring/docker-compose.yml`, which current Docker Compose warns on. Covered by the existing CI job.
- **Empty cloud-init meta-data:** `scripts/cloud-init/meta-data` was a single newline. Populated with `instance-id` and `local-hostname` matching the `hostname` in `user-data`, which is what the NoCloud datasource conventionally expects.

- **Stale SSH host key on every rebuild:** reinstalling the OS generates a new host key, but the previous node's key stayed pinned in `~/.ssh/known_hosts` against the same `[127.0.0.1]:2222` address, so stages 05 and 06 printed a `REMOTE HOST IDENTIFICATION HAS CHANGED` warning mid-pipeline. `-o StrictHostKeyChecking=no` does not cover this -- it suppresses prompts for *unknown* hosts, never *changed* ones. `02-provision-node.ps1` now runs `ssh-keygen -R "[127.0.0.1]:2222"` right after creating the VM.

### Changed
- **Documentation corrected against the code:** `README.md` claimed zero-touch provisioning "injected `debconf_selections`", which has not been in `user-data` for several releases -- the bootloader prompt is seeded by cloud-init's `grub_dpkg` module. `TROUBLESHOOTING.md` #3 documented the same stale mechanism, and #6 described IP discovery via `VBoxManage guestproperty` over a bridged network, neither of which the project has used since 1.3.0. All three now describe what the code does; #3 and #6 keep their original symptoms so the entries are still findable by the error text.
- **Metrics stated with their conditions:** `README.md`'s provisioning figure was an unsourced "~4 minutes". Replaced with 3 min 53 s to a booted OS and 7 min 35 s for the full pipeline, qualified as a single end-to-end run on a 2 vCPU / 4 GB guest rather than a benchmark. Also dropped "headless" from that row: stage 03 boots the VM with the GUI attached so the keystroke injection can be observed, so the install is unattended but not headless.
- **Local lint matches CI:** the `Invoke-ScriptAnalyzer` command in `README.md` omitted `-ExcludeRule PSUseBOMForUnicodeEncodedFile`, so running it locally could report a failure CI would not.

### Added
- **Two root-cause entries in `TROUBLESHOOTING.md`:** #14 covers the media-registry UUID mismatch and the silent-success bug that hid it; #15 covers the `known_hosts` collision and why `StrictHostKeyChecking=no` does not prevent it.

### Deferred
- **Stage 03 is still a timing race.** `03-autoinstall-node.ps1` continues to clear Subiquity's destructive-disk confirmation by sleeping 90 seconds and then firing `controlvm keyboardputstring "yes"` at whatever happens to be on screen. Nothing verifies the prompt is displayed, so on a slow disk the keystroke goes nowhere and the install never completes. The correct fix is to pass `autoinstall` on the kernel command line so Subiquity treats the run as fully automated and never asks -- that requires rebuilding the Ubuntu ISO with a patched `boot/grub/grub.cfg`, and neither `xorriso` nor the Windows ADK's `oscdimg` is currently available on the build host. The limitation is now stated in the script header instead of being left implicit, and the 20-minute deadline above bounds the failure rather than letting it hang. That is a mitigation, not a fix.

## [1.8.0] - 2026-07-30
### Changed
- **Problem statement:** Rewrote `README.md`'s "The Problem" around the four constraints the pipeline actually addresses (no usable console, unversioned GUI provisioning, inbound access requiring a router port-forward, hypervisor-side monitoring with no history and no remote access). Replaced the previous list, which described implementation bugs encountered during the build rather than the project's motivating constraints.
- **Metrics table:** Restructured to map 1:1 onto those four problems, with each figure traceable to a source — provisioning time from a measured end-to-end run, scrape interval from `monitoring/prometheus.yml`, and the one unmeasured baseline explicitly marked `(est.)`.

### Fixed
- **Unverified throughput claim:** `README.md` stated the NAT + `virtio` migration took the VM from 5 Mbps to 800+ Mbps. Neither figure was ever benchmarked and the numbers appeared nowhere else in the repository. Replaced with a measurement taken from inside the VM (~210-290 Mbps across four samples) and the observed pre-migration symptom (a Docker pull stalled at ~50% after an hour). Recorded in `TROUBLESHOOTING.md` #7 along with the command used, and noted there that the pre-migration figure was never benchmarked.

## [1.7.0] - 2026-07-29
### Added
- **Single source of truth config:** Added `config/node.json` for VM name, RAM, CPU cores, disk size, and ISO URL, plus a shared `scripts/Get-LabConfig.ps1` loader. `01-host-prep.ps1`, `02-provision-node.ps1`, `03-autoinstall-node.ps1`, `04-connect-node.ps1`, and `Deploy-Node.ps1` all read from it now instead of each hardcoding (and risking drifting out of sync on) their own defaults -- `SRE-Node-01` was previously duplicated independently across four separate files. Explicit command-line arguments still override the config file per-run.

## [1.6.0] - 2026-07-29
### Fixed
- **Stage 01 restart loop:** `bcdedit /enum "{current}"` was mangled by PowerShell's native-argument marshalling and always returned an error instead of real BCD data, making the idempotency check fail closed and re-demand a restart on every run regardless of actual state. Switched to bare `bcdedit /enum`.
- **Stage 02 delete failure:** the VM-wipe path called `unregistervm --delete` without checking if the VM was still running, which fails with "locked for a session" and cascades into every subsequent `VBoxManage` call. Added the same power-off-if-running guard `03-autoinstall-node.ps1` already had.

### Changed
- **Documentation:** Tightened README wording ("fully automated" → "automated", "instant remote access" → names the one-time Tailscale device approval step). Added TROUBLESHOOTING.md entries for the two fixes above, a false-alarm CPU-spike scenario from an unkilled `yes` loop, and why reaching the VM's Tailscale IP requires Tailscale on the connecting device too (including the host).

## [1.5.0] - 2026-07-29
### Added
- **Observability:** Added `node_exporter` to the Docker Compose stack and configured Prometheus to scrape host-level metrics.
- **CI/CD Pipeline:** Added a new parallel Ubuntu runner job to validate the `docker-compose.yml` configuration on pull requests and pushes.

### Changed
- **Secrets Management:** Moved the Grafana admin password from plaintext in `docker-compose.yml` to a `.env` file (with `.env.example` template) and removed plaintext secrets from the repository.
- **Security:** Switched from interactive password authentication to dynamic SSH key injection via cloud-init. Scripts no longer prompt for passwords, enabling true zero-touch provisioning.
- **Documentation:** Updated `README.md` to reflect true zero-touch passwordless SSH key authentication and adjusted the marketing tone. Added troubleshooting steps for console-login fallback.

## [1.4.0] - 2026-07-27
### Added
- **CI/CD Pipeline:** Implemented a GitHub Actions workflow to automatically lint PowerShell scripts using `PSScriptAnalyzer` on every push.
- **Documentation:** Appended CI/CD pipeline details to `README.md`.

### Fixed
- Resolved multiple `PSScriptAnalyzer` warnings across deployment scripts (`Write-Host`, empty catch blocks, unused variables).

## [1.3.0] - 2026-07-23
### Changed & Fixed
| Component | Issue/Feature | Resolution |
| :--- | :--- | :--- |
| **Networking Architecture** | Severe "dial-up" packet drops when bridging VM to Windows Wi-Fi 6 cards | Switched VirtualBox from Bridged to **NAT** and added the `virtio` driver for maximum gigabit performance. |
| **Port Forwarding** | NAT breaks direct IP access from host | Added explicit VirtualBox port forwarding rules (`2222` for SSH, `3000` for Grafana, `9090` for Prometheus). |
| **IP Discovery** | ARP spoofing and GuestProperty fetches were complex and brittle | Removed IP discovery entirely. Scripts now reliably poll `localhost:2222` to detect VM readiness. |
| **PowerShell Redirection** | Scripts failed to find `ssh.exe` on 32-bit processes due to `SysWOW64` redirection | Implemented a dynamic `$env:WINDIR\sysnative` path fallback to cleanly resolve native Windows OpenSSH binaries regardless of architecture. |
| **Interactive Sudo** | `sudo` failed silently in the background because SSH scripts lacked a TTY | Added the `-t` pseudo-TTY flag to `ssh.exe` calls in scripts `05` and `06` to allow interactive password prompts. |
| **Package Resilience** | Violent VM interruptions caused `apt-get` to permanently lock | Injected `sudo dpkg --configure -a` prior to Docker installation in script `06` to automatically heal corrupted package managers. |
| **Execution Policies** | Scripts blocked by `UnauthorizedAccess` policies | Systematically ran `Unblock-File` across the `scripts/` directory to satisfy Windows security restrictions. |

## [1.2.0] - 2026-07-23
### Added
- Created `Deploy-Node.ps1` master orchestration script to sequentially execute all stages, including an asynchronous wait-loop for the headless OS installation.
- Injected `Start-Transcript` logging into all `scripts/` to automatically generate timestamped, per-host execution logs in the `logs/` directory.
- Created `scripts/05-setup-tailscale.ps1` to automate Tailscale installation for secure remote access.
- Created `scripts/06-setup-monitoring.ps1` to automate Docker and monitoring stack deployment.
- Added `monitoring/` directory containing `docker-compose.yml` and `prometheus.yml` for observability.
- Updated root `README.md` with instructions for executing Phase 2 and Phase 3.
- Added `.gitignore` to prevent tracking of transcript `.log` files and VirtualBox `.iso`/`.vdi` artifacts.

## [1.1.1] - 2026-07-19
### Added
- Created `TROUBLESHOOTING.md` to document critical sysops edge cases.
- Injected `debconf_selections` into `user-data` to suppress interactive `grub-pc` prompts during headless installations on BIOS firmware.

### Fixed
- Replaced a broken/dummy SHA-512 password hash in `user-data` with a newly generated, valid cryptographic hash for the `sysadmin` account.
- Disabled apt network updates during `subiquity` installation via `user-data` to prevent the installer from hanging indefinitely on IPv6/Mirror timeouts.
- Fixed an issue where a silently truncated Ubuntu ISO download would cause physical I/O errors and `Hash Sum mismatch` crashes during `subiquity` installation.
- Explicitly standardized on Legacy BIOS (`--firmware bios`) in `02-provision-node.ps1` to avoid VirtualBox UEFI automated bootloop issues.

## [1.1.0] - 2026-07-19
### Added
- Added `scripts/03-autoinstall-node.ps1` to fully automate the Ubuntu Server OS installation.
- Added `scripts/cloud-init/user-data` and `meta-data` templates to support unattended `subiquity` installation via dynamically generated Virtual Hard Disk (VHD).

## [1.0.2] - 2026-07-19
### Fixed
- Aligned internal script stage numbering (Stage 1/2) with script filenames (01/02) for clarity.
- Fixed a bug in `02-provision-node.ps1` where single `Get-NetAdapter` results lacked a `.Count` property, causing the network selection prompt to break.

## [1.0.1] - 2026-07-19
### Fixed
- Fixed `bcdedit` command failures in `01-host-prep.ps1` by resolving its absolute path (resolves WoW64 and PATH issues) and using double quotes for the `{current}` parameter.

## [1.0.0] - 2026-07-18
### Added
- `.gitignore` for standard PowerShell and VirtualBox artifacts.
- `CHANGELOG.md` to track project history.
- MIT License for open-source distribution.
- Automated Active Network Adapter Detection for VirtualBox bridging.

### Changed
- Reorganized repository structure to follow standard practices (moved scripts to `scripts/` directory).
- Consolidated fragmented documentation into a single root `README.md`.
- Converted `02-provision-node.sh` to `02-provision-node.ps1` for native Windows execution without Git Bash.
- Refactored `01-host-prep.ps1` to include `try/catch` error handling, parameterized variables, and idempotent virtualization feature handling.

### Removed
- `01-Setup` directory (replaced by `scripts/`).
- `02-provision-node.sh` (replaced by pure PowerShell equivalent).
