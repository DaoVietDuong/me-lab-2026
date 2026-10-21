# Read-only inventory of Hyper-V on this host. Changes nothing.
# Needs membership in "Hyper-V Administrators" (or an elevated shell).
# Output: bootstrap/audit/host-inventory.txt

$ErrorActionPreference = 'Stop'
$out = Join-Path $PSScriptRoot 'audit\host-inventory.txt'
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null

& {
    "# Hyper-V host inventory - $(Get-Date -Format s) - $env:COMPUTERNAME"

    "`n## Host"
    $cs = Get-CimInstance Win32_ComputerSystem
    "RAM GB: {0:N1}" -f ($cs.TotalPhysicalMemory / 1GB)
    Get-PSDrive -PSProvider FileSystem |
        Select-Object Name, @{n='UsedGB';e={[math]::Round($_.Used/1GB,1)}}, @{n='FreeGB';e={[math]::Round($_.Free/1GB,1)}} |
        Format-Table -AutoSize | Out-String
    Get-VMHost | Select-Object VirtualMachinePath, VirtualHardDiskPath | Format-List | Out-String

    "## VMs"
    Get-VM | Select-Object Name, State, Generation, ProcessorCount,
        @{n='StartupGB';e={[math]::Round($_.MemoryStartup/1GB,1)}},
        DynamicMemoryEnabled,
        @{n='AssignedGB';e={[math]::Round($_.MemoryAssigned/1GB,1)}},
        AutomaticCheckpointsEnabled, CheckpointType, Uptime, Path |
        Format-List | Out-String

    "## Disks (with checkpoint chain)"
    foreach ($vm in Get-VM) {
        foreach ($d in Get-VMHardDiskDrive -VMName $vm.Name) {
            $path = $d.Path
            while ($path) {
                $v = Get-VHD -Path $path
                "{0} | {1} | {2} | max {3:N1} GB | file {4:N1} GB" -f $vm.Name, $v.VhdType, $v.Path, ($v.Size/1GB), ($v.FileSize/1GB)
                $path = $v.ParentPath
            }
        }
    }

    "`n## Checkpoints"
    Get-VMSnapshot -VMName * | Select-Object VMName, Name, SnapshotType, CreationTime, ParentSnapshotName |
        Format-Table -AutoSize | Out-String

    "## Switches"
    Get-VMSwitch | Select-Object Name, SwitchType, NetAdapterInterfaceDescription | Format-Table -AutoSize | Out-String

    "## VM network adapters"
    Get-VMNetworkAdapter -VMName * | Select-Object VMName, Name, SwitchName, MacAddress, DynamicMacAddressEnabled,
        @{n='IPs';e={$_.IPAddresses -join ', '}} | Format-Table -AutoSize | Out-String

    "## Firmware / Secure Boot (Gen 2 only)"
    Get-VM | Where-Object Generation -eq 2 | ForEach-Object { Get-VMFirmware -VMName $_.Name } |
        Select-Object VMName, SecureBoot, SecureBootTemplate | Format-Table -AutoSize | Out-String
} | Tee-Object -FilePath $out

Write-Host "`nWritten to $out"
