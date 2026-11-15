#!/usr/bin/env python3
"""Run a command on a terminal, answer ubuntu-look.sh's prompts, keep a transcript.

usage: drive.py <transcript> <y|n> <timeout-seconds> -- command...

Answers the yes/no prompt with <y|n> and sudo's prompt with $VM_PASSWORD.
$DRIVE_COUNTDOWN chooses the key sent six seconds into the reboot countdown:
"enter", "ctrlc", or nothing to let it run out.

Exits 124 when the command did not end in time: it is then sent Ctrl-C through
its terminal, which reaches the remote command too, before it is stopped.
Otherwise exits 0; the command's own status is in the transcript's last line.
"""
import os
import pty
import re
import select
import sys
import time

out_path, answer, timeout = sys.argv[1], sys.argv[2], int(sys.argv[3])
command = sys.argv[5:]
password = os.environ.get("VM_PASSWORD", "")
key = {"enter": b"\n", "ctrlc": b"\x03"}.get(os.environ.get("DRIVE_COUNTDOWN", ""))
key_at = None
timed_out = False

pid, fd = pty.fork()
if pid == 0:
    os.execvp(command[0], command)

buf = b""
start = time.time()
with open(out_path, "wb") as log:
    while True:
        if time.time() - start > timeout:
            timed_out = True
            log.write(b"\n### drive.py: TIMEOUT\n")
            # Over ssh -tt a kill would end only the local end; Ctrl-C on the
            # terminal stops the command at the far end as well.
            try:
                os.write(fd, b"\x03")
                time.sleep(5)
            except OSError:
                pass
            try:
                os.kill(pid, 15)
            except ProcessLookupError:
                pass
            break
        if key and key_at and time.time() >= key_at:
            os.write(fd, key)
            key = None
        ready, _, _ = select.select([fd], [], [], 1.0)
        if not ready:
            continue
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        log.write(data)
        log.flush()
        buf = (buf + data)[-4000:]
        if key and key_at is None and b"Rebooting in" in buf:
            key_at = time.time() + 6
        if re.search(rb"\[sudo\][^\n]*:\s*$", buf):
            os.write(fd, password.encode() + b"\n")
            buf = b""
        elif re.search(rb"\[y/N\?\]\s*$", buf):
            os.write(fd, answer.encode() + b"\n")
            buf = b""
    _, status = os.waitpid(pid, 0)
    log.write(b"\n### drive.py: exit %d\n" % os.waitstatus_to_exitcode(status))
sys.exit(124 if timed_out else 0)
