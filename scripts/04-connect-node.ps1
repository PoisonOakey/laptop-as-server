<#
.SYNOPSIS
Boots the provisioned node if needed and prints the SSH connection command.

.DESCRIPTION
This script checks if the VM is running. If not, it boots it headlessly.
It then polls the VirtualBox NAT port-forward on 127.0.0.1:2222 until SSH
answers, and prints the connection command. There is no IP discovery -- the
node is always reached over localhost port-forwarding, not a DHCP address.

Before booting it verifies the two host conditions stage 01 establishes: that
the Windows hypervisor is not holding the CPU, and that there is enough commit
available to back the guest's RAM. Both fail in ways VirtualBox reports only as
a generic error, so they are checked by name here.

.PARAMETER VmName
Name of the Virtual Machine. Defaults to the value in config/node.json.
#>
param (
    [string]$VmName
)

# config/node.json is the single source of truth for lab/hardware settings;
# an explicit -VmName argument still overrides it for one-off runs.
. (Join-Path $PSScriptRoot "Get-LabConfig.ps1")
$Config = Get-LabConfig -ConfigPath (Join-Path $PSScriptRoot "..\config\node.json")
if (-not $VmName) { $VmName = $Config.vm_name }

$logDir = Join-Path $PSScriptRoot "..\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Name)
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
Start-Transcript -Path (Join-Path $logDir "$scriptName-$timestamp.log") -Append

$VBoxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"

# A TCP connect to the NAT port-forward succeeds as soon as VirtualBox is
# listening on the host side, whether or not anything answers inside the guest.
# Reading the SSH identification string is the only way to tell "the forward
# exists" from "sshd is up", and reporting the first as success is what turns a
# hung boot into a green result.
function Test-SshBanner {
    param(
        [string]$TargetHost,
        [int]$Port,
        [int]$TimeoutMs = 4000
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($connect)
        $client.ReceiveTimeout = $TimeoutMs
        $buffer = New-Object byte[] 64
        $read = $client.GetStream().Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { return $false }
        return [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read).StartsWith("SSH-")
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# 0. Preflight -- the host conditions stage 01 establishes.
#
# Neither of these is reported usefully by VirtualBox. Both surface as
# VERR_UNRESOLVED_ERROR at power-on, followed by a boot that either never
# finishes or never starts, so they are named here rather than diagnosed later.
Write-Output "Checking host preconditions..."

# Hyper-V holding the CPU does not stop the VM starting, it makes it roughly 25x
# slower -- VirtualBox logs this as "NEM: Snail execution mode is active" and the
# guest takes many minutes to reach a login prompt, if it ever does. Installing
# or updating WSL 2 or Docker Desktop re-enables this behind your back; see
# TROUBLESHOOTING.md #16.
if ((Get-CimInstance Win32_ComputerSystem).HypervisorPresent) {
    Write-Warning "   [!] A Windows hypervisor is active, so VirtualBox cannot use VT-x directly."
    Write-Warning "       The guest will run in 'snail mode' and may take many minutes to boot."
    Write-Warning "       Fix: run 01-host-prep.ps1 as Administrator, then reboot. See TROUBLESHOOTING.md #16."
} else {
    Write-Output "   [OK] No competing hypervisor -- VirtualBox has direct VT-x access."
}

# Windows commits the guest's full RAM at power-on, so this fails on the commit
# limit rather than on free physical memory. Reported as Windows error 1455 in
# the VM's own log and as VERR_UNRESOLVED_ERROR on the console.
# See TROUBLESHOOTING.md #17.
$requiredMb = [int]$Config.ram_mb
$freeCommitMb = [int]((Get-CimInstance Win32_OperatingSystem).FreeVirtualMemory / 1KB)
# VirtualBox needs the guest's RAM plus its own overhead, which runs a few
# hundred MB. 512 covers it without rejecting a host that would have worked.
$headroomMb = 512
if ($freeCommitMb -lt ($requiredMb + $headroomMb)) {
    Stop-Transcript
    throw ("Not enough Windows commit available to start '$VmName'. " +
           "The guest needs ${requiredMb}MB plus ~${headroomMb}MB of overhead, " +
           "and only ${freeCommitMb}MB is free. Close memory-heavy applications " +
           "(Docker Desktop holds a WSL 2 VM), lower ram_mb in config/node.json, " +
           "or raise the Windows page file. See TROUBLESHOOTING.md #17.")
}
Write-Output "   [OK] Commit available: ${freeCommitMb}MB free, ${requiredMb}MB needed."

# 1. Ensure VM is running
$state = & $VBoxManage showvminfo $VmName | Select-String "State:"
if ($state -match "powered off") {
    Write-Output "VM is currently powered off. Booting headlessly..."
    & $VBoxManage startvm $VmName --type headless
    # Without this the script announces "Waiting for OS to boot" after the boot
    # has already failed, then spends a minute retrying a port that will never
    # open. Every other native call in this repository is checked; this one was
    # not.
    if ($LASTEXITCODE -ne 0) {
        Stop-Transcript
        throw ("VBoxManage failed to start '$VmName' (exit $LASTEXITCODE). " +
               "The VM's own log names the cause: " +
               "`$HOME\VirtualBox VMs\$VmName\Logs\VBox.log. " +
               "See TROUBLESHOOTING.md #17 for the memory case.")
    }
    Write-Output "Waiting for OS to boot (this may take a minute)..."
    Start-Sleep -Seconds 15
}

# 2. Wait for sshd inside the guest to answer, not merely for the forward to open
Write-Output "Waiting for VM to expose SSH on localhost:2222..."
$maxRetries = 20
$retryCount = 0
$sshReady = $false

while (-not $sshReady -and $retryCount -lt $maxRetries) {
    if (Test-SshBanner -TargetHost "127.0.0.1" -Port 2222) {
        $sshReady = $true
        break
    }

    Write-Output "SSH not yet available, retrying in 3 seconds... ($($retryCount+1)/$maxRetries)"
    Start-Sleep -Seconds 3
    $retryCount++
}

if ($sshReady) {

    Write-Output "`n=================================================="
    Write-Output "[OK] VM is actively running and forwarded to localhost!"
    Write-Output "You can now connect to your headless node!"
    Write-Output "Run the following command:"
    Write-Output "`n    ssh -p 2222 sysadmin@127.0.0.1"
    Write-Output "`n(Authenticates via your SSH key -- no password needed. See TROUBLESHOOTING.md #10 if that ever fails.)"
    Write-Output "=================================================="
} else {
    Write-Error ("sshd did not answer on localhost:2222. The port-forward may be open " +
                 "while the guest is still booting -- if a hypervisor warning appeared above, " +
                 "that is the cause and the guest is crawling rather than hung. " +
                 "See TROUBLESHOOTING.md #16 and #17.")
}

Stop-Transcript
