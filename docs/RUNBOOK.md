# Runbook

One section per alert in [`monitoring/alert_rules.yml`](../monitoring/alert_rules.yml). Each rule carries a `runbook_url` annotation pointing here, so the link travels with the notification.

Written for the person woken up by it: what it means, how to confirm it, what to do.

---

## TargetDown

**Severity:** critical · fires after 2 minutes

### What it means

Prometheus has failed to scrape a target. `up` is synthesised by Prometheus itself, so this catches the exporter crashing, the container stopping, and the node disappearing — none of which depend on the target being well enough to report anything.

### Confirm

```bash
curl -s http://127.0.0.1:9090/api/v1/targets | grep -o '"health":"[a-z]*"'
ssh -t -p 2222 sysadmin@127.0.0.1 "sudo docker ps -a --filter name=node_exporter"
```

### Fix

Container stopped or crash-looping:

```bash
ssh -t -p 2222 sysadmin@127.0.0.1 "sudo docker start node_exporter && sudo docker logs --tail 50 node_exporter"
```

Whole node unreachable — check the VM is running, then re-run the pipeline:

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" showvminfo SRE-Node-01 --machinereadable | Select-String '^VMState='
.\scripts\04-connect-node.ps1
```

### If it keeps happening

Repeated flapping usually means the host is under memory pressure and the OOM killer is reaping containers. Check `MemoryPressure` for the same window.

---

## DiskSpaceLow

**Severity:** warning · fires below 15% free, sustained 5 minutes

### What it means

A real filesystem is running out of space. Pseudo-filesystems are excluded because they sit near-full permanently and are never actionable.

### Confirm

```bash
ssh -t -p 2222 sysadmin@127.0.0.1 "df -h --exclude-type=tmpfs --exclude-type=overlay"
```

### Fix

On this node the usual culprit is Docker. Check before deleting anything:

```bash
ssh -t -p 2222 sysadmin@127.0.0.1 "sudo docker system df"
```

Then reclaim, least destructive first:

```bash
# dangling images and stopped containers
ssh -t -p 2222 sysadmin@127.0.0.1 "sudo docker system prune -f"

# journal logs, if /var/log has grown
ssh -t -p 2222 sysadmin@127.0.0.1 "sudo journalctl --vacuum-size=100M"
```

> Do **not** run `docker system prune --volumes` here. It deletes `prometheus_data` and `grafana_data`, which is your metric history and your dashboards.

---

## DiskWillFillIn24Hours

**Severity:** warning · fires when the 1-hour trend projects exhaustion within a day, sustained 30 minutes

### What it means

Free space is falling fast enough to run out within 24 hours, based on `predict_linear` over the last hour. This can fire while the disk still looks healthy — that is the point. A disk at 80% and stable needs nobody; one at 60% and dropping fast does.

### Confirm

Run this in the Prometheus query browser to see the trend rather than the instant:

```promql
predict_linear(node_filesystem_avail_bytes{mountpoint="/"}[1h], 24 * 3600)
```

Negative means projected empty. Compare against actual free space to judge whether it is a real trend or a short burst.

### Fix

Find what is growing:

```bash
ssh -t -p 2222 sysadmin@127.0.0.1 "sudo du -xh --max-depth=2 / 2>/dev/null | sort -rh | head -20"
```

Then as for `DiskSpaceLow`. If the growth is Prometheus itself, the retention period is the lever — it defaults to 15 days.

### False positives

A large one-off write (an image pull, a package upgrade) can trigger this and then resolve on its own. The 30-minute `for` clause absorbs most of them; if it fires and clears within the hour, no action was needed.

---

## MemoryPressure

**Severity:** warning · fires below 10% available, sustained 5 minutes

### What it means

Less than 10% of memory is available. This uses `MemAvailable`, not `MemFree` — free memory excludes reclaimable page cache and looks alarmingly low on a perfectly healthy Linux host. `MemAvailable` is the kernel's own estimate of what a new process could actually get.

### Confirm

```bash
ssh -t -p 2222 sysadmin@127.0.0.1 "free -h && ps aux --sort=-%mem | head -10"
```

### Fix

Identify the consumer first. If it is a container, restart it rather than the node:

```bash
ssh -t -p 2222 sysadmin@127.0.0.1 "sudo docker stats --no-stream"
```

Check whether the kernel has already been killing things:

```bash
ssh -t -p 2222 sysadmin@127.0.0.1 "sudo dmesg -T | grep -i 'out of memory' | tail"
```

If this is chronic rather than a spike, the node is undersized — raise `ram_mb` in [`config/node.json`](../config/node.json) and rebuild.

---

## HighCpuLoad

**Severity:** warning · fires above 2 per core on the 15-minute average, sustained 15 minutes

### What it means

Sustained CPU saturation. Load is divided by core count, so the threshold means the same thing regardless of how the VM is sized. Above 1 per core means work is queuing; above 2 means it is queuing badly.

The 15-minute average and the 15-minute `for` clause are both deliberate — this alert is for sustained load, not spikes.

### Confirm

```bash
ssh -t -p 2222 sysadmin@127.0.0.1 "uptime && top -bn1 | head -15"
```

### Fix

Check the CPU-by-mode panel on the dashboard before assuming it is CPU-bound:

- high `user` — a real workload, find it in `top`
- high `iowait` — the disk is the bottleneck, not the CPU. Check `DiskSpaceLow` too
- high `system` — kernel-side, often heavy network or container churn

A known self-inflicted cause on this node is a stray `yes > /dev/null` loop left from load-testing the dashboard. See [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) #12 — `pkill yes` clears it.

---

## StencilThroughputRegressed

**Severity:** warning · fires below 85% of the node's own 7-day best, sustained 25 hours

### What it means

The node is measurably slower at moving memory than it recently was. `stencil-bench` runs on a daily timer and writes its result to node_exporter's textfile collector; this alert compares the latest figure against the best of the last seven days.

It is deliberately relative rather than a fixed floor. The absolute case is already covered — the `acceptance` role refuses a node below 12 GB/s at provisioning time, which catches gross faults like memory coming up single-channel. This catches the case that floor cannot: a node that passed at 16 GB/s and now manages 13.5. That is a real 15% regression while still being comfortably above any sensible fixed threshold.

The `for: 25h` matters. The measurement only refreshes once a day, so 25 hours means two consecutive daily runs both had to be low. One run that landed while the node was busy will not page anyone.

**What it does not catch:** degradation slower than the seven-day window, which drags the baseline down with it. Hardware decaying over months is invisible to this rule by construction.

### Confirm

Look at the series rather than trusting one sample:

```bash
curl -s 'http://127.0.0.1:9090/api/v1/query?query=stencil_bandwidth_gbytes_per_second' | python3 -m json.tool
```

Then re-measure by hand, which also tells you whether the regression is reproducible or was a one-off:

```bash
ssh -p 2222 sysadmin@127.0.0.1   '~/stencil-bench/build/bench --nx 4096 --ny 4096 --steps 50 --repeats 5'
```

### Fix

Memory bandwidth on this node is shared with the Windows host, so start there:

- **Host contention** — the most likely cause by far. Anything memory-heavy on the host (Docker Desktop's WSL 2 VM, browsers, another VM) competes for the same DRAM. Check the host before the guest
- **Thermal throttling** — sustained load on a laptop CPU drops clocks. Check whether the host has been busy for hours
- **Hypervisor mode** — if VirtualBox has fallen back to running under Hyper-V, everything on the node slows down. `(Get-CimInstance Win32_ComputerSystem).HypervisorPresent` must be `False` on the host; see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) #17
- **A genuinely busy node** — check `HighCpuLoad` and `MemoryPressure`. The benchmark runs `Nice=10` with idle I/O priority, so it yields to real work and will read low on a node that is legitimately loaded

If the figure is reproducibly lower and the host is quiet, the node has actually degraded. Re-provisioning is the honest response; the acceptance gate will refuse it on the way back in if it has not recovered.

**A false positive worth knowing about:** if the benchmark is rebuilt with a faster kernel, the 7-day best jumps and the old figures look like a regression for a week. Expected, and it clears itself.

---

## When an alert fires and you disagree with it

Silence it in Alertmanager rather than deleting the rule. A silence is time-boxed and leaves a record; a deleted rule is invisible in three months when the same thing happens again.

```
http://localhost:9093  ->  Silences  ->  New Silence
```

If a rule is wrong often enough to be annoying, that is a signal to change its threshold or its `for` clause — not to stop measuring.
