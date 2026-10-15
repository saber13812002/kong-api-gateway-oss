#!/usr/bin/env python3
"""Remote executor over paramiko for the s52 trial host.

Usage (password supplied via env var, never written to disk):
    S52_PASSWORD='...' python step4/remote_exec.py "hostname; docker ps --format '{{.Names}}'"
    S52_PASSWORD='...' python step4/remote_exec.py --upload C:/tmp/step4-bundle.tgz /tmp/step4-bundle.tgz
    S52_PASSWORD='...' python step4/remote_exec.py --long "bash step4/run.sh"   # streams output

Host/port from SSH config: 172.20.1.52:2222 (override with S52_HOST / S52_PORT).
Exit code = remote exit code.
"""
import os
import sys

HOST = os.environ.get("S52_HOST", "172.20.1.52")
PORT = int(os.environ.get("S52_PORT", "2222"))
USER = os.environ.get("S52_USER", "saber")
PASSWORD = os.environ.get("S52_PASSWORD", "")


def main() -> int:
    import paramiko  # local import so --help works without it

    if not PASSWORD:
        sys.stderr.write("S52_PASSWORD env var is required\n")
        return 2

    args = sys.argv[1:]
    upload = None
    if args and args[0] == "--upload":
        upload = (args[1], args[2])
        args = args[3:]
    long_run = False
    if args and args[0] == "--long":
        long_run = True
        args = args[1:]
    cmd = " ".join(args) if args else "echo ready"

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, port=PORT, username=USER, password=PASSWORD,
              timeout=30, allow_agent=False, look_for_keys=False,
              banner_timeout=60, auth_timeout=60)

    rc = 0
    try:
        if upload:
            local, remote = upload
            sftp = c.open_sftp()
            sftp.put(local, remote)
            sftp.close()
            print(f"UPLOADED {local} -> {USER}@{HOST}:{remote}")

        if cmd and cmd != "echo ready":
            if long_run:
                stdin, stdout, stderr = c.exec_command(cmd, timeout=None,
                                                       get_pty=False)
                for line in iter(stdout.readline, ""):
                    sys.stdout.write(line)
                    sys.stdout.flush()
                rc = stdout.channel.recv_exit_status()
            else:
                _, stdout, stderr = c.exec_command(cmd, timeout=300)
                out = stdout.read().decode("utf-8", "replace")
                err = stderr.read().decode("utf-8", "replace")
                if out:
                    sys.stdout.write(out)
                if err:
                    sys.stderr.write(err)
                rc = stdout.channel.recv_exit_status()
    finally:
        c.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
