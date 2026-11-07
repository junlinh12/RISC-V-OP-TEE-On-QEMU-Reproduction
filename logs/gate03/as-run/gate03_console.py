#!/usr/bin/env python3
# =============================================================================
#  Gate 03 : console driver for the RISC-V OP-TEE guest
#  Project : RISC-V-OP-TEE-On-QEMU-Reproduction
#
#  Python standard library only. Called by scripts/gate03_boot_xtest.sh.
#
#  QEMU exposes the guest UART (OpenSBI / U-Boot / Linux console) as a raw TCP
#  server on 127.0.0.1:64320 and waits for a client before starting the guest.
#  This driver replaces the manual "telnet localhost 64320" session of the
#  official instructions and types the same commands:
#    login as root -> environment checks -> optee_example_* -> xtest -> poweroff
#  Every byte received is written to the transcript file.
#
#  Each command is sent as  "<cmd>; echo __G03_RC<n>=$?__"  and the driver waits
#  for the marker with a numeric exit code. The echoed command line contains
#  the literal "$?" and therefore never matches.
#
#  Exit status: 0 = all checks passed, 1 = a check / test failed,
#               2 = infrastructure problem (connection, timeout, password prompt),
#               130 = interrupted with Ctrl-C
# =============================================================================
import argparse
import re
import socket
import sys
import time

PROMPT = r"[#$] $"
EXAMPLES = ["hello_world", "random", "aes", "hotp", "secure_storage"]
CHECKS = [
    ("uname", "uname -a"),
    ("kernel_cmdline", "cat /proc/cmdline"),
    ("tee_devices", "ls -l /dev/tee*"),
    ("tee_supplicant", "pidof tee-supplicant"),
    ("optee_driver", "dmesg | grep -i optee"),
]


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
        self.partial = ""
        self.line_hook = None

    def _recv(self):
        try:
            data = self.sock.recv(65536)
        except socket.timeout:
            return
        if not data:
            raise EOFError("console connection closed (QEMU exited)")
        self.log.write(data)
        self.log.flush()
        text = data.decode("utf-8", "replace")
        self.buf += text
        if self.line_hook:
            self.partial += text
            *lines, self.partial = self.partial.split("\n")
            for line in lines:
                self.line_hook(line.rstrip("\r"))

    def expect(self, pattern, timeout, heartbeat=None):
        rx = re.compile(pattern)
        start = last_beat = time.monotonic()
        while True:
            m = rx.search(self.buf)
            if m:
                self.before = self.buf[:m.start()]
                self.buf = self.buf[m.end():]
                return m
            now = time.monotonic()
            if now - start > timeout:
                raise TimeoutError(f"no match for {pattern!r} within {timeout} s")
            if heartbeat and now - last_beat >= heartbeat:
                say(f"... still running ({int((now - start) // 60)} min elapsed)")
                last_beat = now
            if len(self.buf) > 262144:          # keep memory bounded on long output
                self.buf = self.buf[-65536:]
            self._recv()

    def send(self, text):
        self.sock.sendall(text.encode())

    def close(self):
        try:
            self.sock.close()
        finally:
            self.log.close()


class Session:
    def __init__(self, con, cmd_timeout):
        self.con = con
        self.n = 0
        self.cmd_timeout = cmd_timeout

    def run(self, name, cmd, timeout=None, heartbeat=None):
        self.n += 1
        marker = f"__G03_RC{self.n}"
        t0 = time.monotonic()
        say(f"run   {name}: {cmd}")
        self.con.send(f"{cmd}; echo {marker}=$?__\n")
        m = self.con.expect(rf"{marker}=(\d+)__", timeout or self.cmd_timeout, heartbeat)
        rc = int(m.group(1))
        out = self.con.before
        self.con.expect(PROMPT, 60)
        say(f"done  {name}: rc={rc} ({time.monotonic() - t0:.0f} s)")
        print(f"STEP {name} rc={rc}", flush=True)
        return rc, out


def xtest_progress(line):
    if re.match(r"^\* \w+_\d+", line):
        say("xtest " + line[2:90])


def main():
    ap = argparse.ArgumentParser(description="Drive the guest console for G03.")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=64320)
    ap.add_argument("--transcript", required=True)
    ap.add_argument("--connect-timeout", type=int, default=60)
    ap.add_argument("--boot-timeout", type=int, default=900)
    ap.add_argument("--cmd-timeout", type=int, default=300)
    ap.add_argument("--xtest-timeout", type=int, default=10800)
    args = ap.parse_args()

    failures = 0
    infra_error = None
    con = None
    try:
        con = Console(args.host, args.port, args.transcript, args.connect_timeout)
        say(f"connected to {args.host}:{args.port} - QEMU starts the guest now")
        con.expect(r"login: ?$", args.boot_timeout, heartbeat=60)
        say("login prompt reached")
        con.send("root\n")
        m = con.expect(r"(Password: ?$|[#$] $)", 60)
        if m.group(1).startswith("Password"):
            raise RuntimeError("the guest asks for a root password; the driver does not guess passwords")
        say("logged in as root")
        s = Session(con, args.cmd_timeout)

        for name, cmd in CHECKS:
            rc, _ = s.run(name, cmd)
            failures += rc != 0

        for ex in EXAMPLES:
            rc, _ = s.run(f"example_{ex}", f"optee_example_{ex}")
            failures += rc != 0

        con.line_hook = xtest_progress
        rc, out = s.run("xtest", "xtest", timeout=args.xtest_timeout, heartbeat=300)
        con.line_hook = None
        summary = {
            "xtest_rc": rc,
            "subtests": re.search(r"(\d+) subtests? of which (\d+) failed", out),
            "cases": re.search(r"(\d+) test cases? of which (\d+) failed", out),
            "skipped": re.search(r"(\d+) test cases? (?:was|were) skipped", out),
        }
        print(f"SUMMARY xtest_rc={rc}", flush=True)
        for key in ("subtests", "cases"):
            mm = summary[key]
            if mm:
                print(f"SUMMARY xtest_{key}={mm.group(1)} xtest_{key}_failed={mm.group(2)}", flush=True)
                failures += int(mm.group(2)) > 0
            else:
                print(f"SUMMARY xtest_{key}=NOT_FOUND", flush=True)
                failures += 1
        if summary["skipped"]:
            print(f"SUMMARY xtest_skipped={summary['skipped'].group(1)}", flush=True)
        failed_names = sorted(set(re.findall(r"^\s*(\w+_\d+)\s+FAILED", out, re.M)))
        if failed_names:
            print("SUMMARY xtest_failed_cases=" + ",".join(failed_names), flush=True)
        failures += rc != 0

        say("poweroff")
        con.send("poweroff\n")
        try:
            con.expect(r"(reboot: Power down|System halted)", 180)
            say("guest powered off")
        except EOFError:
            say("console closed (QEMU exited)")
    except (TimeoutError, EOFError, ConnectionError, RuntimeError, OSError) as exc:
        infra_error = str(exc)
    finally:
        if con:
            con.close()

    if infra_error:
        print(f"SUMMARY infrastructure_error={infra_error}", flush=True)
        return 2
    print(f"SUMMARY failed_checks={failures}", flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("SUMMARY interrupted_by_user", flush=True)
        sys.exit(130)
