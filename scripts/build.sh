#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
mkdir -p "$OUT"

command -v nasm >/dev/null 2>&1 || {
  echo "error: NASM is required (https://www.nasm.us/)" >&2
  exit 1
}
command -v xorriso >/dev/null 2>&1 || {
  echo "error: xorriso is required to create the bootable ISO (install package xorriso)." >&2
  exit 1
}

nasm -f bin "$ROOT/boot/boot.asm" -o "$OUT/boot.bin"
nasm -f bin "$ROOT/kernel/kernel.asm" -o "$OUT/kernel.bin"

boot_size=$(wc -c < "$OUT/boot.bin")
kernel_size=$(wc -c < "$OUT/kernel.bin")
if [[ "$boot_size" -ne 512 ]]; then
  echo "error: boot sector must be 512 bytes, got $boot_size" >&2
  exit 1
fi
if [[ "$kernel_size" -gt 262144 ]]; then
  echo "error: kernel exceeds the bootloader's 512-sector (256 KiB) load limit ($kernel_size bytes)" >&2
  exit 1
fi

# 1.44 MiB floppy image; kernel starts at sector 2.
dd if=/dev/zero of="$OUT/nova-os.img" bs=512 count=2880 status=none
dd if="$OUT/boot.bin" of="$OUT/nova-os.img" conv=notrunc status=none
dd if="$OUT/kernel.bin" of="$OUT/nova-os.img" bs=512 seek=1 conv=notrunc status=none
# Put the complete 1.44 MiB floppy image in the ISO as an El Torito floppy
# emulation boot image. This preserves the BIOS INT 13h floppy reads used by
# the boot sector; a no-emulation CD image would not satisfy that assumption.
ISO_ROOT="$OUT/iso-root"
mkdir -p "$ISO_ROOT"
cp "$OUT/nova-os.img" "$ISO_ROOT/nova-os.img"
xorriso -as mkisofs \
  -o "$OUT/nova-os.iso" \
  -V NOVA_OS \
  -b nova-os.img \
  -c boot.cat \
  "$ISO_ROOT" >/dev/null
sha256sum "$OUT/nova-os.img" "$OUT/nova-os.iso" > "$OUT/SHA256SUMS.txt"
printf 'Built floppy image: %s\nBootable ISO: %s\nBoot sector: %s bytes\nKernel: %s bytes\n' "$OUT/nova-os.img" "$OUT/nova-os.iso" "$boot_size" "$kernel_size"
