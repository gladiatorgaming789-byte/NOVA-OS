# NOVA-OS code audit

This file records findings before the kernel grows. Re-run the build and QEMU tests after every boot-path or kernel change.

## Fixed

- **Kernel string output stopped after one character (fixed).** The 32-bit `print32` routine returned after each character instead of looping until NUL. This made VGA diagnostics misleading. It now jumps back to the routine for the next character.
- **Boot tests did not exercise the command shell (fixed in CI).** The previous QEMU checks proved only that long mode and the banner were reached. `scripts/shell-smoke-test.py` now sends `help` through QEMU's emulated keyboard and requires the command list to appear on serial output.
- **Banner regression could pass boot checks (fixed in CI).** Rebuilt floppy and ISO tests now require the serial banner as well as the boot checkpoints.

## Known limitations / follow-up

- **No IDT or exception handlers yet.** A CPU exception can still triple-fault/reset without a useful diagnostic. Add a minimal IDT and exception reporting before introducing more complex kernel services.
- **Polling keyboard driver only.** It assumes a PS/2-compatible keyboard and set-1 scancodes; there is no IRQ-based input, key repeat policy, caps lock, or shifted punctuation.
- **Reboot controller timeout (fixed).** The 8042 input-buffer wait is now bounded; if the controller never becomes ready, the kernel prints a diagnostic and halts instead of spinning forever.
- **Early boot assumes BIOS floppy emulation.** The boot sector reads fixed CHS sectors 2–17 and does not retry or fall back to LBA. Keep the ISO's El Torito floppy-emulation layout in sync with this assumption.
- **Memory layout is hard-coded.** The kernel uses fixed addresses for the stack, page tables, and VGA text memory. A memory map and allocator are not implemented.
- **Serial diagnostics are part of the test contract.** Keep the boot marker sequence and kernel banner stable or update the CI checks together with intentional changes.

## Verification policy

A source change is not considered complete merely because it is committed. Require:
1. NASM assembly and boot-sector/kernel-size checks.
2. QEMU boot of the raw image and rebuilt ISO.
3. Serial checkpoints and kernel-banner checks.
4. Interactive keyboard smoke test for shell changes.
5. A real VirtualBox check when available; QEMU success is not proof of VirtualBox success.
