#!/usr/bin/env python3
# =============================================================================
#  Gate 05a : console driver for the isolation demonstration
#  Project  : RISC-V-OP-TEE-On-QEMU-Reproduction
#
#  Python standard library only. Called by scripts/gate05a_isolation.sh.
#  READ accesses only - this driver never writes to guest memory.
#
#  --mode uboot : stop U-Boot's autoboot, then read physical memory with
#                 "md.l <addr> 4". U-Boot runs in S-mode in the UNTRUSTED
#                 domain, without the /dev/mem filters of Linux, so a denied
#                 read shows the PMP enforcement directly. After a faulting
#                 read U-Boot halts; the caller stops QEMU.
#  --mode linux : log in, show /proc/iomem, try "devmem <addr> 32" (busybox,
#                 mmap from user space: a denied access only kills devmem),
#                 then dmesg and poweroff.
#
#  Each read is classified:
#    READ_OK            the value was returned
#    DENIED_FAULT       access fault (U-Boot "Unhandled exception", OpenSBI
#                       trap error, or SIGSEGV/SIGBUS of devmem)
#    BLOCKED_BY_KERNEL  Linux refused before touching memory (e.g. STRICT_DEVMEM)
#    OTHER              anything else (see the transcript)
#  Output lines "RESULT <name> <address> <classification>" are parsed by the
#  caller. Exit status: 0 = finished, 2 = infrastructure problem, 130 = Ctrl-C
# =============================================================================
import argparse
import re
import socket
import sys
import time

PROMPT_SH = r"[#$] $"
PROMPT_UB = r"=> $"
FAULT_UB = r"(Unhandled exception[^\n]*|sbi_trap_error[^\n]*|[Ll]oad access fault[^\n]*)"


def say(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


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

    def drain(self, seconds):
        """collect whatever arrives for a while (e.g. register dump after a fault)"""
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            try:
                self._recv()
            except EOFError:
                break
        out, self.buf = self.buf, ""
        return out

    def send(self, text):
        self.sock.sendall(text.encode())

    def close(self):
        try:
            self.sock.close()
        finally:
            self.log.close()


def result(name, addr, cls, detail=""):
    print(f"RESULT {name} {addr} {cls}" + (f" | {detail}" if detail else ""), flush=True)


def uboot_mode(con, args):
    con.expect(r"Hit any key to stop autoboot", args.boot_timeout)
    con.send(" ")
    con.expect(PROMPT_UB, 30)
    say("U-Boot prompt reached (autoboot stopped)")
    reads = [("control", a) for a in args.control] + [("probe", a) for a in args.probe]
    for kind, addr in reads:
        val = int(addr, 16)
        say(f"md.l {addr} 4   ({kind})")
        con.send(f"md.l {addr} 4\n")
        m = con.expect(rf"({PROMPT_UB})|{FAULT_UB}", 30)
        if m.group(1):          # prompt came back
            dump = re.search(rf"{val:08x}:((?: [0-9a-f]{{8}})+)", con.before)
            if dump:
                result(f"uboot_{kind}", addr, "READ_OK", dump.group(0).strip())
            else:
                result(f"uboot_{kind}", addr, "OTHER", con.before.strip().splitlines()[-1:] and con.before.strip().splitlines()[-1])
        else:
            tail = con.drain(3)
            tval = re.search(r"(?:TVAL|MTVAL|STVAL|tval)[: ]+\s*([0-9a-fx]+)", tail)
            detail = m.group(0).strip() + (f"; TVAL {tval.group(1)}" if tval else "")
            result(f"uboot_{kind}", addr, "DENIED_FAULT", detail)
            say("U-Boot halted after the fault - the caller stops QEMU")
            return
    say("all U-Boot reads done")


class Shell:
    def __init__(self, con, cmd_timeout):
        self.con = con
        self.n = 0
        self.cmd_timeout = cmd_timeout

    def run(self, cmd):
        self.n += 1
        marker = f"__G05_RC{self.n}"
        say(f"run   {cmd}")
        self.con.send(f"{cmd}; echo {marker}=$?__\n")
        m = self.con.expect(rf"{marker}=(\d+)__", self.cmd_timeout)
        rc = int(m.group(1))
        out = self.con.before
        self.con.expect(PROMPT_SH, 60)
        say(f"done  rc={rc}")
        return rc, out


def classify_devmem(rc, out):
    if rc == 0 and re.search(r"^\s*0x[0-9A-Fa-f]+\s*$", out, re.M):
        return "READ_OK"
    if rc in (135, 139) or re.search(r"Segmentation fault|Bus error", out):
        return "DENIED_FAULT"
    if re.search(r"Operation not permitted|Permission denied|Bad address|can't open|Invalid argument", out):
        return "BLOCKED_BY_KERNEL"
    return "OTHER"


def linux_mode(con, args):
    con.expect(r"login: ?$", args.boot_timeout)
    con.send("root\n")
    m = con.expect(r"(Password: ?$|[#$] $)", 60)
    if m.group(1).startswith("Password"):
        raise RuntimeError("the guest asks for a root password; the driver does not guess passwords")
    say("logged in as root")
    sh = Shell(con, args.cmd_timeout)
    sh.run("uname -a")
    rc, out = sh.run("cat /proc/iomem")
    for line in out.splitlines():
        if re.search(r"80100000|80140000|f1000000", line):
            print("IOMEM " + line.strip(), flush=True)
    rc, out = sh.run("command -v devmem")
    if rc != 0:
        for kind, addr in [("control", a) for a in args.control] + [("probe", a) for a in args.probe]:
            result(f"linux_{kind}", addr, "OTHER", "devmem not available in the guest")
    else:
        sh.run("zcat /proc/config.gz 2>/dev/null | grep -E 'CONFIG_(STRICT_|IO_STRICT_)?DEVMEM' || echo '(no /proc/config.gz)'")
        for kind, addr in [("control", a) for a in args.control] + [("probe", a) for a in args.probe]:
            rc, out = sh.run(f"devmem {addr} 32")
            lines = [ln.strip() for ln in out.splitlines() if ln.strip() and "devmem" not in ln]
            result(f"linux_{kind}", addr, classify_devmem(rc, out), f"rc={rc} " + (lines[-1] if lines else ""))
    sh.run("dmesg | tail -n 25")
    say("poweroff")
    con.send("poweroff\n")
    try:
        con.expect(r"(reboot: Power down|System halted)", 180)
    except EOFError:
        pass


def main():
    ap = argparse.ArgumentParser(description="G05a isolation demonstration console driver")
    ap.add_argument("--mode", choices=("uboot", "linux"), required=True)
    ap.add_argument("--control", action="append", default=[], help="address expected to be readable (hex)")
    ap.add_argument("--probe", action="append", default=[], help="address expected to be denied (hex)")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=64320)
    ap.add_argument("--transcript", required=True)
    ap.add_argument("--connect-timeout", type=int, default=60)
    ap.add_argument("--boot-timeout", type=int, default=600)
    ap.add_argument("--cmd-timeout", type=int, default=120)
    args = ap.parse_args()
    con = None
    try:
        con = Console(args.host, args.port, args.transcript, args.connect_timeout)
        say(f"connected - QEMU starts the guest now (mode {args.mode})")
        uboot_mode(con, args) if args.mode == "uboot" else linux_mode(con, args)
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
