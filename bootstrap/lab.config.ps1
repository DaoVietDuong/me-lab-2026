# Single source of truth for the lab VMs and networks (matches the practice plan's tables).
# Dot-sourced by the 1x/2x bootstrap scripts.

$Lab = @{
    VmRoot        = 'E:\HyperV\lab'
    IsoDir        = 'E:\HyperV\iso'
    GoldenVhdx    = 'E:\HyperV\lab\golden-2404.vhdx'
    GoldenSizeGB  = 8                       # smallest VM disk; clones are grown from it
    UbuntuRelease = 'https://releases.ubuntu.com/24.04/'
    User          = 'lab'
    SshPubKey     = "$env:USERPROFILE\.ssh\id_ed25519.pub"
    Domain        = 'lab'

    HostMgmtIp    = '10.0.0.1'
    HubMgmtIp     = '10.0.0.2'
    SpokePrefixes = @('10.10.0.0/24', '10.20.0.0/24')

    Switches = @(
        @{ Name = 'lab-mgmt';   Type = 'Internal' }
        @{ Name = 'spoke-lab';  Type = 'Private'  }
        @{ Name = 'spoke-test'; Type = 'Private'  }
    )

    # Static MACs so cloud-init network-config can match NICs to names (eth0, eth1, ...).
    Vms = [ordered]@{
        'hub' = @{ Cpu = 1; RamGB = 1; DiskGB = 8; Role = 'hub'
            Nics = @(
                @{ Name = 'eth0'; Switch = 'Default Switch'; Mac = '00155D0A0010'; Dhcp = $true }
                @{ Name = 'eth1'; Switch = 'lab-mgmt';       Mac = '00155D0A0011'; Ip = '10.0.0.2/24' }
                @{ Name = 'eth2'; Switch = 'spoke-lab';      Mac = '00155D0A0012'; Ip = '10.10.0.1/24' }
                @{ Name = 'eth3'; Switch = 'spoke-test';     Mac = '00155D0A0013'; Ip = '10.20.0.1/24' }
            ) }
        'lab-node1' = @{ Cpu = 4; RamGB = 5; DiskGB = 24; Role = 'node'
            Nics = @( @{ Name = 'eth0'; Switch = 'spoke-lab'; Mac = '00155D0A0111'; Ip = '10.10.0.11/24'; Gw = '10.10.0.1' } ) }
        'lab-node2' = @{ Cpu = 4; RamGB = 5; DiskGB = 24; Role = 'node'
            Nics = @( @{ Name = 'eth0'; Switch = 'spoke-lab'; Mac = '00155D0A0112'; Ip = '10.10.0.12/24'; Gw = '10.10.0.1' } ) }
        'lab-node3' = @{ Cpu = 4; RamGB = 5; DiskGB = 24; Role = 'node'
            Nics = @( @{ Name = 'eth0'; Switch = 'spoke-lab'; Mac = '00155D0A0113'; Ip = '10.10.0.13/24'; Gw = '10.10.0.1' } ) }
        'tester' = @{ Cpu = 2; RamGB = 2; DiskGB = 14; Role = 'tester'
            Nics = @( @{ Name = 'eth0'; Switch = 'spoke-test'; Mac = '00155D0A0210'; Ip = '10.20.0.10/24'; Gw = '10.20.0.1' } ) }
    }
}
