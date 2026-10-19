# Boot diagnostics

## Marker meanings

The prototype writes one-letter checkpoints to VGA text mode. The kernel also mirrors its checkpoints from **E** onward to COM1 (38400 baud, 8-N-1); the bootloader's earlier **B/K/D** markers are currently VGA-only:

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

The outputs are `build/nova-os.img` (raw floppy image) and `build/nova-os.iso` (BIOS-bootable ISO). The build requires both NASM and `xorriso`.

## VirtualBox setup

1. Create a VM using a 64-bit x86 guest type if available.
2. Keep Enable EFI disabled; this prototype uses legacy BIOS.
3. Attach `build/nova-os.iso` to the VM's **Optical Drive** under Storage, then start the VM. Leave EFI disabled; this ISO uses legacy BIOS El Torito floppy emulation. Alternatively, attach `build/nova-os.img` as a floppy.
4. In VirtualBox, enable **Serial Ports** for the VM, select **Port 1**, set **Port Number** to `0x3F8` and **IRQ** to `4`, and choose **Raw File** with a path such as `C:\\nova-serial.log`. Enable the port and start the VM. The file should contain the kernel checkpoints (`E`, `G`, `C`, `J`, `P`, and, if 64-bit entry succeeds, `L`).
5. Note the last visible marker. A successful NASM build is not proof of a successful boot.

## Current limitations

- This is a tiny boot-chain proof of concept, not a usable operating system.
- The bootloader uses legacy CHS floppy reads and reads 16 sectors starting at sector 2.
- The kernel must remain at or below 8192 bytes.
- There is no IDT or exception handler yet, so CPU faults may hang or reset without a useful error.
- A successful build does not prove the image boots. Runtime validation must be recorded separately.
