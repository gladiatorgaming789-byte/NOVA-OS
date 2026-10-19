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
$Hash = (Get-FileHash -Algorithm SHA256 $ImagePath).Hash.ToLower()
"$Hash  nova-os.img" | Set-Content -Encoding ascii (Join-Path $Out "SHA256SUMS.txt")
Write-Host "Built $ImagePath"
Write-Host "Boot sector: $($Boot.Length) bytes; kernel: $($Kernel.Length) bytes"
Write-Host "This is a raw floppy image, not an ISO. Attach it as a floppy in VirtualBox."
