# NOVA-OS code audit

This file records findings before the kernel grows. Re-run the build and QEMU tests after every boot-path or kernel change.

## Fixed

- **Kernel string output stopped after one character (fixed).** The 32-bit `print32` routine returned after each character instead of looping until NUL. This made VGA diagnostics misleading. It now jumps back to the routine for the next character.
- **Boot tests did not exercise the command shell (fixed in CI).** `scripts/shell-smoke-test.py` sends `help` and `memory` through QEMU's emulated keyboard, checks the command list, and requires a non-empty E820 memory-map count.
- **Banner regression could pass boot checks (fixed in CI).** Rebuilt floppy and ISO tests now require the serial banner as well as the boot checkpoints.
- **A stale root ISO could block a valid source build (fixed in CI).** The workflow no longer tests an old committed root-level ISO before rebuilding; it tests and publishes only the freshly generated image from the current source.

## Known limitations / follow-up

- **Minimal IDT and CPU exception reporting added.** Vectors 0–31 now have gates and report the exception vector over serial before halting. CI builds a fault-injection kernel with `int3` and checks that vector 0x03 is reported. There is not yet a dedicated IST stack for double faults, and hardware IRQs remain disabled.
- **Polling keyboard driver only.** It assumes a PS/2-compatible keyboard and set-1 scancodes. Shifted punctuation and Caps Lock are now handled, but there is no IRQ-based input or deliberate key-repeat policy.
- **Reboot controller timeout (fixed).** The 8042 input-buffer wait is now bounded; if the controller never becomes ready, the kernel prints a diagnostic and halts instead of spinning forever.
- **Early boot still assumes BIOS floppy emulation.** Reads of sectors 2–17 now retry three times with a BIOS disk reset between failures, but there is no LBA fallback. Keep the ISO's El Torito floppy-emulation layout in sync with this assumption.
- **Memory layout is explicit but still fixed.** Constants now centralize stack, page-table, and VGA addresses; the stack top is separated from the page-table region. Real-mode code collects up to 32 BIOS E820 entries at physical 0x5000, and `memory` reports the entry count. A physical-frame allocator and heap are not implemented yet.
- **Serial diagnostics are part of the test contract.** Keep the boot marker sequence and kernel banner stable or update the CI checks together with intentional changes.

## Verification policy

A source change is not considered complete merely because it is committed. Require:
1. NASM assembly and boot-sector/kernel-size checks.
2. QEMU boot of the raw image and rebuilt ISO.
3. Serial checkpoints and kernel-banner checks.
4. Interactive keyboard smoke test for shell changes.
5. A real VirtualBox check when available; QEMU success is not proof of VirtualBox success.
