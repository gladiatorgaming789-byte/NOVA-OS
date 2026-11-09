#!/usr/bin/env python3
"""Patch the boot sector's kernel-sector count after the kernel is assembled."""
from __future__ import annotations

import math
import sys
from pathlib import Path

SIGNATURE = b"NOVA_KSEC"
MAX_KERNEL_BYTES = 512 * 512
SECTOR_SIZE = 512


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: patch-boot-sector.py BOOT_BIN KERNEL_SIZE_BYTES", file=sys.stderr)
        return 2

    boot_path = Path(sys.argv[1])
    kernel_size = int(sys.argv[2])
    boot = bytearray(boot_path.read_bytes())
    if len(boot) != SECTOR_SIZE:
        raise SystemExit(f"boot sector must be exactly {SECTOR_SIZE} bytes")
    if kernel_size <= 0 or kernel_size > MAX_KERNEL_BYTES:
        raise SystemExit(f"kernel size must be between 1 and {MAX_KERNEL_BYTES} bytes")

    count = math.ceil(kernel_size / SECTOR_SIZE)
    if not 1 <= count <= 512:
        raise SystemExit(f"invalid kernel sector count: {count}")

    offset = boot.find(SIGNATURE)
    if offset < 0:
        raise SystemExit("kernel-sector patch signature not found in boot sector")
    value_offset = offset + len(SIGNATURE)
    if value_offset + 2 > len(boot) - 2:
        raise SystemExit("kernel-sector patch field is outside boot-sector code area")

    boot[value_offset:value_offset + 2] = count.to_bytes(2, "little")
    boot_path.write_bytes(boot)
    print(f"Boot loader configured to read {count} kernel sectors ({kernel_size} bytes).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
