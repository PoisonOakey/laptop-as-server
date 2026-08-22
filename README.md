# ZTP — Zero-Touch Provisioning Pipeline

<p align="center">
  <img alt="Tech stack: PowerShell, WSL, VirtualBox, Ubuntu, cloud-init, Ansible, Docker, Tailscale, Prometheus, node_exporter, Alertmanager, Grafana, GitHub Actions, Pester" src="https://github-readme-tech-stack.vercel.app/api/cards?title=Tech%20Stack&theme=github_dark&align=center&titleAlign=center&width=570&gap=12&lineHeight=8&fontSize=18&hideBg=true&borderRadius=6&border=%2330363d&titleColor=%238b949e&lineCount=4&line1=,PowerShell,auto;,WSL,auto;virtualbox,VirtualBox,auto;ubuntu,Ubuntu,auto;&line2=yaml,cloud--init,auto;ansible,Ansible,auto;docker,Docker,auto;tailscale,Tailscale,auto;&line3=prometheus,Prometheus,auto;prometheus,node--exporter,auto;prometheus,Alertmanager,auto;grafana,Grafana,auto;&line4=githubactions,GitHub%20Actions,auto;,Pester,auto;" />
</p>

<p align="center">
  <a href="https://github.com/PoisonOakey/ztp-linux-node/actions/workflows/ci.yml"><img alt="CI status" src="https://github.com/PoisonOakey/ztp-linux-node/actions/workflows/ci.yml/badge.svg?branch=main" /></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/github/license/PoisonOakey/ztp-linux-node" /></a>
  <img alt="Last commit" src="https://img.shields.io/github/last-commit/PoisonOakey/ztp-linux-node" />
</p>

> A PowerShell, cloud-init, and Ansible IaC pipeline that installs, configures, and monitors a headless Linux node from a single command — no installer prompts, no hypervisor wizard.

---

## 🚀 Overview

Infrastructure as Code across four layers, each owned by the tool that should own it.

```mermaid
%%{init: {'themeVariables': { 'background': '#ffffff'}}}%%
flowchart TD
    classDef prov fill:#e6f3ff,stroke:#0066cc,stroke-width:2px,color:#003366,rx:5px,ry:5px;
    classDef conf fill:#e6ffe6,stroke:#009933,stroke-width:2px,color:#004d1a,rx:5px,ry:5px;
    classDef obs fill:#fff4e6,stroke:#cc6600,stroke-width:2px,color:#663300,rx:5px,ry:5px;

    style Provisioning fill:#ffffff,stroke:#dee2e6,stroke-width:2px,stroke-dasharray: 5 5,color:#333
    style Configuration fill:#ffffff,stroke:#dee2e6,stroke-width:2px,stroke-dasharray: 5 5,color:#333
    style Observability fill:#ffffff,stroke:#dee2e6,stroke-width:2px,stroke-dasharray: 5 5,color:#333

    subgraph Provisioning [Provision &amp; Install -- PowerShell, cloud-init]
        direction LR
        A[01: Host Prep]:::prov --> B[02: VM Provisioning]:::prov
        B --> C[03: OS Installation]:::prov
        C --> D[04: Boot &amp; Await SSH]:::prov
    end

    subgraph Configuration [Configure -- Ansible]
        direction LR
        E[docker role]:::conf --> F[monitoring role]:::conf
        F --> G[tailscale role]:::conf
    end

    subgraph Observability [Observe -- left running on the node]
        direction LR
        H[node_exporter]:::obs --> I["Prometheus<br/>5 alert rules"]:::obs
        I --> J[Grafana dashboard]:::obs
        I --> K[Alertmanager]:::obs
        K --> L["Discord<br/>+ runbook link"]:::obs
    end

    D --> E
    F --> H
```

Provisioning is Windows-specific by design — VirtualBox on a Windows host. Configuration is not: the Ansible roles target any Debian-family host.

---

## 🛑 The Problem

| Problem | Why it matters |
|---|---|
| ⌨️ **Interactive OS install** | The Ubuntu installer prompts for disk, bootloader, and credentials before networking exists. |
| 🖱️ **VM defined through a GUI** | Specs set in the VirtualBox wizard are not versioned, reviewable, or repeatable. |
| 🔓 **Inbound access** | Reaching SSH from outside the LAN requires a router port-forward to the VM. |
| 📉 **No metric history** | VirtualBox reports point-in-time figures, readable only at the host's screen. |

---

## 📸 The Result

After the pipeline finishes, this is what is already running.

![Grafana Node Overview dashboard](docs/images/dashboard.png)

Datasource and dashboard are provisioned from this repository, never clicked in. Panels mirror the alert rules, so what is watched and what pages you are the same signals.

![TargetDown alert firing in Prometheus](docs/images/alert-firing.png)

`node_exporter` stopped on purpose. `TargetDown` waited out its `for: 2m` grace period, then fired with the labels defined in [`alert_rules.yml`](monitoring/alert_rules.yml). The other four rules stayed quiet.

![Alert delivered to Discord, firing then resolved](docs/images/discord.png)

Alertmanager delivers the alert, then the resolved notice once the container returns. The runbook link rides on the notification itself.

---

## 📂 Repository Structure

```text
📦 ztp-linux-node/
│
├── ⚙️ Deploy-Node.ps1           # Master execution entrypoint
│
├── 📁 config/                   # Single source of truth: VM name, hardware sizing, ISO URL
│
├── 📁 scripts/                  # 01-04: provision the machine (PowerShell)
│   ├── 📁 cloud-init/           # Unattended Ubuntu autoinstall configuration
│   └── 📁 tests/                # Pester tests for Get-LabConfig
│
├── 📁 ansible/                  # Configure the running node (docker, tailscale, monitoring)
│
├── 📁 monitoring/               # Observability configuration
│   ├── 🐳 docker-compose.yml    # Prometheus & Grafana stack
│   └── 📁 tests/                # promtool unit tests for the alert rules
│
├── 📁 docs/                     # Changelog, troubleshooting, roadmap, Ansible setup
│
└── 📁 logs/                     # Per-stage execution transcripts (gitignored)
```

---

## 🧠 Key Engineering Decisions

| Decision | Why |
|---|---|
| **Provisioning ≠ configuration** | PowerShell drives `VBoxManage`, `diskpart` and `bcdedit`. Ansible owns desired state. Stage 04 runs `VBoxManage`, so it stays PowerShell |
| **Idempotency is proved, not claimed** | A second run must report `changed=0`. The Grafana password persists on the control node so it cannot rotate and break that |
| **Secrets never enter git** | The SSH key renders into a throwaway `user-data`. Grafana and Tailscale credentials stay on the control node, gitignored |
| **Every run recovers** | Stale media registrations and `known_hosts` pins cleared on rebuild. Mounted VHDs released in a `finally` |
| **No silent success** | `$LASTEXITCODE` checked after every native call. The install loop fails on a deadline instead of hanging |
| **NAT over bridged** | Bridged Wi-Fi stalled Docker pulls at ~50% after an hour. NAT + `virtio` measured ~210-290 Mbps |

Each of these came from a failure. The ones with a root-cause writeup are in [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

---

## 🔧 Prerequisites

> [!IMPORTANT]
> An Ansible control node on **WSL 1**. One-time setup: [ANSIBLE-SETUP.md](docs/ANSIBLE-SETUP.md).
> Without it the pipeline provisions the VM, then stops and says so.

VirtualBox 7+ and the Ubuntu ISO are handled by stage 01 — nothing to install by hand.

### Optional credentials

| File | Get it from | Without it |
| :--- | :--- | :--- |
| `ansible/.tailscale_auth_key` | Tailscale → Settings → Keys, **reusable** | Approve the device in a browser once |
| `ansible/.discord_webhook_url` | Discord → text channel → ⚙️ → Integrations → Webhooks | Alerts still group and silence, they just go nowhere |

```bash
echo 'tskey-auth-...' > ansible/.tailscale_auth_key
echo 'https://discord.com/api/webhooks/...' > ansible/.discord_webhook_url
```

Both are read from the control node once and are gitignored.

---

## ⚡ Execution

1. Open PowerShell **as Administrator**.
2. Run `.\Deploy-Node.ps1`. It prompts once for the node's `sudo` password.
3. Prove convergence — the second run must report `changed=0`:
   ```bash
   cd ansible && ANSIBLE_CONFIG=$PWD/ansible.cfg ansible-playbook site.yml -K
   ```

### Access

| Service | Endpoint |
| :--- | :--- |
| **Grafana** | http://localhost:3000 — user `admin`, dashboard already provisioned |
| **Prometheus** | http://localhost:9090 — `/targets` for scrape health, `/alerts` for rule state |
| **Alertmanager** | http://localhost:9093 — grouped alerts and silences |
| **SSH** | `ssh -p 2222 sysadmin@127.0.0.1` |

The Grafana password is generated once and reused — `cat ansible/.grafana_admin_password`, gitignored.

---

## 📈 Metrics

| Metric | Manual Provisioning | Automated Pipeline |
|---|---|---|
| **Time to provision** | 20-30 min, interactive (est.) | 3 min 53 s to a booted OS, 7 min 35 s end-to-end (single run, 2 vCPU / 4 GB) |
| **Reproducibility** | Undocumented manual steps | Single command against `config/node.json` |
| **Remote access** | Router port forwarding | Tailscale mesh VPN, zero inbound ports |
| **Host visibility** | No history, host screen only | `node_exporter` scraped every 15s, viewable from any device on the tailnet |

---

## 📚 Documentation
- [CHANGELOG.md](docs/CHANGELOG.md) - Version history and bug fixes.
- [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) - Detailed root-cause analysis for advanced edge cases.
- [RUNBOOK.md](docs/RUNBOOK.md) - One section per alert: what it means, how to confirm it, what to do.
- [FUTURE-ROADMAP.md](docs/FUTURE-ROADMAP.md) - Tracker: what is built, what is next, what is deliberately not being built.
- [ANSIBLE-SETUP.md](docs/ANSIBLE-SETUP.md) - Control-node prerequisites on Windows, and why WSL 1 rather than WSL 2.

---

## ⚙️ CI/CD Pipeline

Seven gates on every push and PR, in five parallel jobs. All must pass.

| Gate | What it checks |
| :--- | :--- |
| **Lint** | `Invoke-ScriptAnalyzer` over every script, and that `config/node.json` has every key the stages read |
| **Unit tests** | `Pester` against `Get-LabConfig`, the one script with logic rather than side effects |
| **Compose** | `docker compose config` against `.env.example` |
| **Ansible** | `--syntax-check` and `ansible-lint` over the playbook and all four roles |
| **Secret scan** | `gitleaks` across the full history, not just the tip |
| **Observability config** | `promtool` and `amtool` over the Prometheus and Alertmanager configs, cloud-init, the dashboard, and the [runbook](docs/RUNBOOK.md) links |
| **Alert behaviour** | Synthetic series driven through the six rules: each must fire when it should, and stay quiet when it should not |

Dependabot proposes updates monthly, for Actions and the pinned images.

Worth running before you push:

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error,Warning -ExcludeRule PSUseBOMForUnicodeEncodedFile
Invoke-Pester -Path scripts/tests
```

```bash
docker run --rm -v "$PWD/monitoring:/etc/prometheus:ro" --entrypoint promtool \
  prom/prometheus:v3.13.2 test rules /etc/prometheus/tests/alert_rules_test.yml
```

The rest are one-liners in [`ci.yml`](.github/workflows/ci.yml), which is the copy that matters.

CI never builds a VM or connects to a node. A green check means the config is valid and the rules behave — not that the pipeline provisions anything.

> [!IMPORTANT]
> The real test is running `site.yml` twice. The second run must report `changed=0`.
