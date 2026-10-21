#Requires -RunAsAdministrator
# Host networking for the lab: folders, Hyper-V switches, host IP on lab-mgmt, routes to the spokes.
# Idempotent: existing items are reported and left alone, never overwritten.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab.config.ps1')

foreach ($dir in $Lab.VmRoot, $Lab.IsoDir) {
    if (Test-Path $dir) { "exists  : $dir" } else { New-Item -ItemType Directory $dir | Out-Null; "created : $dir" }
}

if (-not (Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue)) {
    throw "'Default Switch' not found - the hub needs it for internet egress."
}

foreach ($sw in $Lab.Switches) {
    $existing = Get-VMSwitch -Name $sw.Name -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.SwitchType -ne $sw.Type) { Write-Warning "switch $($sw.Name) exists as $($existing.SwitchType), expected $($sw.Type) - not touching it" }
        else { "exists  : switch $($sw.Name) ($($sw.Type))" }
        continue
    }
    New-VMSwitch -Name $sw.Name -SwitchType $sw.Type | Out-Null
    "created : switch $($sw.Name) ($($sw.Type))"
}

# Host side of lab-mgmt: 10.0.0.1/24
$ifAlias = 'vEthernet (lab-mgmt)'
$hasIp = Get-NetIPAddress -InterfaceAlias $ifAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object IPAddress -eq $Lab.HostMgmtIp
if ($hasIp) { "exists  : $($Lab.HostMgmtIp) on $ifAlias" }
else {
    New-NetIPAddress -InterfaceAlias $ifAlias -IPAddress $Lab.HostMgmtIp -PrefixLength 24 | Out-Null
    "created : $($Lab.HostMgmtIp)/24 on $ifAlias"
}

# Spokes are reachable only through the hub
$ifIndex = (Get-NetAdapter -Name $ifAlias).ifIndex
foreach ($prefix in $Lab.SpokePrefixes) {
    $ok = Get-NetRoute -DestinationPrefix $prefix -PolicyStore PersistentStore -ErrorAction SilentlyContinue |
        Where-Object { $_.ifIndex -eq $ifIndex -and $_.NextHop -eq $Lab.HubMgmtIp }
    if ($ok) { "exists  : route $prefix via $ifAlias (persistent)"; continue }
    # Replace any wrong or active-only route with a persistent one pinned to lab-mgmt
    $net, $len = $prefix -split '/'
    route.exe delete $net | Out-Null
    $bits = ('1' * [int]$len).PadRight(32, '0')
    $mask = (0..3 | ForEach-Object { [Convert]::ToInt32($bits.Substring($_ * 8, 8), 2) }) -join '.'
    $result = route.exe -p add $net mask $mask $Lab.HubMgmtIp IF $ifIndex
    # route.exe exits 0 even on failure, so check its output
    if ($result -notmatch 'OK!') { throw "route -p add $net mask $mask $($Lab.HubMgmtIp) failed: $result" }
    "created : route $prefix via $($Lab.HubMgmtIp) (persistent)"
}
