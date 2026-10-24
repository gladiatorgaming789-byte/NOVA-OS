# NOVA-OS

**NOVA-OS is an experimental operating system built from scratch for x86-64 PCs and Oracle VirtualBox.** It is not a Linux distribution and does not use the Linux kernel.

> **Status:** experimental command-line OS milestone in active development. The current branch has timer-preempted kernel tasks, ring-3 ELF execution with bounded file-read/write syscalls, user-fault isolation, and a small fixed-slot filesystem with two persistent named text files plus a separately stored ELF executable. It is still not a general-purpose OS: the interactive shell remains in kernel mode, the ELF loader supports one bounded static PT_LOAD segment, and storage is intentionally minimal.

## Project goals

- Custom BIOS boot path and kernel; no Linux kernel or existing OS distribution.
- Build a bootable disk image for Oracle VirtualBox.
- Serial and on-screen diagnostics so a failed boot has useful evidence.
- Small, testable milestones: BIOS boot → protected mode → long mode → keyboard input and shell.
- Expandable kernel load (up to 256 KiB) while preserving the BIOS floppy-emulation boot path.
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

Builds use NASM and xorriso in GitHub Actions. Each successful workflow run publishes a `nova-os-boot-tested-image` artifact containing `build/nova-os.iso`, the raw boot image, a separate writable `build/nova-data.img`, checksums, and serial logs. **Use `build/nova-os.iso` from the downloaded artifact ZIP** in VirtualBox; the root-level `nova-os.iso` is retained for comparison and may be an older image. Configure the VM for BIOS boot (EFI off).

## Current command-line milestone

On the `milestone/command-line-os` branch, the kernel currently provides:

- `help`, `memory`, `alloc`, `free`, `pmmtest`, `heap`, `halloc`, `hfree`, and `uptime` diagnostics.
- `schedtest` to verify both timer-preempted kernel worker tasks progress.
- `usertest` to run a built-in ring-3 program that prints through syscall 1 and exits through syscall 2.
- `userfaulttest` to verify a user-mode protection fault terminates the test program and returns control to the shell.
- `write <text>`, `ls`, and `cat` for the early `NOVA.TXT` file on a separate writable IDE disk. `install` places a built-in ELF64 test executable on the disk and `exec` validates and loads it into ring 3. The current filesystem has one file slot and a 512-byte data sector; the shell line buffer limits a write to 121 bytes.

Attach both the ISO and `nova-data.img` to VirtualBox. Keep the ISO as the boot device and attach `nova-data.img` as a writable IDE hard disk. Do not use the ISO as the writable data volume. The automated workflow verifies that a ring-3 executable writes file contents, reads them back, and that the updated file survives a full guest reboot.

These are integration milestones, not claims of a complete process/filesystem implementation. The next internal work is a real process table and lifecycle, stronger page-table and allocator invariants, and expanding storage beyond one file before the GUI phase.

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
4. BIOS E820 memory-map discovery and a bitmap allocator for 4 KiB physical pages below 1 GiB. The `memory` command reports free pages; `alloc` and `free` exercise a test allocation.
5. A page-backed kernel heap with 16-byte-aligned allocations, block reuse, adjacent-block coalescing, and `heap`, `halloc`, and `hfree` diagnostics. This is an early first-fit heap, not yet a general-purpose or concurrency-safe allocator.
6. Integrated command-line OS milestone (development plan in [docs/command-line-os-milestone.md](docs/command-line-os-milestone.md)): virtual-memory protection, preemptive multitasking, user programs and system calls, persistent storage, and a user-space shell.
7. Graphical environment, applications, networking, and broader device support.

## Repository layout

- boot/ — BIOS boot sector and early boot stages.
- kernel/ — kernel entry and core code.
- scripts/ — image/build/test helpers.
- docs/ — architecture notes, debugging procedures, and the [code audit](docs/code-audit.md).
- .github/workflows/ — automated build checks.

Contributions and bug reports should include the build command, emulator/VirtualBox settings, and the last visible diagnostic marker.
