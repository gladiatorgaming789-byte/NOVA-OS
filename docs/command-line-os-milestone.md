# Command-line OS milestone: architecture and acceptance plan

## Goal

Turn NOVA-OS from a bootable shell prototype into a small, genuinely multitasking command-line operating system. Keep the BIOS/VirtualBox path and diagnostics, but build the internal subsystems against shared interfaces rather than accumulating isolated demos.

This work is developed on `milestone/command-line-os`; `main` remains the known-good bootable baseline until the integrated milestone passes CI.

## Current constraints that must be addressed first

- The BIOS loader now supports a bounded 256 KiB kernel image, but still loads it through floppy-emulation CHS reads.
- The kernel still identity-maps the first 1 GiB using 2 MiB pages. A test address space replaces the 4–8 MiB region with 4 KiB page tables and marks only the built-in user code/stack pages as user-accessible; this is not yet a general per-process VM subsystem.
- The PIT scheduler switches between the kernel shell context and two worker contexts. User-mode tests execute synchronously from the shell; there is not yet a general process table, ELF loader, or independent user-process scheduler.
- A ring-3 syscall path and fault containment test exist. Kernel-mode faults remain fatal, and user pointer validation is currently limited to the small built-in test ABI.
- A separate writable IDE data image and a one-file NOVA filesystem are being integrated. The boot ISO itself must not be treated as writable storage.
- The heap and PMM remain early prototypes; locking, ownership tracking, and failure cleanup need more work before they are general-purpose concurrent allocators.

## Implementation status

- Verified by QEMU in CI: boot image and ISO boot, exception diagnostics, timer scheduler smoke test, ring-3 syscall write/exit/yield, an ELF task yielding and resuming under preemption, and a deliberate user-mode protection fault returning to the shell.
- Implemented but still under integration testing: primary-master ATA PIO and `NOVA.TXT` read/write/list commands on the separate data disk.
- Implemented, with its dedicated end-to-end test now in the workflow: a bounded ELF64 loader for one static PT_LOAD segment and a built-in executable installed on the writable disk. The latest source still needs a successful full workflow run to confirm this test passes alongside the prior scheduler, user-fault, and persistence checks.
- Not complete yet: a general process table and lifecycle, multiple-file/directory support, robust allocator locking, and a user-space shell.

## Target architecture

### 1. Boot and kernel image

Preserve the current BIOS boot route first, but remove the fragile fixed 8 KiB assumption. Introduce a second-stage loader or an equivalent bounded multi-sector loader, define a kernel load range that does not overlap real-mode data, stack, page tables, or allocator metadata, and validate image bounds during the build. Keep the boot ISO and raw image generation reproducible.

### 2. Memory and protection

- Keep E820 discovery, but reserve every kernel-owned range explicitly.
- Add physical-page ownership and a page-table API for mapping/unmapping pages, setting writable/user permissions, and invalidating TLB entries.
- Keep a kernel-only address space and build a separate user address space per process.
- Handle page faults as recoverable process faults when the fault comes from ring 3; retain a diagnostic kernel-fatal path for unrecoverable ring-0 faults.
- Add allocator invariants and tests before enabling preemption.

### 3. Interrupts and preemptive scheduler

- Define one normalized interrupt/context frame for exceptions and IRQs.
- Make the PIT tick update monotonic time and request rescheduling; do not perform complex scheduler work inside device-specific code.
- Add kernel task stacks, a runnable queue, idle task, round-robin time slices, and safe context switching.
- Protect shared kernel structures from interrupt/preemption races. Avoid holding allocator or console locks across a yield.
- Keep keyboard input queued and have the shell consume it as a task rather than monopolizing the kernel loop.

### 4. User programs and system calls

- Add a minimal ELF64 loader with strict validation of headers, segment bounds, alignment, and user address ranges.
- Enter ring 3 with a dedicated user stack and a controlled return path.
- Define a small, versioned syscall ABI for console write, process exit, yield, time, and file operations.
- Ensure user pointers are checked/copied safely; a bad user pointer must terminate the offending process rather than corrupt the kernel.
- Start with a tiny built-in test program, then load a program from the filesystem.

### 5. Persistent storage

- Add a primary/secondary IDE ATA PIO driver suitable for a VirtualBox attached writable disk.
- Choose a simple documented on-disk format (initial target: FAT16-compatible read/write support if the implementation can stay bounded; otherwise a small purpose-built filesystem with explicit image tooling).
- Never write to the boot ISO. Use a separate writable disk image and make it easy to attach to a VM.
- Implement mount, directory listing, create/read/write, and basic metadata operations; test persistence by writing a file, rebooting the VM, and reading it back.
- Define block-device and filesystem interfaces so a future driver or filesystem does not leak into the shell.

### 6. Shell and diagnostics

The kernel shell should become a user-space process when process isolation is stable. The first user commands should include `help`, `clear`, `ps`, `mem`, `uptime`, `ls`, `cat`, `write`, and `reboot`. Add commands only when their backing subsystem is real.

## Integration order (one coordinated milestone, internal checkpoints)

These checkpoints are not separate user-facing releases. They are gates inside the same development effort:

1. **Boot expansion:** larger kernel image, explicit memory layout, boot + ISO smoke tests.
2. **Memory safety:** page-table API, user/kernel permission tests, page-fault diagnostics, allocator stress checks.
3. **Scheduler:** timer-driven preemption, task state/queue, deterministic task-switch test, shell stays responsive.
4. **User mode:** ring-3 transition, validated ELF loader, syscall tests, process fault isolation.
5. **Block device + filesystem:** disk read/write tests, file operations, reboot persistence test.
6. **Integration:** shell in user mode, combined multitasking + filesystem tests, final bootable ISO and checksums.

## Release acceptance criteria

Do not call the milestone complete until CI verifies all of the following:

- The raw boot image and generated ISO both reach the kernel banner.
- Kernel image-size/layout checks pass and boot failure diagnostics remain available over serial.
- At least two tasks make progress under timer-driven preemption.
- A ring-3 ELF program can print, yield voluntarily, resume after scheduling another task, read a file, and exit through syscalls.
- An invalid user-mode memory access is contained to that process.
- A user program can create and read a file from the writable virtual disk.
- A file written before reboot is still readable after reboot.
- The interactive shell smoke test covers the new process and file commands.
- The workflow uploads the exact tested ISO, raw image, writable disk image/template, checksums, and serial logs. Publish a GitHub Release only from a successful run; never label a merely assembled image as boot-tested.

## Engineering rules

- Keep `main` bootable; integrate from this branch only after the acceptance tests pass.
- Prefer small modules and explicit interfaces over a single expanding assembly file.
- Test each new invariant automatically in QEMU. QEMU success is not a substitute for an eventual VirtualBox check.
- Do not fake unsupported commands, silently fall back from protection, or claim persistence without a reboot test.
- Preserve the user-facing deliverable: a bootable `.iso` suitable for VirtualBox, plus clear instructions for any separate writable disk image.
