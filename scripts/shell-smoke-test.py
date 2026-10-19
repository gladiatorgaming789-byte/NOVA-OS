#!/usr/bin/env python3
"""Smoke-test NOVA-OS keyboard input and shell commands through QEMU's monitor."""
from __future__ import annotations

import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: shell-smoke-test.py PATH_TO_DISK_IMAGE", file=sys.stderr)
        return 2

    image = Path(sys.argv[1]).resolve()
    if not image.is_file():
        print(f"image not found: {image}", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="nova-shell-test-") as temp:
        root = Path(temp)
        monitor_path = root / "monitor.sock"
        serial_path = root / "serial.log"
        command = [
            "qemu-system-x86_64",
            "-machine", "pc",
            "-m", "128M",
            "-drive", f"file={image},format=raw,if=floppy",
            "-boot", "a",
            "-display", "none",
            "-serial", f"file:{serial_path}",
            "-monitor", f"unix:{monitor_path},server=on,wait=off",
            "-no-reboot",
            "-no-shutdown",
        ]

        process = subprocess.Popen(
            command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True
        )
        monitor = None
        try:
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    stderr = process.stderr.read() if process.stderr else ""
                    raise RuntimeError(f"QEMU exited early ({process.returncode}): {stderr}")
                try:
                    monitor = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    monitor.settimeout(1)
                    monitor.connect(str(monitor_path))
                    break
                except OSError:
                    if monitor is not None:
                        monitor.close()
                        monitor = None
                    time.sleep(0.05)
            if monitor is None:
                raise RuntimeError("could not connect to QEMU monitor")

            time.sleep(0.5)
            monitor.recv(4096) if _readable(monitor) else None

            # Send a real keyboard sequence to the emulated PS/2 keyboard.
            for key in ("h", "e", "l", "p", "ret"):
                monitor.sendall(f"sendkey {key}\n".encode("ascii"))
                time.sleep(0.15)

            deadline = time.monotonic() + 5
            expected = b"Commands: help, about, clear, reboot"
            while time.monotonic() < deadline:
                if serial_path.exists() and expected in serial_path.read_bytes():
                    break
                time.sleep(0.1)
            else:
                output = serial_path.read_text(errors="replace") if serial_path.exists() else ""
                raise RuntimeError(
                    "shell did not respond to typed 'help'. Captured serial output:\n" + output
                )

            # Verify BIOS E820 discovery through the shell as well.
            for key in ("m", "e", "m", "o", "r", "y", "ret"):
                monitor.sendall(f"sendkey {key}\n".encode("ascii"))
                time.sleep(0.15)

            import re
            deadline = time.monotonic() + 5
            pattern = re.compile(rb"Firmware E820 entries: 0x(?!0000)[0-9A-F]{4}")
            while time.monotonic() < deadline:
                if serial_path.exists() and pattern.search(serial_path.read_bytes()):
                    print("Shell smoke test passed: help and non-empty E820 memory map.")
                    return 0
                time.sleep(0.1)

            output = serial_path.read_text(errors="replace") if serial_path.exists() else ""
            raise RuntimeError(
                "shell did not report a non-empty E820 memory map. Captured serial output:\n" + output
            )
        finally:
            if monitor is not None:
                monitor.close()
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)


def _readable(sock: socket.socket) -> bool:
    import select
    ready, _, _ = select.select([sock], [], [], 0)
    return bool(ready)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"shell smoke test failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
