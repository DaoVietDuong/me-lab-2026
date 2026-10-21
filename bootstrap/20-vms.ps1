# Creates the 5 lab VMs from the golden disk: each gets its own full copy (no differencing disks),
# static RAM, static MACs and a NoCloud seed ISO with hostname, user, SSH key and static network.
# Needs "Hyper-V Administrators". Run 10-host.ps1 and 15-golden.ps1 first.
#   .\20-vms.ps1          create VMs (skips any that already exist)
#   .\20-vms.ps1 -Start   also start them: hub first, then the rest once the hub answers on SSH

param([switch] $Start)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab.config.ps1')
. (Join-Path $PSScriptRoot 'lib\New-SeedIso.ps1')

if (-not (Test-Path $Lab.GoldenVhdx)) { throw "Golden disk missing - run 15-golden.ps1 first" }
if (-not (Test-Path $Lab.SshPubKey))  { throw "No SSH key at $($Lab.SshPubKey) - run: ssh-keygen -t ed25519" }
$pubKey = (Get-Content $Lab.SshPubKey -Raw).Trim()

$secure = Read-Host -AsSecureString "Console password for user '$($Lab.User)' (Hyper-V console only; SSH is key-only)"
$password = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
if ([string]::IsNullOrEmpty($password)) { throw "Empty password - cloud-init's chpasswd rejects it" }
$yamlPassword = "'" + ($password -replace "'", "''") + "'"

function ConvertTo-LinuxMac([string] $mac) { (($mac.ToLower() -split '(..)' | Where-Object { $_ }) -join ':') }

function Get-NetworkConfig($vm) {
    $lines = @('version: 2', 'ethernets:')
    foreach ($nic in $vm.Nics) {
        $lines += "  $($nic.Name):"
        $lines += "    match: {macaddress: `"$(ConvertTo-LinuxMac $nic.Mac)`"}"
        $lines += "    set-name: $($nic.Name)"
        if ($nic.Dhcp) { $lines += '    dhcp4: true'; continue }
        $lines += "    addresses: [$($nic.Ip)]"
        if ($nic.Gw) {
            $lines += "    routes: [{to: default, via: $($nic.Gw)}]"
            $lines += "    nameservers: {addresses: [$($nic.Gw)], search: [$($Lab.Domain)]}"
        }
    }
    $lines -join "`n"
}

function Get-HubExtras {
    $hosts = foreach ($n in $Lab.Vms.Keys) {
        $ip = ($Lab.Vms[$n].Nics | Where-Object { $_.Ip -and $_.Switch -ne 'lab-mgmt' } | Select-Object -First 1).Ip -replace '/\d+$'
        "      $ip $n.$($Lab.Domain) $n"
    }
    @"
packages: [nftables, dnsmasq]
write_files:
  - path: /etc/sysctl.d/90-lab-forward.conf
    content: |
      net.ipv4.ip_forward = 1
  - path: /etc/lab/nftables.conf
    content: |
      #!/usr/sbin/nft -f
      # TEMPORARY: forward everything, NAT to the internet via eth0.
      # Replaced by the default-deny policy in Build step 1.
      flush ruleset
      table inet lab_nat {
        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          oifname "eth0" ip saddr { 10.10.0.0/24, 10.20.0.0/24 } masquerade
        }
      }
  - path: /etc/dnsmasq.d/lab.conf
    content: |
      interface=eth1
      interface=eth2
      interface=eth3
      bind-interfaces
      domain=$($Lab.Domain)
      local=/$($Lab.Domain)/
      expand-hosts
      no-hosts
      addn-hosts=/etc/lab/hosts
      resolv-file=/run/systemd/resolve/resolv.conf
  - path: /etc/lab/hosts
    content: |
$($hosts -join "`n")
  - path: /etc/chrony/conf.d/lab.conf
    content: |
      # The hub is the time source for both spokes
      allow 10.0.0.0/8
runcmd:
  - sysctl --system
  - install -m 0755 /etc/lab/nftables.conf /etc/nftables.conf
  - systemctl enable --now nftables
  - systemctl restart dnsmasq
  - systemctl restart chrony
"@
}

function Get-SpokeExtras($gw) {
    @"
write_files:
  - path: /etc/chrony/sources.d/lab-hub.sources
    content: |
      server $gw iburst
runcmd:
  - sed -i 's/^pool /#pool /' /etc/chrony/chrony.conf
  - systemctl restart chrony
"@
}

function Get-UserData($name, $vm) {
    $common = @"
#cloud-config
hostname: $name
fqdn: $name.$($Lab.Domain)
manage_etc_hosts: true
users:
  - name: $($Lab.User)
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: false
    ssh_authorized_keys:
      - $pubKey
chpasswd:
  expire: false
  users:
    - {name: $($Lab.User), password: $yamlPassword, type: text}
ssh_pwauth: false
"@
    if ($vm.Role -eq 'hub') { $extra = Get-HubExtras } else { $extra = Get-SpokeExtras $vm.Nics[0].Gw }
    $common + "`n" + $extra
}

function Write-Utf8NoBom($path, $text) {
    [IO.File]::WriteAllText($path, ($text -replace "`r`n", "`n") + "`n", (New-Object Text.UTF8Encoding $false))
}

foreach ($name in $Lab.Vms.Keys) {
    $vm = $Lab.Vms[$name]
    if (Get-VM -Name $name -ErrorAction SilentlyContinue) { "exists  : VM $name - skipped"; continue }

    $dir = Join-Path $Lab.VmRoot $name
    New-Item -ItemType Directory -Force $dir | Out-Null

    # Seed ISO (built in a temp folder that is deleted again - it holds the console password)
    $seedDir = Join-Path $env:TEMP "lab-seed-$name"
    New-Item -ItemType Directory -Force $seedDir | Out-Null
    Write-Utf8NoBom (Join-Path $seedDir 'meta-data') "instance-id: $name-$(Get-Date -Format yyyyMMddHHmmss)`nlocal-hostname: $name"
    Write-Utf8NoBom (Join-Path $seedDir 'user-data') (Get-UserData $name $vm)
    Write-Utf8NoBom (Join-Path $seedDir 'network-config') (Get-NetworkConfig $vm)
    $seedIso = Join-Path $dir 'seed.iso'
    New-SeedIso -SourceDir $seedDir -IsoPath $seedIso
    Remove-Item $seedDir -Recurse -Force

    # Own full copy of the golden disk, grown to the plan's size (cloud-init grows the partition)
    $vhd = Join-Path $dir "$name.vhdx"
    Copy-Item $Lab.GoldenVhdx $vhd
    Set-ItemProperty $vhd -Name IsReadOnly -Value $false
    if ($vm.DiskGB -gt $Lab.GoldenSizeGB) { Resize-VHD -Path $vhd -SizeBytes ($vm.DiskGB * 1GB) }

    New-VM -Name $name -Generation 2 -MemoryStartupBytes ($vm.RamGB * 1GB) -VHDPath $vhd -Path $Lab.VmRoot | Out-Null
    Set-VM -Name $name -ProcessorCount $vm.Cpu -StaticMemory -AutomaticCheckpointsEnabled $false `
           -CheckpointType Production -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
    Set-VMFirmware -VMName $name -SecureBootTemplate MicrosoftUEFICertificateAuthority `
                   -FirstBootDevice (Get-VMHardDiskDrive -VMName $name)
    Add-VMDvdDrive -VMName $name -Path $seedIso
    Enable-VMIntegrationService -VMName $name -Name 'Guest Service Interface'

    Get-VMNetworkAdapter -VMName $name | Remove-VMNetworkAdapter
    foreach ($nic in $vm.Nics) {
        Add-VMNetworkAdapter -VMName $name -Name $nic.Name -SwitchName $nic.Switch -StaticMacAddress $nic.Mac
    }
    "created : VM $name ($($vm.Cpu) vCPU, $($vm.RamGB) GB, $($vm.DiskGB) GB)"
}

if (-not $Start) { "`nNot started. Re-run with -Start (stop the old Ubuntu 22.04 VMs first - RAM is tight)."; return }

$others = Get-VM | Where-Object { $_.State -eq 'Running' -and -not $Lab.Vms.Contains($_.Name) }
if ($others) { Write-Warning "Other VMs are running ($($others.Name -join ', ')). The lab needs ~25 GB RAM; starts may fail." }

Start-VM -Name 'hub'
"waiting : hub SSH on $($Lab.HubMgmtIp):22 (first boot installs nftables + dnsmasq, a few minutes)"
$deadline = (Get-Date).AddMinutes(10)
while (-not (Test-NetConnection $Lab.HubMgmtIp -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    if ((Get-Date) -gt $deadline) { throw "hub did not answer on SSH within 10 minutes - check its console" }
    Start-Sleep -Seconds 10
}
"ready   : hub"
foreach ($name in $Lab.Vms.Keys | Where-Object { $_ -ne 'hub' }) { Start-VM -Name $name; "started : $name" }
