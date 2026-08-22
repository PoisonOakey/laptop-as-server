# Troubleshooting Guide

>This document captures the known issues, edge cases, and sysops debugging efforts encountered while building this automated VirtualBox provisioner. If you run into bizarre behavior during the installation, check here first.

---

## 1. The "Truncated ISO" / Hash Sum Mismatch Bug

**Symptoms:**
- The automated installation (`03-autoinstall-node.ps1`) crashes midway through.
- If you check the background VM screen, it's frozen on a Subiquity error log.
- Extracting the Python traceback reveals `apt-get install grub-pc` failing with:
  ```text
  Err:8 file:/cdrom noble/main amd64 os-prober amd64 1.81ubuntu4
    Hash Sum mismatch
  E: Read error - read (5: Input/output error)
  ```

**Root Cause:**
The `01-host-prep.ps1` script uses `curl.exe` (or `Invoke-WebRequest`) to download the Ubuntu ISO. If your internet connection drops or times out during this 3.4 GB download, the file will be saved partially (e.g., stopping at 2.4 GB). However, since the file exists on the disk, subsequent runs of `01-host-prep.ps1` will assume it was successfully downloaded and skip fetching it.
VirtualBox will mount this truncated ISO without complaining. The boot files at the start of the ISO work perfectly, but as soon as the installer reaches the end of the filesystem to extract packages like `os-prober` or `grub-pc`, it hits a physical end-of-file I/O error and crashes the entire installation.

**Resolution:**
Always verify the SHA256 checksum of the downloaded ISO. If you encounter this bug:
1. Delete the corrupted ISO from your lab directory (`$HOME\server-lab\*.iso`).
2. Re-run `01-host-prep.ps1` and ensure the download reaches 100% (approx 3.4 GB).

---

## 2. VirtualBox UEFI Firmware Boot Loop

**Symptoms:**
- Switching the VM's firmware from standard BIOS to UEFI (`--firmware efi`) causes the VM to drop into the `UEFI Interactive Shell v2.2` instead of booting the Ubuntu ISO.
- Manually navigating the UEFI file system (`FS0:\EFI\BOOT\BOOTX64.EFI`) allows the ISO to boot, but automation is completely broken.

**Root Cause:**
VirtualBox's UEFI implementation is notoriously finicky with Linux ISOs. By default, it expects the EFI bootloaders to be in a highly specific path and fails to automatically fall back to the CD-ROM EFI partition in certain unattended scenarios.

**Resolution:**
For optimal automation compatibility, this project explicitly forces **Standard BIOS** (`--firmware bios`). Ubuntu Server's autoinstaller fully supports BIOS installations, and it circumvents the VirtualBox UEFI bootloader bugs entirely.

---

## 3. The Interactive `grub-pc` Prompt (Unattended Block)

**Symptoms:**
- During an automated Ubuntu installation on a Standard BIOS system, the installation pauses indefinitely.
- Viewing the VM screen reveals a purple `debconf` prompt asking the user which disk to install the GRUB bootloader to (e.g., `/dev/sda`).
- This completely breaks the "headless" and "unattended" nature of the script.

**Root Cause:**
When installing via legacy BIOS, the `grub-pc` package is updated or installed. By default, `debconf` notices it is a new installation and defensively prompts the user to confirm the Master Boot Record (MBR) disk location to avoid overwriting existing bootloaders.

**Resolution:**
We pre-answer the prompt from `user-data` using cloud-init's `grub_dpkg` module, which seeds the `grub-pc/install_devices` debconf question before the package is configured:
```yaml
  grub_dpkg:
    enabled: true
    grub_pc_install_devices:
      - /dev/sda
```
This forces `grub-pc` to silently install to `/dev/sda` without hanging the installation.

> **Historical note:** earlier revisions of this project wrote the answer as a raw `debconf_selections` block. It was replaced by `grub_dpkg`, which is the supported cloud-init module for this exact question and does not depend on getting the debconf line format right by hand. Some older commit messages and CHANGELOG entries still refer to `debconf_selections`; the seeding in `user-data` is what is actually in force.

---

## 4. The Silent IPv6 / Apt-Get Mirror Hang

**Symptoms:**
- The automated installation proceeds normally but gets permanently stuck on the `installing kernel` step.
- The VM's CPU usage might sit around 0% for the installation processes.
- Jumping into the hidden installer terminal (TTY2 via `Alt+F2`) and running `ps auxf` reveals that the `apt-get` process is running `/usr/lib/apt/methods/http`, but has accumulated zero recent CPU time and is completely hung.

**Root Cause:**
By default, Ubuntu's installer attempts to connect to `archive.ubuntu.com` to download the latest kernel updates during installation. If IPv6 traffic is blackholed on the path, or the mirror is unresponsive, `apt-get` can hang indefinitely without timing out, permanently freezing the unattended installation. This was first hit on the bridged network adapter used before 1.3.0, but the failure is a property of the mirror fetch itself, not of the adapter -- it is equally reachable under NAT, which is why the mitigation stayed in place after the migration.

**Resolution:**
To enforce a deterministic, offline build that completely ignores internet mirrors during the installation phase, we configure `cloud-init` to disable updates. 
This block must be present in `user-data`:
```yaml
  apt:
    disable_suites: [updates, security]
```
*(You can safely run `apt update && apt upgrade` via SSH after the machine boots normally.)*

---

## 5. Invalid / Dummy Password Hash

**Symptoms:**
- The VM successfully installs and boots to the `login:` prompt.
- Entering the correct username and password repeatedly results in `Login incorrect`.
- SSH access is similarly denied due to authentication failure.

**Root Cause:**
`cloud-init` requires passwords to be provided as SHA-512 cryptographic hashes in the `user-data` file. If a dummy hash (or a hash that corresponds to a different password) is mistakenly injected into `user-data`, `cloud-init` will faithfully write that invalid hash to the VM's `/etc/shadow` file during installation. Once the VM boots, you will be permanently locked out.

**Resolution:**
Generate a mathematically valid SHA-512 crypt hash for your desired password and inject it into the `user-data` identity block. On Linux systems, this can be generated via `mkpasswd -m sha-512`. On Windows, you can use Python with the `passlib` module. Once corrected, you must re-provision and reinstall the VM to apply the new hash.

---

## 6. Blind Hypervisor -- Why There Is No IP Discovery At All

**Symptoms (historical):**
- `04-connect-node.ps1` failed to retrieve the VM's IP address, timing out after 20 retries with `Could not retrieve IP address. Ensure the VM has finished the OS installation and has rebooted.`

**Root Cause:**
The connection script originally used `VBoxManage guestproperty get` to ask the guest for its DHCP address. That feature depends entirely on the `virtualbox-guest-utils` daemon running inside the VM — and because this project configures a strictly offline installation (APT network updates disabled to avoid the IPv6 hang in item 4), the guest additions package is never downloaded or installed. The host had no way to learn the address.

**Resolution:**
IP discovery was removed rather than repaired. The architecture moved to NAT with fixed port-forwards (item 7), so the node's address is not a runtime unknown to be discovered — it is always `127.0.0.1`, reached on `2222` (SSH), `3000` (Grafana), and `9090` (Prometheus). `04-connect-node.ps1` now polls TCP `127.0.0.1:2222` until SSH answers, which tests the thing that actually matters (can we reach it?) instead of inferring it from an address lookup that needed an agent we deliberately do not install.

If you do want the guest's own address for some other reason, log into the console via the VirtualBox GUI and run `ip a`. Under NAT it will be a private `10.0.2.x` address that is not routable from the host — which is precisely why the port-forwards exist.

> **Note:** the error message quoted above no longer exists in any script. It is preserved here because searching for it is how you would land on this entry.

---

## 7. Dial-up Speeds / Wi-Fi Bridging Packet Drop

**Symptoms:**
- The VM installs successfully, but `apt-get` downloads (or Docker image pulls) crawl at dial-up speeds. Observed in practice: a Docker image pull stalled at roughly 50% after an hour.
- Pinging the VM shows severe packet loss.

**Root Cause:**
VirtualBox Bridged Networking has a fatal flaw when bridged over modern Wi-Fi adapters (such as Intel Wi-Fi 6 cards). Because a single Wi-Fi station association generally does not allow multiple MAC addresses, VirtualBox employs a MAC-translation workaround that frequently causes massive packet drops. The default `Intel PRO/1000 MT` network emulation exacerbates this.

**Resolution:**
The architecture was migrated entirely to **NAT**. The VM shares the host's internet connection, and no packet drops were observed after the change. The `virtio` paravirtualized network driver was also applied (`--nictype1 virtio`) to improve throughput. Host access is handled via VirtualBox Port Forwarding.

Measured after the migration: **~210-290 Mbps** (four samples: 294 / 225 / 223 / 212 Mbps), taken from inside the VM against a Cloudflare CDN endpoint, so the figure covers the whole path (guest → NAT → host Wi-Fi → ISP → CDN):
```bash
curl -s -o /dev/null -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=52428800'
```
The pre-migration figure was never benchmarked, so only the qualitative symptom above is on record for it.

---

## 8. Missing `ssh.exe` on 64-bit Windows

**Symptoms:**
- The deployment scripts fail with `CommandNotFoundException` for `C:\Windows\System32\OpenSSH\ssh.exe`, even though OpenSSH is installed and the file physically exists on the disk.

**Root Cause:**
If you run the scripts from a 32-bit PowerShell process (such as a 32-bit VS Code terminal) on a 64-bit Windows installation, Windows aggressively engages the "File System Redirector". Any attempt to execute a binary in `C:\Windows\System32` is silently redirected to `C:\Windows\SysWOW64`. Because OpenSSH does not ship a 32-bit binary in `SysWOW64`, PowerShell reports that the file does not exist.

**Resolution:**
The provisioning scripts implement a dynamic path fallback. They first check for the existence of `$env:WINDIR\sysnative\OpenSSH\ssh-keygen.exe` (a virtual alias that forces 32-bit applications to access the true 64-bit `System32` folder) before falling back to the standard path.

> This originally applied to `ssh.exe` and `scp.exe` in the configuration stages as well. Those stages are now Ansible roles running from WSL, which uses the Linux OpenSSH client and is unaffected. The fallback remains in `02-provision-node.ps1` and `03-autoinstall-node.ps1`, which still call `ssh-keygen.exe` on the Windows side.

---

## 9. Background Installations Failing Silently

**Symptoms:**
- Tailscale or Docker fails to install, but the PowerShell orchestration script reports `[OK] Monitoring Stack Deployed!` without throwing any visible errors.

**Root Cause:**
When PowerShell automates SSH commands that include `sudo` (e.g., `ssh user@ip "sudo apt-get install docker"`), the Linux server cannot interactively prompt you for the `sysadmin` password because the SSH session was not allocated a terminal. `sudo` simply crashes silently in the background, terminating the installation.

**Resolution:**
Two separate fixes were needed, and for a long time only the first was in place.

The `-t` flag (pseudo-TTY) was added to all SSH commands in scripts `05` and `06`. This forces OpenSSH to allocate a true terminal over the network, allowing the Linux `sudo` binary to securely pass its interactive password prompt back to your Windows PowerShell window. That addressed the *cause* of the failure.

It did not address why the failure was **silent**. `$ErrorActionPreference = 'Stop'` does not apply to native executables — a failing `ssh.exe` only sets `$LASTEXITCODE`, and PowerShell continues to the next line. Both scripts ran the remote command and then printed their success banner unconditionally, so any remote failure was reported as success. Stage 06's payload is a six-command chain, which made it worse: a failure gave no indication which step died.

Both scripts were fixed to check `$LASTEXITCODE` after every `ssh`/`scp` call and throw with the exit status, so the banner could only print on a run that actually succeeded. This is the same defect class as the stale-medium failure in item 14, and it was ultimately fixed by hand in four separate scripts.

That repetition is why configuration management moved to Ansible. `05-setup-tailscale.ps1` and `06-setup-monitoring.ps1` no longer exist — the `tailscale` and `monitoring` roles replaced them, and in Ansible a play halts at the failing task and names it. The reporting is structural rather than a convention each script has to remember. `Deploy-Node.ps1` applies the same discipline to the Ansible invocation itself: it checks the exit status and fails loudly rather than printing a completion banner over a failed run. See the Architecture section of the [README](../README.md).

---

## 10. Locked Out After Switching to SSH Key Auth

**Symptoms:**
- `ssh -p 2222 sysadmin@127.0.0.1` hangs or is rejected after a fresh install.
- `03-autoinstall-node.ps1` either failed before completing, or completed but the injected key doesn't match the one on your machine (e.g. you ran it once, generated a key, then deleted `~/.ssh` before a second run).

**Root Cause:**
`user-data` sets `allow-pw: false`, so SSH password authentication is disabled entirely — the VM only accepts the public key that was rendered into `user-data` at install time (`03-autoinstall-node.ps1` reads `~/.ssh/id_ed25519.pub` or `id_rsa.pub`, generating one if neither exists, and writes it into a throwaway copy under `$LabDir`, never into the tracked template). If that key is later regenerated, moved, or the render step silently used a stale/empty value, SSH access breaks.

**Resolution:**
This only disables *SSH* password login — the account password (`sysadmin`, see the `identity` block in `user-data`) still works for a **local console login**, since that's unaffected by the SSH daemon setting:
1. Open the VM directly in the VirtualBox GUI (not headless) and log in at the console with `sysadmin` / the password documented in `user-data`.
2. From the console, fix `~/.ssh/authorized_keys` manually, or re-run `03-autoinstall-node.ps1` (which will re-provision with your current public key) to reinstall cleanly.

The script also fails loudly (`exit 1`) before writing `user-data` at all if it can't read back a well-formed `ssh-...` public key, specifically to avoid ever shipping a VM with authorized-keys empty and SSH password auth disabled.

---

## 11. Infinite "Restart Required" Loop in Stage 01

**Symptoms:**
- `01-host-prep.ps1` reports `CRITICAL: Hyper-V features were modified. A system restart is REQUIRED before running Stage 2.` and throws, telling you to reboot.
- You reboot, run `Deploy-Node.ps1` again, and it demands the exact same restart again -- forever, even though nothing is actually changing on the system.

**Root Cause:**
The BCD idempotency check called `bcdedit /enum "{current}"` to see whether `hypervisorlaunchtype` was already off before touching it. PowerShell's native-argument marshalling mangles the curly-brace `"{current}"` token when passed through the call operator (`&`), so `bcdedit` returns `The specified entry type is invalid` instead of real boot configuration data. `Select-String` then never finds the `hypervisorlaunchtype` line, the check always concludes "not yet disabled," and the script re-triggers the restart requirement on every single run regardless of actual state.

**Resolution:**
The check was changed to call plain `bcdedit /enum` (no entry ID), which enumerates the active boot entries by default and parses cleanly through PowerShell -- avoiding the malformed argument entirely. This matches how the corresponding `bcdedit /set hypervisorlaunchtype off` call already omits the ID for the same reason. To confirm the fix on your own machine, run `01-host-prep.ps1` twice: the second run should report `[OK] BCD hypervisor launch type is already disabled.` and proceed straight to Stage 2 with no restart demanded.

---

## 12. Grafana Shows CPU Pegged at 100%+ and It Won't Come Down

**Symptoms:**
- The "Node Exporter Full" dashboard (Grafana ID `1860`) shows CPU usage ramp up to 100% (or higher, on multi-core panels) and stay there indefinitely.
- This is often self-inflicted while intentionally load-testing the dashboard, e.g. running `yes > /dev/null &` a few times over SSH to confirm the graphs actually move.

**Root Cause:**
`yes` writes to stdout in an infinite loop with no natural exit, so each backgrounded `yes > /dev/null &` permanently pins one CPU core until explicitly killed. The usual mistake: running `kill` with no argument. Bash's `kill` builtin requires a PID or job spec to know what to terminate — `kill` alone just prints its usage string and kills nothing, silently leaving every backgrounded `yes` process running. This isn't a bug in the monitoring stack; Grafana/Prometheus are correctly reporting real, ongoing load from `/proc` via `node_exporter` (see the item 1 fix in `docs/CHANGELOG.md` 1.5.0) — it's proof the pipeline works, not a symptom of it breaking.

**Resolution:**
Give `kill` an actual target:
```bash
kill %1 %2 %3        # by job number, if you backgrounded a few in the same shell
kill 3518 3520 3521  # by PID, from `jobs -l` or `ps aux | grep yes`
pkill yes             # simplest -- kills every process literally named "yes"
```
CPU usage on the Grafana dashboard should drop back down within one scrape interval (`scrape_interval: 15s` in `monitoring/prometheus.yml`) plus a few seconds to settle.

---

## 13. Can't Reach Grafana/Prometheus via the Tailscale IP -- Not Even From the Host Machine

**Symptoms:**
- `http://<tailscale-ip>:3000` (or `:9090`) times out from your phone, another laptop, *and* even from the Windows machine that's hosting the VM itself.
- `Test-NetConnection -ComputerName <tailscale-ip> -Port 3000` fails both the TCP and ping checks from the host.
- The VM itself shows up fine in the Tailscale admin console with a valid `100.x.x.x` address, and `tailscale up` completed successfully inside the VM.

**Root Cause:**
The `tailscale` Ansible role only installs and authenticates Tailscale **inside the guest VM** (as did `05-setup-tailscale.ps1` before it). It never touches the Windows host. A Tailscale IP (`100.64.0.0/10`) is only reachable by a device that is itself running the Tailscale client and signed into the same tailnet -- there's no route to it otherwise, the same way there's no route to another company's internal VPN just because you know an IP on it. If the connecting device (host laptop, phone, etc.) was never enrolled, `100.x.x.x` addresses simply don't resolve for it, regardless of any Docker/firewall configuration on the VM side.

**Resolution:**
This is intentionally **not** automated by the pipeline, and that's a deliberate design choice, not a gap: which personal devices join your tailnet is a decision for the operator, not something a VM-provisioning script should silently do to your own laptop as a side effect. To actually reach the VM remotely:
1. Install Tailscale on whichever device you want to reach it from (e.g. on Windows: `winget install -e --id Tailscale.Tailscale`; there's an app for iOS/Android/macOS/Linux too).
2. Sign into the **same** Tailscale account/tailnet used for the VM.
3. Then `http://<tailscale-ip>:3000` becomes reachable from that device.

Note that if you're physically at the host machine, you don't need any of this -- `http://localhost:3000` already works via the existing VirtualBox NAT port-forward. Tailscale only matters for devices that *aren't* the host.

> **If the restart demand genuinely persists across reboots, check *how* you rebooted.** Windows ships with Fast Startup enabled by default, which makes "Shut down" a hybrid operation: the kernel session is hibernated to `hiberfil.sys` and restored on next power-on rather than reinitialised. Boot-time settings like `hypervisorlaunchtype` may not take effect. **"Restart" always performs a full cold boot and bypasses Fast Startup**, so it is the more reliable choice here — the opposite of most people's intuition.

---

## 14. Stage 03 Fails With "UUID Does Not Match The Value Stored In The Media Registry"

**Symptoms:**
- The first run of the pipeline works. Every run after it dies in `03-autoinstall-node.ps1`:
  ```text
  VBoxManage.exe: error: UUID {5d20ce9c-...} of the medium 'C:\Users\...\cidata.vhd'
  does not match the value {f62e50f9-...} stored in the media registry
  ('C:\Users\...\.VirtualBox\VirtualBox.xml')
  ```
- Worse, on older revisions the script carried on regardless: it slept 90 seconds, typed into a VM that was never started, and printed `Automated installation has been triggered!` on a run that did nothing at all.

**Root Cause:**
Two independent defects that compounded.

First, `03-autoinstall-node.ps1` rebuilds `cidata.vhd` from scratch on every run, so the new file gets a new UUID. VirtualBox, however, still holds the *previous* UUID — sometimes in the VM's own machine XML as `SATA Controller-ImageUUID-1-0`, sometimes in the global media registry in `VirtualBox.xml`, depending on how the earlier run ended. Attaching a file whose UUID disagrees with the stored one is rejected outright.

Second, `$ErrorActionPreference = 'Stop'` **does not apply to native executables**. A failing `VBoxManage` call only sets `$LASTEXITCODE`; PowerShell carries on to the next line. So the failed `startvm` never stopped the script.

**Resolution:**
Stage 03 now clears the stale registration before rebuilding the disk — detaching the medium if the slot is occupied, and closing the registry entry if one is registered for that path. The entry is looked up by location and closed *by UUID*, because closing by path makes VirtualBox reopen the file and re-run the very comparison that is already failing.

Both places matter: a run interrupted at different points leaves the stale reference in different places, so the machine-XML detach and the media-registry `closemedium` are each load-bearing on their own.

Explicit `$LASTEXITCODE` checks were added after the `storageattach` and `startvm` calls so a failure is now loud and immediate instead of producing a success banner.

---

## 15. "REMOTE HOST IDENTIFICATION HAS CHANGED!" After Rebuilding The VM

**Symptoms:**
- After wiping and re-provisioning the node, the Ansible run (or a manual `ssh -p 2222 sysadmin@127.0.0.1`) prints:
  ```text
  @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
  @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
  @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
  Offending ED25519 key in C:\Users\<you>/.ssh/known_hosts:4
  ```
- The pipeline still completes, which makes it easy to ignore.

**Root Cause:**
Reinstalling the OS generates a brand-new SSH host key, but the old node's key is still pinned in `~/.ssh/known_hosts` against the same address — every VM in this project answers on `[127.0.0.1]:2222`, so each rebuild collides with its predecessor's entry.

The scripts pass `-o StrictHostKeyChecking=no`, which is often assumed to cover this. It does not. That option only suppresses the confirmation prompt for hosts that are **unknown**; a host whose key has **changed** is treated as a possible man-in-the-middle regardless. Key-based auth still succeeds (which is why the pipeline finishes), but password and keyboard-interactive auth are disabled for that connection and the warning is printed every time.

**Resolution:**
`02-provision-node.ps1` now drops the stale pin immediately after creating the VM, before any OS is installed on it:
```powershell
& $sshKeygenPath -R "[127.0.0.1]:2222"
```
`ssh-keygen -R` is a no-op when there is no matching entry, so this is safe on a first run. Note the bracket syntax — a non-default port is part of the `known_hosts` key, and `ssh-keygen -R 127.0.0.1` will not match an entry stored as `[127.0.0.1]:2222`.

---

## 16. Stage 01 Demands A Restart Again After Installing WSL

**Symptoms:**
- The pipeline has been running cleanly, with stage 01 reporting `[OK] BCD hypervisor launch type is already disabled.` on every run.
- You install WSL to set up the Ansible control node.
- The next run of `Deploy-Node.ps1` reports `[*] Disabling BCD hypervisor launch type...` and stops with `CRITICAL: Hyper-V features were modified. A system restart is REQUIRED`.

**Root Cause:**
This is not a regression — it is the two halves of the project disagreeing, and stage 01 winning.

`wsl --install` enables the `VirtualMachinePlatform` feature and sets `hypervisorlaunchtype` to `Auto`, because WSL 2 is a virtual machine and needs the Windows hypervisor. `01-host-prep.ps1` exists to do the exact opposite: it disables that feature and sets `hypervisorlaunchtype` to `Off` so VirtualBox gets direct access to the CPU's virtualization extensions rather than running as a client of Hyper-V.

So installing WSL undoes what stage 01 established, and the next run correctly re-applies it. A BCD change only takes effect at boot, hence the restart.

**Resolution:**
Reboot once and continue. It should not recur, **provided the WSL distribution is WSL 1**.

WSL 1 is a syscall translation layer with no VM and no hypervisor dependency, so it keeps working after the hypervisor is disabled. That is the main reason [ANSIBLE-SETUP.md](ANSIBLE-SETUP.md) specifies WSL 1 rather than WSL 2. If the distribution is WSL 2, the conflict is permanent and the two will fight on every run — convert it:

```powershell
wsl --set-version <distro> 1
```

Note that **Docker Desktop stops working** while the hypervisor is disabled, since its backing distribution is WSL 2. That is a pre-existing tension on any host running both Docker Desktop and VirtualBox, and it does not affect this pipeline — the monitoring stack runs in Docker *inside the VM*, not on the Windows host.

If the restart demand repeats after rebooting, see the Fast Startup note at the end of item 11.

Note that Docker Desktop re-enables the hypervisor the same way `wsl --install` does, and it does so on install *and* on update. If a host that has been working starts booting the guest at a crawl, that is the first thing to check — see item 17.

---

## 17. VM Fails To Start, Or Boots At A Crawl, On A Host That Worked Yesterday

**Symptoms:**

Two distinct failures with one shared trigger. Both appear only as `VERR_UNRESOLVED_ERROR`, which names neither.

*Failure A — the VM never starts:*
```
VBoxManage.exe: error: Unresolved (unknown) host platform error. (VERR_UNRESOLVED_ERROR)
VBoxManage.exe: error: Details: code E_FAIL (0x80004005), component ConsoleWrap, interface IConsole
```
followed by the SSH poll retrying twenty times against a port that will never open.

*Failure B — the VM starts but never finishes booting:* the script reports the forward is open, `ssh` then times out "during banner exchange", and the console sits on an early boot line for ten minutes while `VBoxHeadless` burns a core.

**Root Cause:**

*Failure A is the Windows commit limit, not free RAM.* Commit is the total memory Windows has promised across everything running — physical RAM plus page file. VirtualBox commits the guest's entire RAM at power-on, so a 4 GB guest needs a 4 GB promise (plus a few hundred MB of its own overhead) available in one go, regardless of how much is merely *free*. The VM's own log names it precisely:

```
Unhandled error 1455
pgmR3PhysInitAndLinkRamRange failed: ... VERR_UNRESOLVED_ERROR
```

Windows error 1455 is `ERROR_COMMITMENT_LIMIT`. Observed on a 15.8 GB host with a 20 GB commit limit and 2.1 GB free, against a guest asking for 4 GB. Nothing about the host had changed except what was running on it — Docker Desktop's WSL 2 backend alone held 1.7 GB.

*Failure B is item 16 arriving without the restart demand.* The Windows hypervisor is holding VT-x, so VirtualBox falls back to running as a Hyper-V client. Its log says so plainly:

```
NEM: NEMR3Init: Snail execution mode is active!
```

The guest still boots, roughly 25x slower. Booting is thousands of small device operations and each one pays the toll, so a 30-second boot becomes fifteen minutes or never. Note that Virtualization-Based Security keeps the hypervisor loaded even with Hyper-V features off and Docker Desktop closed — check `(Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard).VirtualizationBasedSecurityStatus`, where `2` means enabled and running.

**Resolution:**

`04-connect-node.ps1` now checks both before booting and names whichever is wrong, so neither has to be diagnosed from a VirtualBox error code again.

For Failure A, in order of preference:

| Fix | Trade-off |
| :--- | :--- |
| Close what is holding the commit — Docker Desktop first, then `wsl --shutdown` | Free, immediate, temporary |
| Lower `ram_mb` in `config/node.json` | Permanent, and the node has less headroom |
| Raise the Windows page file | Permanent and costs only disk. The real fix if the limit is close to installed RAM |

Check what is actually available before blaming the VM:
```powershell
[math]::Round((Get-CimInstance Win32_OperatingSystem).FreeVirtualMemory / 1MB, 1)
```

For Failure B, run `01-host-prep.ps1` as Administrator and reboot — it disables the hypervisor and the conflicting Windows features. If it has already run and `HypervisorPresent` is still `True`, the setting has not taken effect because BCD changes are boot-time only, so the reboot is not optional:

```powershell
(Get-CimInstance Win32_ComputerSystem).HypervisorPresent   # must be False
```

**Worth knowing:** stage 04 can be run on its own to wake a node that is merely powered off, and doing so skips stage 01 — which is what re-establishes both conditions. If the host has since gained Docker Desktop or a WSL 2 distribution, stage 04 alone will not save you. That is why the preflight lives in stage 04 rather than only in stage 01.

---

## Conclusion
SysOps automation relies heavily on environmental consistency. When debugging headless installations, always rule out physical file corruption (like the truncated ISO) before tearing apart your bootloader configurations!
