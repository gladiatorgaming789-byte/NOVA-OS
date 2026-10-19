# NOVA-OS

**NOVA-OS is an experimental operating system built from scratch for x86-64 PCs and Oracle VirtualBox.** It is not a Linux distribution and does not use the Linux kernel.

> **Status:** early x86-64 kernel prototype with a polling keyboard and a tiny interactive command shell. It is not a complete operating system yet.

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

The old ISO and its source are **not currently stored in this repository**, so the markers alone are not enough to diagnose that exact binary. This repository is becoming the source of truth going forward.

## Build

Builds use NASM and xorriso in GitHub Actions. Each successful workflow run publishes a `nova-os-boot-tested-image` artifact containing the rebuilt `build/nova-os.iso`, raw floppy image, checksums, and serial logs. **Use `build/nova-os.iso` from the downloaded artifact ZIP** in VirtualBox; the root-level `nova-os.iso` is retained for comparison and may be an older image. Configure the VM for BIOS boot (EFI off).

## Testing policy

A successful compilation is not the same as a successful boot. Results will be labeled separately:

1. **Build check** — source assembles and image layout is valid.
2. **Emulator boot check** — image is actually run in QEMU or another emulator and reaches the expected marker.
3. **VirtualBox check** — confirmed by a real VirtualBox boot.

Never infer a later checkpoint merely because an earlier one appeared.

## Planned milestones

1. Reproducible BIOS boot image and reliable serial/VGA diagnostics.
2. Stable protected-mode and x86-64 long-mode transitions with explicit failure checkpoints.
3. Interrupt handling, memory map, physical memory allocator, and kernel panic reporting.
4. Keyboard input and a tiny interactive shell (polling PS/2 input; initial commands: `help`, `about`, `clear`, `reboot`).
5. Filesystem and persistence.
6. Graphical environment and applications.

## Repository layout

- boot/ — BIOS boot sector and early boot stages.
- kernel/ — kernel entry and core code.
- scripts/ — image/build/test helpers.
- docs/ — architecture notes and debugging procedures.
- .github/workflows/ — automated build checks.

Contributions and bug reports should include the build command, emulator/VirtualBox settings, and the last visible diagnostic marker.
