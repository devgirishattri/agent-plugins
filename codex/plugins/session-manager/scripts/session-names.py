#!/usr/bin/env python3
"""Read the latest explicit Codex session names as sanitized ID/name TSV."""

import calendar
from datetime import datetime
from decimal import Decimal
import json
import re
import sys


SESSION_ID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z")
TIMESTAMP = re.compile(
    r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})\Z"
)


def timestamp_key(value):
    """Normalize offsets while preserving sub-microsecond precision."""
    if not isinstance(value, str):
        raise ValueError("timestamp must be a string")
    match = TIMESTAMP.fullmatch(value)
    if match is None:
        raise ValueError("invalid timestamp")
    base, fraction, offset = match.groups()
    stamp = datetime.fromisoformat(base + offset.replace("Z", "+00:00"))
    return calendar.timegm(stamp.utctimetuple()), Decimal("0." + (fraction or "0"))


def latest_names(lines):
    latest = {}
    for line in lines:
        try:
            entry = json.loads(line)
            if not isinstance(entry, dict):
                continue
            session_id = entry.get("id")
            name = entry.get("thread_name")
            if not isinstance(session_id, str) or not SESSION_ID.fullmatch(session_id):
                continue
            # Null/missing/empty names explicitly clear an older name.
            if name is None:
                name = ""
            if not isinstance(name, str):
                continue
            timestamp = timestamp_key(entry.get("updated_at"))
        except (ValueError, OverflowError):
            # A malformed or partially written row must not discard other names.
            continue
        if session_id not in latest or timestamp >= latest[session_id][0]:
            # Last physical row wins when two timestamps represent the same instant.
            name = re.sub(r"[\x00-\x1f\x7f]", " ", name)
            if not name.strip():
                name = ""
            latest[session_id] = timestamp, name
    return {session_id: name for session_id, (_, name) in latest.items()}


def main():
    try:
        with open(sys.argv[1], encoding="utf-8", errors="replace") as index:
            names = latest_names(index)
    except FileNotFoundError:
        return 0
    except OSError as error:
        print("ERROR: Cannot read session index: " + str(error), file=sys.stderr)
        return 1
    for session_id, name in names.items():
        if name:
            # Invalid escaped surrogate code points must not abort all output.
            name = name.encode("utf-8", errors="replace").decode("utf-8")
            print(session_id + "\t" + name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
