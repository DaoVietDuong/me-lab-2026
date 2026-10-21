# Builds a cloud-init NoCloud seed ISO (volume label "cidata") from a folder,
# using the IMAPI2 COM API built into Windows - no extra tools needed.
#   . .\lib\New-SeedIso.ps1
#   New-SeedIso -SourceDir .\seed\hub -IsoPath E:\HyperV\lab\hub\seed.iso

if (-not ('LabIsoWriter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices.ComTypes;
public static class LabIsoWriter {
    public static void Write(string path, object comStream, int blockSize, int totalBlocks) {
        IStream s = (IStream)comStream;
        byte[] buf = new byte[blockSize];
        using (FileStream fs = File.Create(path)) {
            for (int i = 0; i < totalBlocks; i++) {
                s.Read(buf, blockSize, IntPtr.Zero);
                fs.Write(buf, 0, blockSize);
            }
        }
    }
}
'@
}

function New-SeedIso {
    param(
        [Parameter(Mandatory)] [string] $SourceDir,
        [Parameter(Mandatory)] [string] $IsoPath,
        [string] $VolumeName = 'cidata'
    )
    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 3          # ISO9660 + Joliet (keeps names like "user-data")
    $fsi.VolumeName = $VolumeName
    $fsi.Root.AddTree((Resolve-Path $SourceDir).Path, $false)
    $img = $fsi.CreateResultImage()
    New-Item -ItemType Directory -Force (Split-Path $IsoPath) | Out-Null
    [LabIsoWriter]::Write($IsoPath, $img.ImageStream, $img.BlockSize, $img.TotalBlocks)
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($fsi) | Out-Null
}
