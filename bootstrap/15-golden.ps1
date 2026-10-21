# Builds the read-only Ubuntu 24.04 golden disk that every lab VM is copied from.
# Needs "Hyper-V Administrators". Run 10-host.ps1 first.
#
# One manual step: Ubuntu 24.04 asks "Continue with autoinstall? (yes|no)" on the console.
# The script opens the VM console for you - type  yes  and press Enter. The VM powers off when done (~10-15 min).

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on PS 5.1
. (Join-Path $PSScriptRoot 'lab.config.ps1')
. (Join-Path $PSScriptRoot 'lib\New-SeedIso.ps1')

if (Test-Path $Lab.GoldenVhdx) { "exists  : $($Lab.GoldenVhdx) - delete it first to rebuild"; return }

# 1. Latest 24.04 point-release ISO, verified against Canonical's SHA256SUMS
# PS 5.1 returns this file as byte[] (no text content type), so decode it explicitly
$raw = (Invoke-WebRequest -UseBasicParsing ($Lab.UbuntuRelease + 'SHA256SUMS')).Content
if ($raw -is [byte[]]) { $raw = [Text.Encoding]::ASCII.GetString($raw) }
$line = $raw -split "`n" | ForEach-Object Trim |
    Where-Object { $_ -match 'ubuntu-24\.04(\.\d+)*-live-server-amd64\.iso$' } | Select-Object -Last 1
if (-not $line) { throw "No live-server ISO listed in SHA256SUMS" }
$expected, $isoName = $line -split '\s+\*?', 2
$isoPath = Join-Path $Lab.IsoDir $isoName

if (-not (Test-Path $isoPath)) {
    "download: $isoName (~3 GB)"
    Start-BitsTransfer -Source ($Lab.UbuntuRelease + $isoName) -Destination $isoPath
}
$actual = (Get-FileHash $isoPath -Algorithm SHA256).Hash
if ($actual -ne $expected.Trim().ToUpper()) { throw "SHA256 mismatch for $isoPath`n expected $expected`n actual   $actual" }
"verified: $isoName"

# 2. Autoinstall seed
$seedIso = Join-Path $Lab.IsoDir 'golden-seed.iso'
New-SeedIso -SourceDir (Join-Path $PSScriptRoot 'golden') -IsoPath $seedIso

# 3. Temporary installer VM
$name = 'golden-build'
if (Get-VM -Name $name -ErrorAction SilentlyContinue) { throw "VM '$name' already exists - remove it first" }
New-VM -Name $name -Generation 2 -MemoryStartupBytes 4GB -Path $Lab.VmRoot `
       -NewVHDPath $Lab.GoldenVhdx -NewVHDSizeBytes ($Lab.GoldenSizeGB * 1GB) -SwitchName 'Default Switch' | Out-Null
Set-VM -Name $name -ProcessorCount 4 -StaticMemory -AutomaticCheckpointsEnabled $false
Set-VMFirmware -VMName $name -SecureBootTemplate MicrosoftUEFICertificateAuthority
$dvd = Add-VMDvdDrive -VMName $name -Path $isoPath -Passthru
Add-VMDvdDrive -VMName $name -Path $seedIso
Set-VMFirmware -VMName $name -FirstBootDevice $dvd

Start-VM -Name $name
vmconnect.exe localhost $name
"waiting : type 'yes' in the console; the VM powers off when the install is done"
while ((Get-VM -Name $name).State -ne 'Off') { Start-Sleep -Seconds 15 }

# 4. Keep only the disk, read-only
Remove-VM -Name $name -Force
Remove-Item (Join-Path $Lab.VmRoot $name) -Recurse -Force -ErrorAction SilentlyContinue
Set-ItemProperty $Lab.GoldenVhdx -Name IsReadOnly -Value $true
"created : $($Lab.GoldenVhdx) (read-only)"
