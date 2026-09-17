#!/usr/bin/env python3
"""Stream a smoke suite and expose its failure in GitHub check annotations."""
from collections import deque
import shlex
import subprocess
import sys


def main():
    command = sys.argv[1:]
    if not command:
        raise SystemExit("usage: ci-smoke.py COMMAND [ARG ...]")
    tail = deque(maxlen=30)
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True, errors="replace") as process:
        for line in process.stdout:
            print(line, end="", flush=True)
            tail.append(line)
        status = process.wait()
    if status:
        message = f"{shlex.join(command)} exited {status}\n" + "".join(tail)
        message = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::error::{message}", flush=True)
    return status if status >= 0 else 128 - status


if __name__ == "__main__":
    sys.exit(main())
