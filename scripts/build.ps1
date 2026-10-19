$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Out = Join-Path $Root "build"
New-Item -ItemType Directory -Force -Path $Out | Out-Null

if (-not (Get-Command nasm -ErrorAction SilentlyContinue)) {
    throw "NASM is required. Install it and ensure nasm.exe is on PATH."
}

& nasm -f bin (Join-Path $Root "boot/boot.asm") -o (Join-Path $Out "boot.bin")
if ($LASTEXITCODE -ne 0) { throw "NASM failed assembling boot sector." }
& nasm -f bin (Join-Path $Root "kernel/kernel.asm") -o (Join-Path $Out "kernel.bin")
if ($LASTEXITCODE -ne 0) { throw "NASM failed assembling kernel." }

$Boot = [IO.File]::ReadAllBytes((Join-Path $Out "boot.bin"))
$Kernel = [IO.File]::ReadAllBytes((Join-Path $Out "kernel.bin"))
if ($Boot.Length -ne 512) { throw "Boot sector must be exactly 512 bytes; got $($Boot.Length)." }
if ($Kernel.Length -gt 8192) { throw "Kernel exceeds 16 sectors (8192 bytes)." }

$Image = New-Object byte[] (1474560)
[Array]::Copy($Boot, 0, $Image, 0, $Boot.Length)
[Array]::Copy($Kernel, 0, $Image, 512, $Kernel.Length)
$ImagePath = Join-Path $Out "nova-os.img"
[IO.File]::WriteAllBytes($ImagePath, $Image)
$Xorriso = Get-Command xorriso -ErrorAction SilentlyContinue
if (-not $Xorriso) {
    throw "xorriso is required to create nova-os.iso. Install xorriso and ensure xorriso.exe is on PATH."
}
$IsoRoot = Join-Path $Out "iso-root"
New-Item -ItemType Directory -Force -Path $IsoRoot | Out-Null
Copy-Item -Force $ImagePath (Join-Path $IsoRoot "nova-os.img")
& xorriso -as mkisofs -o (Join-Path $Out "nova-os.iso") -V NOVA_OS -b nova-os.img -c boot.cat $IsoRoot
if ($LASTEXITCODE -ne 0) { throw "xorriso failed creating the bootable ISO." }

$Hashes = @(
    "$( (Get-FileHash -Algorithm SHA256 $ImagePath).Hash.ToLower() )  nova-os.img"
    "$( (Get-FileHash -Algorithm SHA256 (Join-Path $Out "nova-os.iso")).Hash.ToLower() )  nova-os.iso"
)
$Hashes | Set-Content -Encoding ascii (Join-Path $Out "SHA256SUMS.txt")
Write-Host "Built floppy image: $ImagePath"
Write-Host "Built bootable ISO: $(Join-Path $Out 'nova-os.iso')"
Write-Host "Boot sector: $($Boot.Length) bytes; kernel: $($Kernel.Length) bytes"
