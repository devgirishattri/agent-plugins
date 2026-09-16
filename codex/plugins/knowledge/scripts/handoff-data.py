#!/usr/bin/env python3
"""Validate and render handoff v2 scope/items; evidence is never executed or verified."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import stat
import sys

ID = re.compile(r"[a-z0-9]+(?:_[a-z0-9]+)*\Z")
UTC = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\Z")
STATUSES = {"pending", "in_progress", "blocked", "done", "cancelled"}
KINDS = {"file", "commit", "test", "reference"}


def fail(message):
    raise ValueError(message)


def object_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def decode(text):
    return json.loads(text, object_pairs_hook=object_pairs,
                      parse_constant=lambda value: fail("non-finite JSON value"))


def read_regular(path):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | os.O_NONBLOCK)
    with os.fdopen(descriptor, "r", encoding="utf-8") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            fail("input must be an owned regular non-symlink file")
        return stream.read()


def fields(value, required, optional, label):
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    missing = set(required) - value.keys()
    unknown = value.keys() - set(required) - set(optional)
    if missing:
        fail(f"{label} missing fields: {', '.join(sorted(missing))}")
    if unknown:
        fail(f"{label} unknown fields: {', '.join(sorted(unknown))}")


def text_value(value, label):
    if not isinstance(value, str) or not value.strip():
        fail(f"{label} must be a nonempty string")
    # YAML printable ranges, restricted further to one physical line. JSON
    # accepts escaped C1 controls/surrogates, but literal YAML flow values do not.
    if any(not (0x20 <= ord(c) <= 0x7E or 0xA0 <= ord(c) <= 0xD7FF
                or 0xE000 <= ord(c) <= 0xFFFD or 0x10000 <= ord(c) <= 0x10FFFF)
           or c in "\u2028\u2029" for c in value):
        fail(f"{label} must be single-line YAML-printable text without control characters")
    return value


def timestamp(value, label):
    text_value(value, label)
    if not UTC.fullmatch(value):
        fail(f"{label} must be UTC YYYY-MM-DDTHH:MM:SSZ")
    try:
        datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        fail(f"{label} is not a valid calendar timestamp")


def relative_path(value, label):
    text_value(value, label)
    if value.startswith("/") or "\\" in value or ":" in value or ".." in value.split("/"):
        fail(f"{label} must be a repository-relative POSIX path without parent traversal")


def validate_data(data):
    fields(data, ("scope", "items"), (), "handoff data")
    scope = data["scope"]
    fields(scope, ("repository", "paths"), (), "scope")
    repository = text_value(scope["repository"], "scope.repository")
    if not ID.fullmatch(repository):
        fail("scope.repository must be a stable snake_case repository identifier")
    if not isinstance(scope["paths"], list) or not scope["paths"]:
        fail("scope.paths must be a nonempty list (use '.' for the repository root)")
    for path in scope["paths"]:
        relative_path(path, "scope.paths entry")
    if len(scope["paths"]) != len(set(scope["paths"])):
        fail("scope.paths contains duplicates")
    if not isinstance(data["items"], list) or not data["items"]:
        fail("items must be a nonempty list")
    ids = set()
    for item in data["items"]:
        fields(item, ("id", "summary", "status", "evidence"), (), "item")
        item_id = text_value(item["id"], "item.id")
        if not ID.fullmatch(item_id) or item_id in ids:
            fail("item.id must be unique snake_case")
        ids.add(item_id)
        text_value(item["summary"], f"item {item_id} summary")
        if not isinstance(item["status"], str) or item["status"] not in STATUSES:
            fail(f"item {item_id} status must be one of {', '.join(sorted(STATUSES))}")
        evidence = item["evidence"]
        if not isinstance(evidence, list):
            fail(f"item {item_id} evidence must be a list")
        if item["status"] == "done" and not evidence:
            fail(f"done item {item_id} requires at least one evidence entry (still unverified)")
        for entry in evidence:
            fields(entry, ("kind", "ref", "observed_at"), ("note",), f"item {item_id} evidence")
            if not isinstance(entry["kind"], str) or entry["kind"] not in KINDS:
                fail(f"evidence.kind must be one of {', '.join(sorted(KINDS))}")
            text_value(entry["ref"], "evidence.ref")
            timestamp(entry["observed_at"], "evidence.observed_at")
            if "note" in entry:
                text_value(entry["note"], "evidence.note")
            if entry["kind"] == "file":
                relative_path(entry["ref"], "file evidence.ref")
            if entry["kind"] == "commit" and not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", entry["ref"]):
                fail("commit evidence.ref must be a full lowercase 40- or 64-hex object ID")
    return data


def load_saved(path):
    return parse_saved(read_regular(path))


def parse_saved(text):
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        fail("saved handoff needs a leading frontmatter fence")
    try:
        end = lines.index("---", 1)
    except ValueError:
        fail("saved handoff frontmatter fence is unclosed")
    values = {}
    active = None
    allowed = {"handoff_version", "kind", "created", "updated", "expires", "tickets", "scope", "items"}
    for line in lines[1:end]:
        if not line:
            continue
        if line.startswith("  - ") and active in ("items", "tickets"):
            values[active].append(decode(line[4:]) if active == "items" else line[4:])
            continue
        key, separator, value = line.partition(":")
        if not separator or key not in allowed or key in values:
            fail("unknown, duplicate, or malformed v2 frontmatter field")
        value = value.strip()
        active = key
        if key in ("tickets", "items"):
            if value:
                fail(f"{key} must use one '  - ' entry per line")
            values[key] = []
        elif key == "scope":
            values[key] = decode(value)
        else:
            values[key] = value
    if values.get("handoff_version") != "2" or values.get("kind") != "handoff":
        fail("expected handoff_version: 2 and kind: handoff")
    for key in ("created", "updated", "expires"):
        timestamp(values.get(key), key)
    return validate_data({"scope": values.get("scope"), "items": values.get("items")})


def validate_transition(previous, updated):
    if previous["scope"]["repository"] != updated["scope"]["repository"]:
        fail("same-name handoff cannot change scope.repository; use a new handoff name")
    missing = {item["id"] for item in previous["items"]} - {item["id"] for item in updated["items"]}
    if missing:
        fail("existing item IDs must be retained; mark cancelled instead of omitting: " + ", ".join(sorted(missing)))


def render(data):
    # JSON is a valid YAML flow value; the profile uses one JSON object per
    # item, without a general YAML loader, aliases, tags, or executable values.
    yield "scope: " + json.dumps(data["scope"], ensure_ascii=False, sort_keys=True)
    yield "items:"
    for item in data["items"]:
        yield "  - " + json.dumps(item, ensure_ascii=False, sort_keys=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validator = commands.add_parser("validate", help="validate a saved v2 handoff, without checking evidence truth")
    validator.add_argument("handoff", type=Path)
    validator.add_argument("--summary", action="store_true", help="print item evidence counts, explicitly unverified")
    renderer = commands.add_parser("render", help="render validated scope/items for the save-context writer")
    renderer.add_argument("--data", type=Path)
    renderer.add_argument("--previous", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "validate":
            data = load_saved(args.handoff)
            if args.summary:
                for item in data["items"]:
                    print(f"item {item['id']} ({item['status']}): {len(item['evidence'])} evidence entries recorded, not verified")
        else:
            if not args.data and not args.previous:
                fail("render requires --data or --previous")
            previous = load_saved(args.previous) if args.previous else None
            data = validate_data(decode(read_regular(args.data))) if args.data else previous
            if previous is not None:
                validate_transition(previous, data)
            sys.stdout.write("\n".join(render(data)) + "\n")
    except (ValueError, TypeError, OSError, UnicodeError, RecursionError) as error:
        message = " ".join(str(error).splitlines())
        print(f"ERROR: handoff data: {message}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
