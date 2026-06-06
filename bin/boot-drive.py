#!/usr/bin/env python3
"""boot-drive.py - orchestrate a hands-free JTAG bring-up of the ADSP-SC598 to a
Linux login prompt. Invoked by bin/boot-run.sh (which does the arg/preflight
work); not normally run by hand.

It collapses the three-terminal ADI dev flow (make openocd / make gdb / make
terminal) into one automated sequence:

  1. Start OpenOCD over the ICE (or reuse one already serving the GDB port).
  2. Drive GDB through a pseudo-tty for the two-stage JTAG load the SC598 needs
     in JTAG/no-boot mode: load SPL -> run (DDR init, then it spins waiting for
     proper) -> load U-Boot proper -> run. Proper's board_init_r probes the
     ADP5588 @ i2c2 0x34 and asserts uart0-en, which is what brings the console
     to life on a Rev-E SOM.
  3. Own the serial console (auto-probing the candidate ports if one is not
     pinned), interrupt autoboot, and type the network + bootargs + tftp + bootm
     sequence, gating on ping and the tftp transfer.
  4. Wait for the Linux login prompt. On success, optionally auto-login and/or
     hand the live console to minicom.

Pure Python 3 standard library - no third-party modules. Serial is configured
with stty and driven over a raw fd, so pyserial is not required.
"""

import argparse
import os
import pty
import re
import select
import signal
import socket
import subprocess
import sys
import threading
import time

PROMPT = r"\(gdb\)"
BANNER_RE = r"U-Boot SPL|U-Boot 20|Hit any key to stop|ADI Boot Mode"

# A power-cycle is the fix when the SoC is not in a clean JTAG state. The ICE
# cannot reset a running A55 (e.g. Linux still up from a previous make boot), so
# the GDB attach/reset fails. Detect that and say so plainly.
POWERCYCLE_MSG = (
    "could not cleanly attach/reset the SC598 over JTAG. The board is almost "
    "certainly NOT in a fresh JTAG state — most often it is still running Linux "
    "from a previous `make boot`, or BMODE is not in the JTAG/no-boot position. "
    "The ICE can't reset a running core. Fix: POWER-CYCLE the board (BMODE in "
    "JTAG/no-boot), then re-run `make boot`."
)
# Markers (seen in GDB's own stream) that the remote attach or the reset did not
# really take — the running-core / not-fresh-JTAG case. "abort occurred" and
# "Error executing event reset" are echoed back from OpenOCD through GDB when
# `monitor reset halt` fails on a live core; they never appear on a clean reset.
_BOTCHED = ("Remote replied unexpectedly", "Connection refused",
            "Connection timed out", "Remote communication error",
            '"monitor" command not supported', "Ignoring packet error",
            "Truncated register", "abort occurred", "Error executing event reset",
            "Error executing event gdb-attach")


def _connect_botched(text):
    return any(m in text for m in _BOTCHED)


def now():
    return time.monotonic()


def info(msg):
    sys.stdout.write(f"[boot] {msg}\n")
    sys.stdout.flush()


def die(msg, code=1):
    sys.stdout.write(f"[boot] ERROR: {msg}\n")
    sys.stdout.flush()
    raise BootError(msg, code)


class BootError(Exception):
    def __init__(self, msg, code=1):
        super().__init__(msg)
        self.code = code


# ----------------------------------------------------------------------------
# Stream: a read source (serial fd or gdb pty master) with line teeing to the
# user's screen + a log file, plus a regex expect() over the accumulated buffer.
# ----------------------------------------------------------------------------
class Stream:
    MAXBUF = 256 * 1024

    def __init__(self, name, prefix, logfh):
        self.name = name
        self.prefix = prefix
        self.logfh = logfh
        self.buf = ""
        self.pos = 0
        self.lock = threading.Lock()
        self._pending = ""
        self._stop = threading.Event()
        self._thread = None

    def _start_reader(self, fd):
        self._fd = fd
        self._thread = threading.Thread(target=self._reader, daemon=True)
        self._thread.start()

    def _reader(self):
        while not self._stop.is_set():
            try:
                r, _, _ = select.select([self._fd], [], [], 0.2)
            except (OSError, ValueError):
                break
            if not r:
                continue
            try:
                data = os.read(self._fd, 4096)
            except OSError:
                break
            if not data:
                break
            self._feed(data.decode("latin-1"))

    def _feed(self, text):
        with self.lock:
            self.buf += text
            if len(self.buf) > self.MAXBUF:
                drop = len(self.buf) - self.MAXBUF
                self.buf = self.buf[drop:]
                self.pos = max(0, self.pos - drop)
        self._tee(text)
        if self.logfh:
            try:
                self.logfh.write(text)
                self.logfh.flush()
            except OSError:
                pass

    def _tee(self, text):
        if self.prefix:
            self._pending += text
            while "\n" in self._pending:
                line, self._pending = self._pending.split("\n", 1)
                sys.stdout.write(f"{self.prefix}{line}\n")
        else:
            sys.stdout.write(text)
        sys.stdout.flush()

    def expect(self, patterns, timeout):
        if isinstance(patterns, str):
            patterns = [patterns]
        compiled = [re.compile(p) if isinstance(p, str) else p for p in patterns]
        deadline = now() + timeout
        while now() < deadline:
            with self.lock:
                hay = self.buf[self.pos:]
                best = None
                best_idx = None
                for i, c in enumerate(compiled):
                    m = c.search(hay)
                    if m and (best is None or m.start() < best.start()):
                        best = m
                        best_idx = i
                if best is not None:
                    self.pos += best.end()
                    return best_idx, best.group(0)
            time.sleep(0.05)
        return None

    def tail(self, n=1800):
        with self.lock:
            return self.buf[-n:]

    def stop(self):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=1.0)


# ----------------------------------------------------------------------------
# SerialConsole: a Stream over a raw serial fd we can also write to.
# ----------------------------------------------------------------------------
class SerialConsole(Stream):
    def __init__(self, port, baud, prefix, logfh):
        super().__init__(port, prefix, logfh)
        self.port = port
        self.baud = baud
        subprocess.run(
            ["stty", "-F", port, str(baud), "cs8", "-cstopb", "-parenb",
             "-echo", "raw"],
            check=True,
        )
        self.fd = os.open(port, os.O_RDWR | os.O_NOCTTY)
        self._start_reader(self.fd)

    def send_line(self, line, settle=0.3):
        os.write(self.fd, (line + "\r").encode("latin-1"))
        time.sleep(settle)

    def send_raw(self, data):
        os.write(self.fd, data)

    def close(self):
        self.stop()
        try:
            os.close(self.fd)
        except OSError:
            pass


# ----------------------------------------------------------------------------
# GdbPty: GDB driven over a pseudo-tty so we can script it interactively.
# ----------------------------------------------------------------------------
class GdbPty(Stream):
    def __init__(self, gdb_bin, spl_elf, logfh):
        super().__init__("gdb", "[gdb] ", logfh)
        self.master, slave = pty.openpty()
        self.proc = subprocess.Popen(
            [gdb_bin, "-q", spl_elf],
            stdin=slave, stdout=slave, stderr=slave,
            start_new_session=True, close_fds=True,
        )
        os.close(slave)
        self._start_reader(self.master)

    def send_line(self, line, expect_prompt=True, timeout=30):
        os.write(self.master, (line + "\n").encode("latin-1"))
        if expect_prompt:
            if self.expect([PROMPT], timeout) is None:
                die(f"gdb did not return a prompt after: {line}")

    def interrupt(self, timeout=8):
        os.write(self.master, b"\x03")
        return self.expect([PROMPT], timeout)

    def graceful_detach(self):
        try:
            os.write(self.master, b"\x03")
            self.expect([PROMPT], 5)
            os.write(self.master, b"detach\n")
            self.expect([PROMPT], 5)
            os.write(self.master, b"quit\n")
            self.proc.wait(timeout=5)
        except Exception:
            pass
        finally:
            self.kill()

    def kill(self):
        self.stop()
        if self.proc.poll() is None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=3)
            except Exception:
                try:
                    self.proc.kill()
                except Exception:
                    pass
        try:
            os.close(self.master)
        except OSError:
            pass


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
def port_open(host, port):
    try:
        with socket.create_connection((host or "127.0.0.1", int(port)), timeout=0.5):
            return True
    except OSError:
        return False


def spawn_openocd(args, logfh):
    cmd = ["bash", args.openocd_runner,
           "--openocd-bin", args.openocd_bin,
           "--scripts-dir", args.openocd_scripts,
           "--ice", args.openocd_ice,
           "--target", args.openocd_target,
           "--gdb-port", str(args.gdb_port),
           "--machine", args.machine]
    if args.openocd_sudo:
        cmd += ["--sudo", args.openocd_sudo]
    info(f"starting OpenOCD: {' '.join(cmd)}")
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    oocd = Stream("openocd", "[openocd] ", logfh)
    oocd._start_reader(proc.stdout.fileno())
    oocd.proc = proc
    return oocd


def wait_gdb_port(args, oocd):
    deadline = now() + args.openocd_timeout
    while now() < deadline:
        if port_open(args.gdb_host, args.gdb_port):
            return
        if oocd is not None and oocd.proc.poll() is not None:
            die("OpenOCD exited before serving the GDB port — see [openocd] output "
                "above (ICE connected? BMODE in JTAG position? udev/sudo for the ICE?)")
        time.sleep(0.25)
    die(f"OpenOCD never started serving :{args.gdb_port} within "
        f"{args.openocd_timeout}s")


def gdb_two_stage(gdb, args):
    """Connect + the two-stage SPL->proper JTAG load."""
    info("GDB: connecting to OpenOCD")
    if gdb.expect([PROMPT], 20) is None:
        die("gdb never reached its initial prompt")
    gdb.send_line("set pagination off")
    gdb.send_line("set confirm off")
    target = f"{args.gdb_host}:{args.gdb_port}" if args.gdb_host else f":{args.gdb_port}"
    info(f"GDB: target extended-remote {target}")
    os.write(gdb.master, (f"target extended-remote {target}\n").encode())
    if gdb.expect([PROMPT], 25) is None:
        die(f"gdb did not return after connecting to {target}")
    if _connect_botched(gdb.tail(3000)):
        die(POWERCYCLE_MSG)

    if args.gdb_reset:
        info("GDB: monitor reset halt")
        os.write(gdb.master, b"monitor reset halt\n")
        gdb.expect([PROMPT], 25)
        if _connect_botched(gdb.tail(2500)):
            die(POWERCYCLE_MSG)

    info(f"GDB: loading SPL ({os.path.basename(args.spl_elf)})")
    os.write(gdb.master, b"load\n")
    r = gdb.expect([r"Transfer rate", r"Load failed|Cannot access memory|No such file"], 60)
    if r is None or r[0] == 1:
        die("SPL load over JTAG failed. Usual cause: the board is not in a fresh JTAG "
            "state — POWER-CYCLE it (BMODE in JTAG/no-boot) and re-run. Otherwise check "
            "the ICE link and that the ELF matches the board.")
    gdb.expect([PROMPT], 10)

    # SPL runs board_init_f (DDR init) then, in JTAG/no-boot mode, spins waiting
    # for proper. Stop it AFTER DDR is up (proper's load fails if DDR is not
    # ready). The spin-symbol breakpoint is deterministic; a timeout falls back
    # to the proven manual technique (run a bit, then Ctrl-C).
    if args.spl_spin_sym:
        info(f"GDB: running SPL to {args.spl_spin_sym} (DDR init)")
        os.write(gdb.master, (f"tbreak {args.spl_spin_sym}\n").encode())
        bp = gdb.expect([r"breakpoint \d+ at", r"not defined|No symbol"], 8)
        if bp is None or bp[0] == 1:
            info(f"  symbol {args.spl_spin_sym} not found; using timed interrupt instead")
            gdb.expect([PROMPT], 5)
            _spl_run_timed(gdb, args)
        else:
            gdb.expect([PROMPT], 5)
            os.write(gdb.master, b"continue\n")
            hit = gdb.expect([rf"reakpoint \d+,.*{re.escape(args.spl_spin_sym)}",
                              rf"{re.escape(args.spl_spin_sym)} \("], args.spl_run_timeout)
            if hit is None:
                info("  spin breakpoint did not fire; interrupting SPL (fallback)")
                gdb.interrupt()
            else:
                gdb.expect([PROMPT], 5)
    else:
        _spl_run_timed(gdb, args)

    os.write(gdb.master, b"delete\n")          # drop the SPL breakpoint
    gdb.expect([PROMPT], 5)

    info(f"GDB: loading U-Boot proper ({os.path.basename(args.proper_elf)})")
    gdb.send_line(f"file {args.proper_elf}", timeout=15)
    os.write(gdb.master, b"load\n")
    r = gdb.expect([r"Transfer rate", r"Load failed|Cannot access memory"], 120)
    if r is None or r[0] == 1:
        die("U-Boot proper load failed — DDR likely not initialised. Try "
            "BOOT_GDB_RESET=1, or power-cycle the board (BMODE on JTAG) and retry.")
    gdb.expect([PROMPT], 10)

    info("GDB: continue — running U-Boot proper (console should come alive)")
    os.write(gdb.master, b"continue\n")        # target runs; gdb blocks here


def _spl_run_timed(gdb, args):
    info(f"GDB: running SPL for {args.spl_run_secs}s then interrupting")
    os.write(gdb.master, b"continue\n")
    time.sleep(args.spl_run_secs)
    gdb.interrupt()


def open_consoles(args, logfh):
    if args.serial_port:
        return [SerialConsole(args.serial_port, args.serial_baud, "", logfh)]
    cands = [c for c in args.serial_candidates.split() if c]
    if not cands:
        die("no serial port pinned (SERIAL_PORT) and no candidates to probe")
    info(f"auto-probing serial console across: {', '.join(cands)}")
    consoles = []
    for c in cands:
        try:
            consoles.append(SerialConsole(c, args.serial_baud,
                                          f"{os.path.basename(c)}| ", logfh))
        except (OSError, subprocess.CalledProcessError) as e:
            info(f"  cannot open {c}: {e} (skipping)")
    if not consoles:
        die("could not open any candidate serial port")
    return consoles


def select_console(consoles, timeout):
    if len(consoles) == 1:
        c = consoles[0]
        if c.expect([BANNER_RE], timeout) is None:
            die(f"no U-Boot banner on {c.port} within {timeout}s — wrong console "
                f"port, or proper never asserted uart0-en (check the [gdb] load)")
        c.prefix = ""
        c._pending = ""
        info(f"console: {c.port}")
        return c
    info("waiting for the U-Boot banner to reveal the console port...")
    deadline = now() + timeout
    banner = re.compile(BANNER_RE)
    while now() < deadline:
        for c in consoles:
            with c.lock:
                if banner.search(c.buf):
                    winner = c
                    break
        else:
            time.sleep(0.1)
            continue
        break
    else:
        die(f"no U-Boot banner on any candidate within {timeout}s — none of the "
            f"probed ports is the SC598 console (or proper never drove uart0-en)")
    for c in consoles:
        if c is not winner:
            c.close()
    winner.prefix = ""
    winner._pending = ""
    winner.pos = 0  # rescan from start for the prompt
    info(f"console identified: {winner.port}")
    return winner


def reach_uboot_prompt(console, args):
    info("interrupting autoboot, waiting for the U-Boot prompt")
    prompt = re.escape(args.uboot_prompt)
    deadline = now() + args.uboot_timeout
    got = False
    while now() < deadline:
        if console.expect([prompt], 0.3) is not None:
            got = True
            break
        console.send_raw(b" ")            # 'any key' stops autoboot; harmless at the prompt
    if not got:
        die("never reached the U-Boot '%s' prompt. Last console output:\n%s"
            % (args.uboot_prompt, console.tail()))
    # Submit any buffered spaces as a no-op so we start on a clean command line.
    console.send_raw(b"\r")
    console.expect([prompt], 5)


def send_boot_cmds(console, args):
    with open(args.cmds_file) as fh:
        cmds = [ln.rstrip("\n") for ln in fh if ln.strip()]
    info("driving U-Boot:")
    for line in cmds:
        sys.stdout.write(f"[boot]   => {line}\n")
        sys.stdout.flush()
        console.send_line(line)
        if line.startswith("ping"):
            r = console.expect([r"is alive",
                                r"not on the same|ping failed|host .* is not alive|timed out"], 20)
            if r is None or r[0] == 1:
                die("ping gate failed — board <-> host link is down. Not tftp'ing. "
                    "Last output:\n%s" % console.tail())
            info("  ping OK (link up)")
        elif line.startswith("tftp"):
            r = console.expect([r"Bytes transferred",
                                r"TFTP error|T T T T|not found|file not found|Retry count exceeded"], 90)
            if r is None or r[0] == 1:
                die("tftp of the fitImage failed — is the TFTP server running "
                    "(make tftp-ensure) and the fitImage staged (make tftp)? "
                    "Last output:\n%s" % console.tail())
            info("  fitImage transferred")


def wait_for_login(console, args):
    info(f"booting Linux — waiting up to {args.linux_timeout}s for '{args.login_regex}'")
    if console.expect([args.login_regex], args.linux_timeout) is None:
        die("Linux did not reach the login prompt in time. Last console output:\n%s"
            % console.tail())


def auto_login(console, args):
    info(f"auto-login as '{args.user}'")
    console.send_line(args.user)
    if args.password:
        if console.expect([r"[Pp]assword:"], 6) is not None:
            console.send_line(args.password)
    console.expect([r"# |\$ |~#"], 12)


def handoff_minicom(console, args):
    port = console.port
    if not sys.stdin.isatty():
        info(f"not a tty — skipping the minicom handoff. Board is at login on {port}.")
        info(f"  attach with:  make terminal SERIAL_PORT={port}")
        console.close()
        return
    console.close()
    info(f"handing the console to minicom on {port} (exit: Ctrl-A then X)")
    cmd = []
    if args.minicom_sudo:
        cmd += args.minicom_sudo.split()
    cmd += ["minicom", "-D", port, "-b", str(args.serial_baud), "-o"]
    try:
        os.execvp(cmd[0], cmd)
    except OSError as e:
        info(f"could not exec minicom ({e}). Run it yourself:")
        info(f"  make terminal SERIAL_PORT={port}")


def build_argparser():
    p = argparse.ArgumentParser(description="Drive the SC598 to a Linux login over JTAG.")
    p.add_argument("--openocd-runner", required=True)
    p.add_argument("--openocd-bin", required=True)
    p.add_argument("--openocd-scripts", required=True)
    p.add_argument("--openocd-ice", default="ice1000")
    p.add_argument("--openocd-target", default="adspsc59x_a55.cfg")
    p.add_argument("--openocd-sudo", default="")
    p.add_argument("--openocd-timeout", type=float, default=60.0)
    p.add_argument("--machine", required=True)
    p.add_argument("--gdb-bin", required=True)
    p.add_argument("--gdb-host", default="")
    p.add_argument("--gdb-port", default="3333")
    p.add_argument("--spl-elf", required=True)
    p.add_argument("--proper-elf", required=True)
    p.add_argument("--spl-spin-sym", default="board_boot_order")
    p.add_argument("--spl-run-secs", type=float, default=4.0)
    p.add_argument("--spl-run-timeout", type=float, default=20.0)
    p.add_argument("--gdb-reset", type=int, default=1)
    p.add_argument("--serial-port", default="")
    p.add_argument("--serial-candidates", default="")
    p.add_argument("--serial-baud", default="115200")
    p.add_argument("--cmds-file", required=True)
    p.add_argument("--uboot-prompt", default="=> ")
    p.add_argument("--uboot-timeout", type=float, default=90.0)
    p.add_argument("--login-regex", default="login:")
    p.add_argument("--linux-timeout", type=float, default=180.0)
    p.add_argument("--auto-login", type=int, default=0)
    p.add_argument("--user", default="root")
    p.add_argument("--password", default="")
    p.add_argument("--interactive", type=int, default=1)
    p.add_argument("--minicom-sudo", default="")
    p.add_argument("--log-file", default="")
    return p


def main():
    args = build_argparser().parse_args()
    logfh = open(args.log_file, "a") if args.log_file else None
    if logfh:
        logfh.write(f"\n===== make boot @ {time.strftime('%Y-%m-%d %H:%M:%S')} =====\n")
        logfh.flush()

    oocd = None
    gdb = None
    consoles = []
    interactive_exec = False

    def cleanup():
        if gdb is not None:
            gdb.graceful_detach()
        if oocd is not None and getattr(oocd, "proc", None) is not None:
            oocd.stop()
            if oocd.proc.poll() is None:
                try:
                    oocd.proc.terminate()
                    oocd.proc.wait(timeout=4)
                except Exception:
                    try:
                        oocd.proc.kill()
                    except Exception:
                        pass
        for c in consoles:
            try:
                c.close()
            except Exception:
                pass

    def on_signal(signum, frame):
        raise BootError(f"interrupted (signal {signum})", 130)

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    try:
        # 1. OpenOCD
        if port_open(args.gdb_host, args.gdb_port):
            info(f"OpenOCD already serving :{args.gdb_port} — reusing it")
        else:
            oocd = spawn_openocd(args, logfh)
            wait_gdb_port(args, oocd)
            info(f"OpenOCD up on :{args.gdb_port}")

        # 2. Serial (opened before GDB continues, so the banner is never missed)
        consoles = open_consoles(args, logfh)

        # 3. GDB two-stage JTAG load
        gdb = GdbPty(args.gdb_bin, args.spl_elf, logfh)
        gdb_two_stage(gdb, args)

        # 4. Identify the live console + reach the U-Boot prompt
        console = select_console(consoles, args.uboot_timeout)
        consoles = [console]
        reach_uboot_prompt(console, args)

        # 5. Network + bootargs + tftp + bootm (gated)
        send_boot_cmds(console, args)

        # 6. Linux login
        wait_for_login(console, args)
        info("SUCCESS — Linux login prompt reached.")
        if args.auto_login:
            auto_login(console, args)

        # 7. Done. Release JTAG (target keeps running), then optional handoff.
        if gdb is not None:
            gdb.graceful_detach()
            gdb = None
        if oocd is not None and getattr(oocd, "proc", None) is not None:
            oocd.stop()
            if oocd.proc.poll() is None:
                oocd.proc.terminate()
            oocd = None
        if args.interactive:
            interactive_exec = True
            handoff_minicom(console, args)  # execs minicom; does not return on success
        else:
            info(f"board is at the login prompt on {console.port}. "
                 f"Attach with: make terminal SERIAL_PORT={console.port}")
        return 0
    except BootError as e:
        return e.code
    finally:
        if not interactive_exec:
            cleanup()


if __name__ == "__main__":
    sys.exit(main())
