#!/usr/bin/env python3
"""Smoke-test NOVA-OS keyboard input, memory commands, and heap reuse through QEMU."""
from __future__ import annotations

import re
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
            if _readable(monitor):
                monitor.recv(4096)

            def output() -> bytes:
                return serial_path.read_bytes() if serial_path.exists() else b""

            def send_keys(keys: tuple[str, ...]) -> None:
                for key in keys:
                    monitor.sendall(f"sendkey {key}\n".encode("ascii"))
                    time.sleep(0.12)

            def run_command(keys: tuple[str, ...], pattern: bytes, description: str,
                            previous_count: int = 0, timeout: float = 5) -> bytes:
                send_keys(keys)
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    data = output()
                    if len(re.findall(pattern, data)) > previous_count:
                        return data
                    time.sleep(0.1)
                captured = output().decode(errors="replace")
                raise RuntimeError(f"{description} failed. Captured serial output:\n{captured}")

            help_pattern = re.escape(
                b"Commands: help, about, clear, memory, alloc, free, pmmtest, schedtest, heap, halloc, hfree, uptime, reboot"
            )
            run_command(("h", "e", "l", "p", "ret"), help_pattern, "shell help command")
            print("Shell help check passed.")

            e820_pattern = rb"Firmware E820 entries: 0x(?!0000)[0-9A-F]{4}"
            run_command(("m", "e", "m", "o", "r", "y", "ret"), e820_pattern,
                        "E820 memory-map command")
            print("E820 memory map check passed.")

            pmmtest_pattern = re.escape(
                b"PMM safety test passed: reserved and double frees rejected."
            )
            run_command(("p", "m", "m", "t", "e", "s", "t", "ret"),
                        pmmtest_pattern, "physical allocator safety regression")
            print("Physical allocator safety regression passed.")

            scheduler_pattern = re.escape(
                b"Scheduler test passed: both preempted tasks made progress."
            )
            run_command(
                ("s", "c", "h", "e", "d", "t", "e", "s", "t", "ret"),
                scheduler_pattern,
                "timer-preemptive scheduler regression",
            )
            print("Timer-preemptive scheduler check passed.")

            page_alloc_pattern = rb"Allocated physical page: 0x[0-9A-F]{8,16}"
            run_command(("a", "l", "l", "o", "c", "ret"), page_alloc_pattern,
                        "physical page allocation")
            run_command(("f", "r", "e", "e", "ret"), re.escape(b"Freed test page."),
                        "physical page free")
            print("Physical page alloc/free check passed.")

            heap_alloc_pattern = rb"Heap allocation at: 0x[0-9A-F]{8,16}"
            first_count = len(re.findall(heap_alloc_pattern, output()))
            data = run_command(("h", "a", "l", "l", "o", "c", "ret"),
                               heap_alloc_pattern, "first heap allocation", first_count)
            first_addresses = re.findall(heap_alloc_pattern, data)
            first_address = first_addresses[-1].split(b": ", 1)[1]
            print(f"First heap allocation: {first_address.decode()}")

            hfree_pattern = re.escape(b"Heap test allocation freed.")
            freed_count = len(re.findall(hfree_pattern, output()))
            run_command(("h", "f", "r", "e", "e", "ret"), hfree_pattern,
                        "first heap free", freed_count)

            # The allocator is first-fit. After freeing the only test block, the
            # next same-size allocation should reuse that block's payload address.
            second_count = len(re.findall(heap_alloc_pattern, output()))
            data = run_command(("h", "a", "l", "l", "o", "c", "ret"),
                               heap_alloc_pattern, "heap allocation after free", second_count)
            addresses = re.findall(heap_alloc_pattern, data)
            second_address = addresses[-1].split(b": ", 1)[1]
            if second_address != first_address:
                raise RuntimeError(
                    "heap free-list reuse failed: first allocation was "
                    f"{first_address.decode()}, second was {second_address.decode()}"
                )
            print(f"Heap free-list reuse check passed at {second_address.decode()}.")

            freed_count = len(re.findall(hfree_pattern, output()))
            run_command(("h", "f", "r", "e", "e", "ret"), hfree_pattern,
                        "second heap free", freed_count)
            print("Shell smoke test passed: help, E820, physical alloc/free, heap alloc/free, and heap reuse.")
            return 0
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
