# Boot diagnostics

## Marker meanings

The prototype writes one-letter checkpoints to VGA text mode:

- **B** — BIOS boot sector started.
- **K** — bootloader read the configured kernel sectors and is about to jump to the kernel.
- **D** — BIOS disk read failed.
- **E** — kernel entry was reached in 16-bit real mode.
- **G** — the kernel loaded its GDT and is about to enable protected mode.
- **C** — protected-mode entry completed.
- **J** — long-mode page-table setup reached its checkpoint.
- **P** — paging was enabled and the code is about to far-jump to 64-bit code.
- **L** — 64-bit entry code executed.

These markers localize a failure but do not identify its cause. If the last visible marker is E or G, inspect the instructions immediately after that marker first.

## Build on Windows

1. Install NASM and add nasm.exe to PATH.
2. Open PowerShell in the repository root.
3. Run: powershell -ExecutionPolicy Bypass -File .\scripts\build.ps1
4. The raw floppy image is build\nova-os.img.

## Build on Linux

Install NASM, then run:

    bash scripts/build.sh

The output is build/nova-os.img.

## VirtualBox setup

1. Create a VM using a 64-bit x86 guest type if available.
2. Keep Enable EFI disabled; this prototype uses legacy BIOS.
3. Attach build/nova-os.img as a floppy image. If your VirtualBox version will not attach it as a floppy, use QEMU or convert it to a compatible virtual floppy format.
4. Start the VM and note the last visible marker.

## Current limitations

- This is a tiny boot-chain proof of concept, not a usable operating system.
- The bootloader uses legacy CHS floppy reads and reads 16 sectors starting at sector 2.
- The kernel must remain at or below 8192 bytes.
- There is no IDT or exception handler yet, so CPU faults may hang or reset without a useful error.
- A successful build does not prove the image boots. Runtime validation must be recorded separately.
