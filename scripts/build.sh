#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
mkdir -p "$OUT"

command -v nasm >/dev/null 2>&1 || {
  echo "error: NASM is required (https://www.nasm.us/)" >&2
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
if [[ "$kernel_size" -gt 8192 ]]; then
  echo "error: kernel is larger than the 16 sectors loaded by the bootloader ($kernel_size bytes)" >&2
  exit 1
fi

# 1.44 MiB floppy image; kernel starts at sector 2.
dd if=/dev/zero of="$OUT/nova-os.img" bs=512 count=2880 status=none
dd if="$OUT/boot.bin" of="$OUT/nova-os.img" conv=notrunc status=none
dd if="$OUT/kernel.bin" of="$OUT/nova-os.img" bs=512 seek=1 conv=notrunc status=none
sha256sum "$OUT/nova-os.img" > "$OUT/SHA256SUMS.txt"
printf 'Built: %s\nBoot sector: %s bytes\nKernel: %s bytes\n' "$OUT/nova-os.img" "$boot_size" "$kernel_size"
echo "This is a raw floppy image, not an ISO. Attach it as a floppy in VirtualBox."
