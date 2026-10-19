# NOVA-OS

**NOVA-OS is an experimental operating system built from scratch for x86-64 PCs and Oracle VirtualBox.** It is not a Linux distribution and does not use the Linux kernel.

> **Status:** early x86-64 kernel prototype with an interrupt-driven keyboard queue, PIT timer, BIOS E820 memory discovery, a bitmap physical-page allocator, and a tiny interactive shell. It is not a complete operating system yet.

## Project goals

- Custom BIOS boot path and kernel; no Linux kernel or existing OS distribution.
- Build a bootable disk image for Oracle VirtualBox.
- Serial and on-screen diagnostics so a failed boot has useful evidence.
- Small, testable milestones: boot sector → loaded stage → protected mode → long mode → keyboard input and shell.
- Reproducible builds and automated static/build checks.

## Current development focus

The earlier local prototype displayed **B**, **K**, and **E** in VirtualBox, but did not show later checkpoints. Those letters were intended as diagnostics, not proof that every later CPU-mode transition works:

| Marker | Intended meaning |
| --- | --- |
| B | BIOS boot sector began executing |
| K | boot code reached its kernel/stage loading checkpoint |
| E | loaded code reached its entry point |
| G | GDT / protected-mode setup checkpoint |
| C | protected-mode checkpoint |
| J | long-mode preparation checkpoint |
| P | paging / long-mode activation checkpoint |
| L | 64-bit long-mode entry checkpoint |

The markers alone do not prove that every transition worked. The current source and automated build are the source of truth; use the freshly rebuilt ISO from a successful GitHub Actions artifact rather than an older image.

## Build

Builds use NASM and xorriso in GitHub Actions. Each successful workflow run publishes a `nova-os-boot-tested-image` artifact containing the rebuilt `build/nova-os.iso`, raw floppy image, checksums, and serial logs. **Use `build/nova-os.iso` from the downloaded artifact ZIP** in VirtualBox; the root-level `nova-os.iso` is retained for comparison and may be an older image. Configure the VM for BIOS boot (EFI off).

## Testing policy

A successful compilation is not the same as a successful boot. Results will be labeled separately:

1. **Build check** — source assembles and image layout is valid.
2. **Emulator boot check** — image is actually run in QEMU or another emulator and reaches the expected marker.
3. **Interactive shell check** — QEMU sends keyboard input and checks the command response.\n4. **VirtualBox check** — confirmed by a real VirtualBox boot.

Never infer a later checkpoint merely because an earlier one appeared.

## Planned milestones

1. Reproducible BIOS boot image and reliable serial/VGA diagnostics.
2. Stable protected-mode and x86-64 long-mode transitions with explicit failure checkpoints.
3. Minimal IDT, CPU exception reporting, PIC/PIT interrupts, and queued PS/2 keyboard input.
4. BIOS E820 memory-map discovery and a bitmap allocator for 4 KiB physical pages below 1 GiB. The `memory` command reports free pages; `alloc` and `free` exercise a single test allocation.
5. Virtual memory improvements and a kernel heap.
6. Preemptive multitasking and scheduler.
7. Filesystem and persistence.
8. User programs and system calls.
9. Graphical environment, applications, networking, and broader device support.

## Repository layout

- boot/ — BIOS boot sector and early boot stages.
- kernel/ — kernel entry and core code.
- scripts/ — image/build/test helpers.
- docs/ — architecture notes, debugging procedures, and the [code audit](docs/code-audit.md).
- .github/workflows/ — automated build checks.

Contributions and bug reports should include the build command, emulator/VirtualBox settings, and the last visible diagnostic marker.
