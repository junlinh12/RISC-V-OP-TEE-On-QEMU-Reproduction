#!/usr/bin/env python3
# =============================================================================
#  Gate 05b-2 : Linux console driver for the M2 / M3 interrupt tests
#  Project    : RISC-V-OP-TEE-On-QEMU-Reproduction
#
#  Python standard library only. Called by scripts/gate05b_test.sh.
#  Linux runs on hvc0 (virtio console, TCP 127.0.0.1:64321). OpenSBI and the
#  bare-metal apps use the QEMU stdio console, where the bash script injects
#  the key presses. The two sides synchronise through barrier files:
#    --ready-file : created here once Linux is up and the first checks ran
#    --go-file    : created by the caller after the key tests on the OpenSBI side
#
#  Checks (as in the official M2 / M3 instructions):
#    - APLIC registered in Linux (dmesg)
#    - APLIC-DIRECT interrupt lines present and still counting afterwards
#      (Linux interrupt handling not affected by the M-mode / VIRQ changes)
#    - M2 only: IRQ affinity follows smp_affinity_list (CPU1, then CPU0)
#  Disk activity for the counters: read-only dd from /dev/vda at fixed offsets.
#  Output lines "RESULT <name> PASS|FAIL | detail" are parsed by the caller.
#  Exit status: 0 finished, 2 infrastructure problem, 130 Ctrl-C
# =============================================================================
import argparse
import os
import re
import socket
import sys
import time

PROMPT = r"[#$] $"


def say(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def result(name, ok, detail=""):
    print(f"RESULT {name} {'PASS' if ok else 'FAIL'}" + (f" | {detail}" if detail else ""), flush=True)


class Console:
    def __init__(self, host, port, transcript, connect_timeout):
        self.log = open(transcript, "wb")
        deadline = time.monotonic() + connect_timeout
        while True:
            try:
                self.sock = socket.create_connection((host, port), timeout=5)
                break
            except OSError as exc:
                if time.monotonic() > deadline:
                    raise ConnectionError(f"cannot connect to {host}:{port}: {exc}") from exc
                time.sleep(1)
        self.sock.settimeout(1.0)
        self.buf = ""
        self.before = ""

    def _recv(self):
        try:
            data = self.sock.recv(65536)
        except socket.timeout:
            return
        if not data:
            raise EOFError("console connection closed (QEMU exited)")
        self.log.write(data)
        self.log.flush()
        self.buf += data.decode("utf-8", "replace")

    def expect(self, pattern, timeout):
        rx = re.compile(pattern)
        start = time.monotonic()
        while True:
            m = rx.search(self.buf)
            if m:
                self.before = self.buf[:m.start()]
                self.buf = self.buf[m.end():]
                return m
            if time.monotonic() - start > timeout:
                raise TimeoutError(f"no match for {pattern!r} within {timeout} s")
            if len(self.buf) > 262144:
                self.buf = self.buf[-65536:]
            self._recv()

    def idle(self, seconds):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            self._recv()

    def send(self, text):
        self.sock.sendall(text.encode())

    def close(self):
        try:
            self.sock.close()
        finally:
            self.log.close()


class Shell:
    def __init__(self, con, timeout):
        self.con, self.n, self.timeout = con, 0, timeout

    def run(self, cmd):
        self.n += 1
        marker = f"__G05B_RC{self.n}"
        say(f"run   {cmd}")
        self.con.send(f"{cmd}; echo {marker}=$?__\n")
        m = self.con.expect(rf"{marker}=(\d+)__", self.timeout)
        rc, out = int(m.group(1)), self.con.before
        self.con.expect(PROMPT, 60)
        say(f"done  rc={rc}")
        return rc, out


def interrupts(sh):
    """parse /proc/interrupts -> {irq: (cpu0, cpu1, chip, name)} for numbered lines"""
    _, out = sh.run("cat /proc/interrupts")
    table = {}
    for line in out.splitlines():
        m = re.match(r"\s*(\d+):\s+(\d+)\s+(\d+)\s+(\S+)\s+.*?(\S+)\s*$", line)
        if m:
            table[int(m.group(1))] = (int(m.group(2)), int(m.group(3)), m.group(4), m.group(5))
    return table


def aplic_total(table):
    return sum(c0 + c1 for c0, c1, chip, _ in table.values() if chip.startswith("APLIC"))


def wait_file(path, timeout, con):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if os.path.exists(path):
            return True
        con.idle(1)
    return False


def main():
    ap = argparse.ArgumentParser(description="G05b-2 Linux console driver")
    ap.add_argument("--target", choices=("m2", "m3"), required=True)
    ap.add_argument("--port", type=int, default=64321)
    ap.add_argument("--transcript", required=True)
    ap.add_argument("--ready-file", required=True)
    ap.add_argument("--go-file", required=True)
    ap.add_argument("--connect-timeout", type=int, default=60)
    ap.add_argument("--boot-timeout", type=int, default=600)
    ap.add_argument("--cmd-timeout", type=int, default=180)
    ap.add_argument("--wait-timeout", type=int, default=300)
    args = ap.parse_args()
    con = None
    try:
        con = Console("127.0.0.1", args.port, args.transcript, args.connect_timeout)
        say("connected to the Linux console (hvc0)")
        con.expect(r"login: ?$", args.boot_timeout)
        con.send("root\n")
        m = con.expect(r"(Password: ?$|[#$] $)", 60)
        if m.group(1).startswith("Password"):
            raise RuntimeError("the guest asks for a root password; the driver does not guess passwords")
        say("logged in as root")
        sh = Shell(con, args.cmd_timeout)
        sh.run("uname -a; nproc")
        rc, out = sh.run("dmesg | grep -iE 'aplic|imsic|aia|irqchip|riscv-intc'")
        lines = [ln.strip() for ln in out.splitlines() if re.search(r"aplic", ln, re.I) and "grep" not in ln]
        result("linux_aplic_registered", bool(lines), lines[0] if lines else "no APLIC line in dmesg")
        snap1 = interrupts(sh)
        aplic = {k: v for k, v in snap1.items() if v[2].startswith("APLIC")}
        result("linux_aplic_direct_lines", bool(aplic),
               ", ".join(f"{k}:{v[3]}" for k, v in sorted(aplic.items())) or "none")

        open(args.ready_file, "w").close()
        say("Linux side ready - waiting while keys are tested on the OpenSBI console")
        if not wait_file(args.go_file, args.wait_timeout, con):
            raise TimeoutError("the caller did not finish the key tests in time")

        sh.run("dd if=/dev/vda of=/dev/null bs=1M count=32 skip=64 2>&1 | tail -n 1")
        snap2 = interrupts(sh)
        before, after = aplic_total(snap1), aplic_total(snap2)
        result("linux_aplic_counters", after > before, f"APLIC-DIRECT total {before} -> {after}")

        if args.target == "m2":
            rc, out = sh.run("basename $(readlink /sys/block/vda/device)")
            dev = out.strip().splitlines()[-1].strip() if out.strip() else ""
            irq = next((k for k, v in snap2.items() if v[3] == dev and v[2].startswith("APLIC")), None)
            if irq is None:
                result("linux_affinity", False, f"no APLIC line for the vda device {dev!r}")
            else:
                for cpu, skip in ((1, 128), (0, 192)):
                    sh.run(f"echo {cpu} > /proc/irq/{irq}/smp_affinity_list")
                    a = interrupts(sh)
                    sh.run(f"dd if=/dev/vda of=/dev/null bs=1M count=32 skip={skip} 2>&1 | tail -n 1")
                    b = interrupts(sh)
                    d0, d1 = b[irq][0] - a[irq][0], b[irq][1] - a[irq][1]
                    ok = (d1 > 0 and d0 == 0) if cpu == 1 else (d0 > 0 and d1 == 0)
                    result(f"linux_affinity_cpu{cpu}", ok, f"irq {irq} ({dev}): CPU0 +{d0}, CPU1 +{d1}")

        say("poweroff")
        con.send("poweroff\n")
        try:
            con.expect(r"(reboot: Power down|System halted)", 120)
        except (EOFError, TimeoutError):
            pass
        return 0
    except (TimeoutError, EOFError, ConnectionError, RuntimeError, OSError) as exc:
        print(f"SUMMARY infrastructure_error={exc}", flush=True)
        return 2
    finally:
        if con:
            con.close()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("SUMMARY interrupted_by_user", flush=True)
        sys.exit(130)
