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
    if len(sys.argv) not in (2, 3):
        print("usage: shell-smoke-test.py PATH_TO_BOOT_IMAGE [PATH_TO_DATA_DISK]", file=sys.stderr)
        return 2

    image = Path(sys.argv[1]).resolve()
    data_disk = Path(sys.argv[2]).resolve() if len(sys.argv) == 3 else None
    if not image.is_file():
        print(f"image not found: {image}", file=sys.stderr)
        return 2
    if data_disk is not None and not data_disk.is_file():
        print(f"data disk not found: {data_disk}", file=sys.stderr)
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
            "-no-shutdown",
        ]

        if data_disk is not None:
            command.extend(["-drive", f"file={data_disk},format=raw,if=ide,index=0"])

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
                b"Commands: help, about, clear, memory, mem, ps, kill <pid>, wait <pid>, alloc, free, pmmtest, schedtest, usertest, userfaulttest, install, exec, ls, cat, cat2, write, write2, heap, halloc, hfree, uptime, reboot"
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

            ps_pattern = rb"Task 1: worker-a iterations: 0x[0-9A-F]{8}"
            ps_data = run_command(("p", "s", "ret"), ps_pattern,
                                  "scheduler task inspection")
            if b"Task 2: worker-b iterations: 0x" not in ps_data:
                raise RuntimeError("ps did not report both scheduler worker tasks")
            if b"Task 4 PID: 0x00000004" not in ps_data:
                raise RuntimeError("ps did not report the stable shell PID")
            invalid_kill = re.escape(
                b"Process PID not found or kill syntax invalid (use: kill <pid>)."
            )
            run_command(
                ("k", "i", "l", "l", "spc", "9", "9", "9", "ret"),
                invalid_kill,
                "reject unknown process ID",
            )
            invalid_wait = re.escape(
                b"Process PID not found or wait syntax invalid (use: wait <pid>)."
            )
            run_command(
                ("w", "a", "i", "t", "spc", "9", "9", "9", "ret"),
                invalid_wait,
                "reject wait for unknown process ID",
            )
            run_command(("m", "e", "m", "ret"), e820_pattern,
                        "mem alias")
            print("Task inspection and mem alias checks passed.")

            user_output_pattern = re.escape(
                b"NOVA ring-3 program: syscall write works"
            )
            run_command(
                ("u", "s", "e", "r", "t", "e", "s", "t", "ret"),
                user_output_pattern,
                "ring-3 syscall write/exit test",
                timeout=6,
            )
            print("Ring-3 syscall write/exit test passed.")
            # The single user slot receives a fresh PID on every launch.
            # Kill it immediately after observing its output. Depending on the
            # scheduler tick, it may have exited already; both outcomes must be
            # safe, and ps must show the slot stopped with its CR3 reclaimed.
            pid_pattern = rb"Task 3 PID: 0x[0-9A-F]{8}"
            previous_pid_count = len(re.findall(pid_pattern, output()))
            pid_snapshot = run_command(
                ("p", "s", "ret"),
                pid_pattern,
                "user process PID inspection",
                previous_count=previous_pid_count,
            )
            pid_matches = re.findall(rb"Task 3 PID: 0x([0-9A-F]{8})", pid_snapshot)
            if not pid_matches or int(pid_matches[-1], 16) < 5:
                raise RuntimeError("user process did not receive a dynamic PID")
            if b"Task 3 parent PID: 0x00000004" not in pid_snapshot:
                raise RuntimeError("user process parent PID was not recorded")
            if b"Task 3 name: usertest" not in pid_snapshot:
                raise RuntimeError("user process name was not recorded")
            user_pid = str(int(pid_matches[-1], 16))
            termination_result = (
                rb"(?:Process terminated and its address space reclaimed\."
                rb"|Process exists but is not running\.)"
            )
            run_command(
                tuple(["k", "i", "l", "l", "spc"] + list(user_pid) + ["ret"]),
                termination_result,
                "terminate or safely reject an already exited process",
            )
            stopped_pattern = re.escape(
                b"Task 3 lifecycle (0=unused,1=ready,2=running,3=stopped): 0x00000003"
            )
            previous_stopped_count = len(re.findall(stopped_pattern, output()))
            stopped_snapshot = run_command(
                ("p", "s", "ret"),
                stopped_pattern,
                "process is no longer schedulable",
                previous_count=previous_stopped_count,
            )
            if b"Task 3 address-space root (0=none): 0x00000000" not in stopped_snapshot:
                raise RuntimeError("terminated process retained its address-space root")
            print(f"Process identity, termination, and VM cleanup checks passed (PID {user_pid}).")

            reaped_pattern = rb"Process reaped; exit status: 0x0000000[02]"
            run_command(
                tuple(["w", "a", "i", "t", "spc"] + list(user_pid) + ["ret"]),
                reaped_pattern,
                "collect process exit status and reap its slot",
            )
            reaped_snapshot = run_command(
                ("p", "s", "ret"),
                re.escape(b"Task 3 PID: 0x00000000"),
                "verify reaped process identity is cleared",
            )
            if b"Task 3 lifecycle (0=unused,1=ready,2=running,3=stopped): 0x00000000" not in reaped_snapshot:
                raise RuntimeError("reaped process slot was not returned to UNUSED")
            if b"Task 3 parent PID: 0x00000000" not in reaped_snapshot:
                raise RuntimeError("reaped process retained its parent PID")
            print("Wait/reap lifecycle passed: exit status collected and task slot released.")

            # Repeatedly launch and exit the same ring-3 test process. The
            # physical-page count must return to its baseline after every run;
            # otherwise process cleanup is leaking user address-space pages.
            free_pages_pattern = rb"Free 4KiB pages: 0x([0-9A-F]{8})"
            baseline_data = run_command(
                ("m", "e", "m", "o", "r", "y", "ret"),
                free_pages_pattern,
                "baseline physical-page count before process stress",
            )
            baseline_matches = re.findall(free_pages_pattern, baseline_data)
            if not baseline_matches:
                raise RuntimeError("memory command did not report free physical pages")
            baseline_pages = int(baseline_matches[-1], 16)
            exit_pattern = re.escape(b"Ring-3 program exited through syscall.")
            for iteration in range(8):
                previous_output_count = len(re.findall(user_output_pattern, output()))
                previous_exit_count = len(re.findall(exit_pattern, output()))
                run_command(
                    ("u", "s", "e", "r", "t", "e", "s", "t", "ret"),
                    user_output_pattern,
                    f"ring-3 process stress launch {iteration + 1}",
                    previous_count=previous_output_count,
                    timeout=6,
                )
                deadline = time.monotonic() + 6
                while time.monotonic() < deadline:
                    if len(re.findall(exit_pattern, output())) > previous_exit_count:
                        break
                    time.sleep(0.1)
                else:
                    raise RuntimeError(
                        f"ring-3 process stress run {iteration + 1} did not exit"
                    )
            final_data = run_command(
                ("m", "e", "m", "o", "r", "y", "ret"),
                free_pages_pattern,
                "physical-page count after process stress",
            )
            final_matches = re.findall(free_pages_pattern, final_data)
            final_pages = int(final_matches[-1], 16) if final_matches else -1
            if final_pages != baseline_pages:
                raise RuntimeError(
                    "ring-3 process stress leaked physical pages: "
                    f"baseline={baseline_pages}, final={final_pages}"
                )
            print("Eight ring-3 process launches exited without leaking physical pages.")

            user_fault_pattern = re.escape(
                b"User process faulted; terminated safely."
            )
            run_command(
                ("u", "s", "e", "r", "f", "a", "u", "l", "t", "t", "e", "s", "t", "ret"),
                user_fault_pattern,
                "ring-3 protection fault isolation",
                timeout=6,
            )
            fault_ps = run_command(
                ("p", "s", "ret"),
                re.escape(b"Task 3 exit status: 0x00000001"),
                "inspect faulted process metadata",
            )
            fault_pid_match = re.search(rb"Task 3 PID: 0x([0-9A-F]{8})", fault_ps)
            if fault_pid_match is None:
                raise RuntimeError(
                    "could not parse faulted process PID from ps output: "
                    + fault_ps.decode(errors="replace")[-1200:]
                )
            if b"Task 3 exit status: 0x00000001" not in fault_ps:
                raise RuntimeError("user fault did not record exit status 1")
            fault_pid = str(int(fault_pid_match.group(1), 16))
            run_command(
                tuple(["w", "a", "i", "t", "spc"] + list(fault_pid) + ["ret"]),
                re.escape(b"Process reaped; exit status: 0x00000001"),
                "reap faulted process and collect fault exit status",
            )
            data = run_command(
                ("h", "e", "l", "p", "ret"),
                help_pattern,
                "shell recovery after user fault",
                previous_count=1,
            )
            print("User fault isolation and shell recovery passed.")

            # Repeat the supervisor-page write violation. This is stronger
            # than a single crash check: every fault must retire the task,
            # reclaim its address-space pages, and leave the shell schedulable.
            baseline_data = run_command(
                ("m", "e", "m", "o", "r", "y", "ret"),
                free_pages_pattern,
                "baseline physical-page count before fault stress",
            )
            baseline_matches = re.findall(free_pages_pattern, baseline_data)
            if not baseline_matches:
                raise RuntimeError("memory command omitted the baseline page count")
            fault_baseline_pages = int(baseline_matches[-1], 16)
            for iteration in range(8):
                previous_fault_count = len(re.findall(user_fault_pattern, output()))
                run_command(
                    ("u", "s", "e", "r", "f", "a", "u", "l", "t", "t", "e", "s", "t", "ret"),
                    user_fault_pattern,
                    f"ring-3 supervisor-page protection test {iteration + 1}",
                    previous_count=previous_fault_count,
                    timeout=6,
                )
                previous_help_count = len(re.findall(help_pattern, output()))
                run_command(
                    ("h", "e", "l", "p", "ret"),
                    help_pattern,
                    f"shell recovery after protection test {iteration + 1}",
                    previous_count=previous_help_count,
                    timeout=6,
                )
            final_data = run_command(
                ("m", "e", "m", "o", "r", "y", "ret"),
                free_pages_pattern,
                "physical-page count after fault stress",
            )
            final_matches = re.findall(free_pages_pattern, final_data)
            fault_final_pages = int(final_matches[-1], 16) if final_matches else -1
            if fault_final_pages != fault_baseline_pages:
                raise RuntimeError(
                    "ring-3 protection-fault stress leaked physical pages: "
                    f"baseline={fault_baseline_pages}, final={fault_final_pages}"
                )
            print("Eight protection faults recovered safely without page leaks.")

            if data_disk is not None:
                write_pattern = re.escape(b"Saved NOVA.TXT to persistent storage.")
                run_command(
                    ("w", "r", "i", "t", "e", "spc", "h", "e", "l", "l", "o",
                     "spc", "f", "r", "o", "m", "spc", "n", "o", "v", "a", "ret"),
                    write_pattern,
                    "persistent file write",
                    timeout=8,
                )
                print("Persistent file write passed.")

                ls_pattern = rb"NOVA\.TXT bytes: 0x[0-9A-F]{8}"
                run_command(("l", "s", "ret"), ls_pattern, "filesystem directory listing")
                cat_pattern = re.escape(b"File: hello from nova")
                run_command(("c", "a", "t", "ret"), cat_pattern, "filesystem file read")
                print("Filesystem ls/cat checks passed.")

                # Exercise a second independently named file and ensure the
                # directory entry/data sector are distinct from NOVA.TXT.
                write2_pattern = re.escape(b"Saved NOVA2.TXT to persistent storage.")
                run_command(
                    ("w", "r", "i", "t", "e", "2", "spc", "s", "e", "c", "o", "n", "d",
                     "spc", "f", "i", "l", "e", "ret"),
                    write2_pattern,
                    "second persistent file write",
                    timeout=8,
                )
                cat2_pattern = re.escape(b"File NOVA2.TXT: second file")
                run_command(("c", "a", "t", "2", "ret"), cat2_pattern,
                            "second named file read")
                listing_data = run_command(("l", "s", "ret"), rb"NOVA2\.TXT bytes: 0x[0-9A-F]{8}",
                                           "second file directory listing")
                if b"NOVA.TXT bytes: 0x" not in listing_data:
                    raise RuntimeError("writing NOVA2.TXT damaged the first file entry")
                print("Multiple named file read/write/listing checks passed.")

                banner_pattern = re.escape(b"NOVA OS - 64-bit kernel online")
                old_banner_count = len(re.findall(banner_pattern, output()))
                reboot_pattern = re.escape(b"Rebooting NOVA OS...")
                run_command(("r", "e", "b", "o", "o", "t", "ret"),
                            reboot_pattern, "filesystem persistence reboot", timeout=5)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    if len(re.findall(banner_pattern, output())) > old_banner_count:
                        break
                    time.sleep(0.1)
                else:
                    raise RuntimeError("VM did not reboot for filesystem persistence test")
                run_command(("c", "a", "t", "ret"), cat_pattern,
                            "file contents after reboot", previous_count=1, timeout=8)
                cat2_count = len(re.findall(cat2_pattern, output()))
                run_command(("c", "a", "t", "2", "ret"), cat2_pattern,
                            "second file contents after reboot", previous_count=cat2_count)
                listing_data = run_command(("l", "s", "ret"),
                                           rb"NOVA2\.TXT bytes: 0x[0-9A-F]{8}",
                                           "second file directory entry after reboot")
                if b"NOVA.TXT bytes: 0x" not in listing_data:
                    raise RuntimeError("second-file persistence damaged NOVA.TXT entry")
                print("Both named files persist across reboot.")

                install_pattern = re.escape(b"Installed NOVA.ELF on persistent storage.")
                run_command(("i", "n", "s", "t", "a", "l", "l", "ret"),
                            install_pattern, "ELF install to filesystem", timeout=8)
                elf_listing_pattern = rb"NOVA\.ELF bytes: 0x[0-9A-F]{8}"
                listing_data = run_command(("l", "s", "ret"), elf_listing_pattern,
                                           "ELF file listing")
                if b"NOVA.TXT bytes: 0x" not in listing_data:
                    raise RuntimeError("installing NOVA.ELF unexpectedly removed NOVA.TXT")
                cat_count = len(re.findall(cat_pattern, output()))
                run_command(("c", "a", "t", "ret"), cat_pattern,
                            "text file remains available beside ELF", previous_count=cat_count)
                elf_output_pattern = re.escape(b"NOVA ELF64 program loaded from disk")
                payload_pattern = re.escape(b"user process wrote persistent data")
                yield_pattern = re.escape(b"NOVA ELF task yielding to scheduler")
                resumed_pattern = re.escape(b"NOVA ELF task resumed after yield")
                exit_pattern = re.escape(b"Ring-3 program exited through syscall.")
                previous_file_reads = len(re.findall(payload_pattern, output()))
                previous_exits = len(re.findall(exit_pattern, output()))
                previous_yields = len(re.findall(yield_pattern, output()))
                previous_resumes = len(re.findall(resumed_pattern, output()))
                run_command(("e", "x", "e", "c", "ret"), elf_output_pattern,
                            "ELF64 load and ring-3 execution", timeout=8)
                deadline = time.monotonic() + 6
                while time.monotonic() < deadline:
                    data = output()
                    file_reads = len(re.findall(payload_pattern, data))
                    exits = len(re.findall(exit_pattern, data))
                    yields = len(re.findall(yield_pattern, data))
                    resumes = len(re.findall(resumed_pattern, data))
                    if (file_reads > previous_file_reads and exits > previous_exits
                            and yields > previous_yields and resumes > previous_resumes):
                        break
                    time.sleep(0.1)
                else:
                    raise RuntimeError(
                        "scheduled ELF process did not write/read its file, yield, resume, and exit"
                    )
                ps_stopped_pattern = re.escape(
                    b"Task 3: user ELF state (0=stopped, 1=runnable): 0x00000000"
                )
                run_command(("p", "s", "ret"), ps_stopped_pattern,
                            "user process state after exit", previous_count=1)
                no_user_cr3_pattern = re.escape(
                    b"Task 3 address-space root (0=none): 0x00000000"
                )
                run_command(
                    ("p", "s", "ret"),
                    no_user_cr3_pattern,
                    "user address-space root cleared after exit",
                    previous_count=0,
                )
                lifecycle_stopped_pattern = re.escape(
                    b"Task 3 lifecycle (0=unused,1=ready,2=running,3=stopped): 0x00000003"
                )
                run_command(
                    ("p", "s", "ret"),
                    lifecycle_stopped_pattern,
                    "canonical process lifecycle after exit",
                    previous_count=0,
                )

                # A stopped task must not be scheduled. Repeatedly allow timer
                # preemption to run, then inspect the lifecycle state; it must
                # remain STOPPED until an explicit launch changes it to READY.
                for iteration in range(3):
                    previous_stopped_count = len(
                        re.findall(lifecycle_stopped_pattern, output())
                    )
                    run_command(
                        ("p", "s", "ret"),
                        lifecycle_stopped_pattern,
                        f"stopped-task scheduler exclusion {iteration + 1}",
                        previous_count=previous_stopped_count,
                    )

                shell_cr3_pattern = re.escape(
                    b"Task 4 address-space root (0=none): 0x"
                ) + rb"[0-9A-F]{8}"
                run_command(
                    ("p", "s", "ret"),
                    shell_cr3_pattern,
                    "shell address-space root remains recorded",
                    previous_count=0,
                )

                # A stopped process must be restartable in the same boot.
                # This catches stale saved-RSP/context bugs that a reboot hides.
                previous_file_reads = len(re.findall(payload_pattern, output()))
                previous_exits = len(re.findall(exit_pattern, output()))
                previous_yields = len(re.findall(yield_pattern, output()))
                previous_resumes = len(re.findall(resumed_pattern, output()))
                run_command(("e", "x", "e", "c", "ret"), elf_output_pattern,
                            "restart ELF after normal exit", previous_count=1, timeout=8)
                deadline = time.monotonic() + 6
                while time.monotonic() < deadline:
                    data = output()
                    if (len(re.findall(payload_pattern, data)) > previous_file_reads
                            and len(re.findall(exit_pattern, data)) > previous_exits
                            and len(re.findall(yield_pattern, data)) > previous_yields
                            and len(re.findall(resumed_pattern, data)) > previous_resumes):
                        break
                    time.sleep(0.1)
                else:
                    raise RuntimeError("ELF process did not restart and finish after its first exit")
                run_command(("p", "s", "ret"), ps_stopped_pattern,
                            "restarted process returns to stopped state", previous_count=2)
                print("ELF loader, scheduler, file syscalls, exit, and same-boot restart passed.")

                old_banner_count = len(re.findall(banner_pattern, output()))
                reboot_pattern = re.escape(b"Rebooting NOVA OS...")
                run_command(("r", "e", "b", "o", "o", "t", "ret"),
                            reboot_pattern, "ELF persistence reboot", timeout=5)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    if len(re.findall(banner_pattern, output())) > old_banner_count:
                        break
                    time.sleep(0.1)
                else:
                    raise RuntimeError("VM did not reboot before persisted ELF execution test")
                persisted_cat_pattern = re.escape(b"File: user process wrote persistent data")
                run_command(("c", "a", "t", "ret"), persisted_cat_pattern,
                            "user-written file survives reboot")
                previous_file_reads = len(re.findall(payload_pattern, output()))
                previous_exits = len(re.findall(exit_pattern, output()))
                previous_yields = len(re.findall(yield_pattern, output()))
                previous_resumes = len(re.findall(resumed_pattern, output()))
                run_command(("e", "x", "e", "c", "ret"), elf_output_pattern,
                            "ELF execution after reboot", previous_count=1, timeout=8)
                deadline = time.monotonic() + 6
                while time.monotonic() < deadline:
                    data = output()
                    file_reads = len(re.findall(payload_pattern, data))
                    exits = len(re.findall(exit_pattern, data))
                    yields = len(re.findall(yield_pattern, data))
                    resumes = len(re.findall(resumed_pattern, data))
                    if (file_reads > previous_file_reads and exits > previous_exits
                            and yields > previous_yields and resumes > previous_resumes):
                        break
                    time.sleep(0.1)
                else:
                    raise RuntimeError(
                        "persisted ELF process did not write/read its file, yield, resume, and exit"
                    )
                print("ELF executable survived reboot and ran again.")

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
            print("Shell smoke test passed: scheduler, ring-3 isolation, memory, heap, and available filesystem checks.")
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
