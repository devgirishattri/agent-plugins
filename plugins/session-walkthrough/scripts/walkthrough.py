#!/usr/bin/env python3
"""session-walkthrough helper (Claude tree): validate, render and scope.

Python 3 standard library only. Run it as ``python3 -B walkthrough.py <command>``.

  validate  Check a manifest against manifest.schema.json and every WT-* rule.
  render    Validate, then write a self-contained index.html in the run directory.
  scope     Record a bounded, content-free fingerprint of the dirty working tree
            at the start or the end of a task and derive the manifest scope blocks.

Exit codes: 0 valid or done, 1 manifest invalid, 2 unusable input, unsafe
location or lock refusal. Tunables are read from the environment on every
invocation and are never exported:

  SESSION_WALKTHROUGH_OUTPUT_ROOT            default .tmp/walkthroughs
  SESSION_WALKTHROUGH_FINGERPRINT_MAX_BYTES  default 8388608
  SESSION_WALKTHROUGH_LOCK_TIMEOUT_SECS      default 10
"""
import argparse
import datetime
import hashlib
import html
import json
import math
import os
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import traceback

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DESCRIPTORS = os.path.join(SCRIPT_DIR, "descriptors")
MANIFEST_SCHEMA_PATH = os.path.join(SCRIPT_DIR, "manifest.schema.json")
DESCRIPTOR_SCHEMA_PATH = os.path.join(SCRIPT_DIR, "descriptor.schema.json")

EXIT_OK = 0
EXIT_INVALID = 1
EXIT_UNUSABLE = 2

MAX_JSON_BYTES = 16 * 1024 * 1024
MAX_FAILURES = 1000
MAX_SNAPSHOT_ENTRIES = 20000
DEFAULT_FINGERPRINT_MAX_BYTES = 8388608
DEFAULT_LOCK_TIMEOUT_SECS = 10
DEFAULT_OUTPUT_ROOT = ".tmp/walkthroughs"
DEFAULT_START_REASON = "scope start was not recorded"
BASE_LIMITATION = "Fingerprints show that paths changed; they do not prove who changed them"

BOM = chr(0xFEFF)

MEDIA_BY_EXTENSION = {
    "png": "image/png",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "webp": "image/webp",
    "mp4": "video/mp4",
    "mov": "video/quicktime",
    "webm": "video/webm",
}


class Unusable(Exception):
    """Input, location or environment that cannot be used safely (exit 2)."""


# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

def escape_token(token):
    return str(token).replace("~", "~0").replace("/", "~1")


def pointer(path):
    """JSON pointer for a path list; the document root is shown as '/'."""
    if not path:
        return "/"
    return "/" + "/".join(escape_token(token) for token in path)


def brief(value, limit=80):
    """Single-line, ASCII-only rendering of a value for failure messages."""
    text = json.dumps(value, ensure_ascii=True)
    if len(text) > limit:
        text = text[: limit - 3] + "..."
    return text


def one_line(message, limit=300):
    text = re.sub(r"[\x00-\x1f\x7f]", " ", message)
    return text if len(text) <= limit else text[: limit - 3] + "..."


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def dget(node, *keys):
    for key in keys:
        if not isinstance(node, dict) or key not in node:
            return None
        node = node[key]
    return node


def as_list(value):
    return value if isinstance(value, list) else []


def as_dict(value):
    return value if isinstance(value, dict) else {}


def utc_now_text():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def env_int(name, default, minimum):
    """Read a positive integer tunable per invocation; anything else is the default."""
    raw = os.environ.get(name, "")
    if re.fullmatch(r"[0-9]{1,15}", raw):
        value = int(raw)
        if value >= minimum:
            return value
    return default


# --------------------------------------------------------------------------
# Strict JSON: owned regular non-symlink reads, duplicate keys, non-finite numbers
# --------------------------------------------------------------------------

class StrictObject(dict):
    """A dict that remembers the duplicate keys seen while it was parsed."""
    __slots__ = ("duplicates",)


def _object_pairs(pairs):
    obj = StrictObject()
    obj.duplicates = []
    for key, value in pairs:
        if key in obj:
            obj.duplicates.append(key)
        obj[key] = value
    return obj


class NonFinite(Exception):
    pass


def _reject_constant(name):
    raise NonFinite("non-finite number %s" % name)


def _parse_float(text):
    value = float(text)
    if not math.isfinite(value):
        raise NonFinite("non-finite number %s" % text)
    return value


def _collect_duplicates(node, path, out):
    if isinstance(node, dict):
        for key in getattr(node, "duplicates", ()):
            out.append((path + [key], "duplicate object key %s" % brief(key)))
        for key, value in node.items():
            _collect_duplicates(value, path + [key], out)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            _collect_duplicates(value, path + [index], out)


def parse_json_text(text, label):
    """Return (document, problems); problems are (path, message) strict-JSON violations."""
    try:
        document = json.loads(text, object_pairs_hook=_object_pairs,
                              parse_constant=_reject_constant, parse_float=_parse_float)
    except NonFinite as exc:
        return None, [([], str(exc))]
    except RecursionError:
        raise Unusable("%s is nested too deeply" % label)
    except ValueError as exc:
        raise Unusable("%s is not valid JSON: %s" % (label, exc))
    problems = []
    try:
        _collect_duplicates(document, [], problems)
    except RecursionError:
        raise Unusable("%s is nested too deeply" % label)
    return document, problems


def read_regular_bytes(path, label, limit=MAX_JSON_BYTES):
    """Read an owned regular file; a symlink at the final component is refused."""
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    flags |= getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        if exc.errno in (getattr(os, "ELOOP", -1), getattr(os, "EMLINK", -1)):
            raise Unusable("%s must be an owned regular non-symlink file: %s" % (label, path))
        raise Unusable("%s is not readable: %s (%s)" % (label, path, exc.strerror or exc))
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
            raise Unusable("%s must be an owned regular non-symlink file: %s" % (label, path))
        if info.st_size > limit:
            raise Unusable("%s is larger than %d bytes: %s" % (label, limit, path))
        chunks = []
        total = 0
        while True:
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                break
            total += len(chunk)
            if total > limit:
                raise Unusable("%s is larger than %d bytes: %s" % (label, limit, path))
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


def load_json_file(path, label):
    raw = read_regular_bytes(path, label)
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise Unusable("%s is not valid UTF-8 (%s): %s" % (label, exc.reason, path))
    if text.startswith(BOM):
        raise Unusable("%s starts with a byte-order mark: %s" % (label, path))
    return parse_json_text(text, label)


def load_json_strict(path, label):
    """Load a support file (schema, descriptor, snapshot); any strictness problem is fatal."""
    document, problems = load_json_file(path, label)
    if problems:
        raise Unusable("%s violates strict JSON: %s" % (label, problems[0][1]))
    return document


# --------------------------------------------------------------------------
# JSON Schema draft-07 subset evaluator (the schema file stays authoritative)
# --------------------------------------------------------------------------

KEYWORDS = frozenset((
    "type", "const", "enum", "pattern", "required", "additionalProperties", "properties",
    "items", "oneOf", "anyOf", "allOf", "minimum", "maximum", "exclusiveMinimum",
    "exclusiveMaximum", "minLength", "maxLength", "minItems", "maxItems", "uniqueItems",
    "minProperties", "maxProperties", "$ref"))
ANNOTATIONS = frozenset((
    "$schema", "$id", "$comment", "title", "description", "definitions", "default", "examples"))


def type_name(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return type(value).__name__


def type_ok(name, value):
    if name == "null":
        return value is None
    if name == "boolean":
        return isinstance(value, bool)
    if name == "string":
        return isinstance(value, str)
    if name == "array":
        return isinstance(value, list)
    if name == "object":
        return isinstance(value, dict)
    if name == "integer":
        return (isinstance(value, int) and not isinstance(value, bool)) or (
            isinstance(value, float) and value.is_integer())
    if name == "number":
        return is_number(value)
    raise Unusable("schema uses unsupported type %r" % (name,))


def json_equal(left, right):
    if isinstance(left, bool) or isinstance(right, bool):
        return isinstance(left, bool) and isinstance(right, bool) and left == right
    if is_number(left) and is_number(right):
        return left == right
    if isinstance(left, str) and isinstance(right, str):
        return left == right
    if left is None or right is None:
        return left is None and right is None
    if isinstance(left, list) and isinstance(right, list):
        return len(left) == len(right) and all(json_equal(a, b) for a, b in zip(left, right))
    if isinstance(left, dict) and isinstance(right, dict):
        return set(left) == set(right) and all(json_equal(left[key], right[key]) for key in left)
    return False


def _ends_with_unescaped_dollar(pattern):
    if not pattern.endswith("$"):
        return False
    backslashes = 0
    index = len(pattern) - 2
    while index >= 0 and pattern[index] == "\\":
        backslashes += 1
        index -= 1
    return backslashes % 2 == 0


class SchemaEvaluator(object):
    """Evaluate a draft-07 subset. Unsupported keywords stop the run instead of passing."""

    def __init__(self, root):
        if not isinstance(root, dict):
            raise Unusable("schema root must be an object")
        self.root = root
        self._regex = {}

    def validate(self, instance, schema=None):
        """Return a list of (path, message) for every violation."""
        return self._check(self.root if schema is None else schema, instance, [], None)

    def _deref(self, schema):
        seen = 0
        while isinstance(schema, dict) and "$ref" in schema:
            schema = self._resolve(schema["$ref"])
            seen += 1
            if seen > 32:
                raise Unusable("schema $ref chain is too deep")
        return schema

    def _resolve(self, ref):
        if not isinstance(ref, str) or not ref.startswith("#/"):
            raise Unusable("schema uses an unsupported $ref %s" % brief(ref))
        node = self.root
        for token in ref[2:].split("/"):
            token = token.replace("~1", "/").replace("~0", "~")
            if not isinstance(node, dict) or token not in node:
                raise Unusable("schema $ref %s does not resolve" % ref)
            node = node[token]
        return node

    def _pattern(self, pattern):
        compiled = self._regex.get(pattern)
        if compiled is None:
            if not isinstance(pattern, str) or not pattern.startswith("^") \
                    or not _ends_with_unescaped_dollar(pattern):
                raise Unusable("schema pattern must be anchored with ^ and $: %s" % brief(pattern))
            try:
                compiled = re.compile(pattern)
            except re.error as exc:
                raise Unusable("schema pattern does not compile (%s): %s" % (exc, brief(pattern)))
            self._regex[pattern] = compiled
        return compiled

    def _check(self, schema, value, path, ref_name):
        if not isinstance(schema, dict):
            raise Unusable("schema node must be an object")
        if "$ref" in schema:
            target = self._resolve(schema["$ref"])
            return self._check(target, value, path, str(schema["$ref"]).rsplit("/", 1)[-1])
        for key in schema:
            if key not in KEYWORDS and key not in ANNOTATIONS:
                raise Unusable("schema uses unsupported keyword %s" % brief(key))
        errors = []
        declared = schema.get("type")
        if declared is not None:
            names = [declared] if isinstance(declared, str) else list(declared)
            if not any(type_ok(name, value) for name in names):
                return [(path, "expected %s, got %s" % (" or ".join(names), type_name(value)))]
        if "const" in schema and not json_equal(value, schema["const"]):
            errors.append((path, "must equal %s" % brief(schema["const"])))
        if "enum" in schema and not any(json_equal(value, item) for item in schema["enum"]):
            errors.append((path, "must be one of %s" % brief(schema["enum"], 140)))
        if isinstance(value, str):
            self._check_string(schema, value, path, ref_name, errors)
        if is_number(value):
            self._check_number(schema, value, path, errors)
        if isinstance(value, list):
            self._check_array(schema, value, path, errors)
        if isinstance(value, dict):
            self._check_object(schema, value, path, errors)
        self._check_combinators(schema, value, path, errors)
        return errors

    def _check_string(self, schema, value, path, ref_name, errors):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append((path, "is shorter than %d characters" % schema["minLength"]))
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errors.append((path, "is longer than %d characters (%d)" % (schema["maxLength"], len(value))))
        if "pattern" in schema and not self._pattern(schema["pattern"]).fullmatch(value):
            label = ref_name if ref_name else "required"
            errors.append((path, "does not match the %s pattern %s" % (label, brief(schema["pattern"], 90))))

    def _check_number(self, schema, value, path, errors):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append((path, "is below the minimum %s" % schema["minimum"]))
        if "maximum" in schema and value > schema["maximum"]:
            errors.append((path, "is above the maximum %s" % schema["maximum"]))
        if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
            errors.append((path, "must be greater than %s" % schema["exclusiveMinimum"]))
        if "exclusiveMaximum" in schema and value >= schema["exclusiveMaximum"]:
            errors.append((path, "must be less than %s" % schema["exclusiveMaximum"]))

    def _check_array(self, schema, value, path, errors):
        if "minItems" in schema and len(value) < schema["minItems"]:
            errors.append((path, "needs at least %d items" % schema["minItems"]))
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errors.append((path, "allows at most %d items" % schema["maxItems"]))
        if schema.get("uniqueItems") is True:
            for index, item in enumerate(value):
                if any(json_equal(item, earlier) for earlier in value[:index]):
                    errors.append((path + [index], "duplicates an earlier item"))
        if "items" in schema:
            items = schema["items"]
            if not isinstance(items, dict):
                raise Unusable("schema uses unsupported tuple-form items")
            for index, item in enumerate(value):
                errors.extend(self._check(items, item, path + [index], None))

    def _check_object(self, schema, value, path, errors):
        for key in schema.get("required", ()):
            if key not in value:
                errors.append((path + [key], "required property is missing"))
        if "minProperties" in schema and len(value) < schema["minProperties"]:
            errors.append((path, "needs at least %d properties" % schema["minProperties"]))
        if "maxProperties" in schema and len(value) > schema["maxProperties"]:
            errors.append((path, "allows at most %d properties" % schema["maxProperties"]))
        properties = schema.get("properties", {})
        for key, sub in properties.items():
            if key in value:
                errors.extend(self._check(sub, value[key], path + [key], None))
        extra = schema.get("additionalProperties", True)
        for key in value:
            if key in properties:
                continue
            if extra is False:
                errors.append((path + [key], "unknown property"))
            elif isinstance(extra, dict):
                errors.extend(self._check(extra, value[key], path + [key], None))

    def _check_combinators(self, schema, value, path, errors):
        if "allOf" in schema:
            for sub in schema["allOf"]:
                errors.extend(self._check(sub, value, path, None))
        if "anyOf" in schema:
            results = [self._check(sub, value, path, None) for sub in schema["anyOf"]]
            if not any(not result for result in results):
                errors.extend(self._closest(schema["anyOf"], results, value, path))
        if "oneOf" in schema:
            branches = schema["oneOf"]
            results = [self._check(sub, value, path, None) for sub in branches]
            matches = [index for index, result in enumerate(results) if not result]
            if not matches:
                errors.extend(self._closest(branches, results, value, path))
            elif len(matches) > 1:
                errors.append((path, "matches %d alternatives; exactly one is allowed" % len(matches)))

    def _closest(self, branches, results, value, path):
        """Errors of the most relevant alternative when none matched."""
        compatible = []
        wanted = []
        for sub, result in zip(branches, results):
            resolved = self._deref(sub)
            declared = resolved.get("type") if isinstance(resolved, dict) else None
            names = [declared] if isinstance(declared, str) else list(declared or [])
            wanted.extend(names)
            if not names or any(type_ok(name, value) for name in names):
                compatible.append(result)
        if not compatible:
            unique = []
            for name in wanted:
                if name not in unique:
                    unique.append(name)
            return [(path, "expected %s, got %s" % (" or ".join(unique), type_name(value)))]
        return min(compatible, key=len)


# --------------------------------------------------------------------------
# Context: manifest schema, grammar helpers, descriptors
# --------------------------------------------------------------------------

class Context(object):
    def __init__(self, descriptors_dir=None):
        schema, problems = load_json_file(MANIFEST_SCHEMA_PATH, "manifest.schema.json")
        if problems or not isinstance(schema, dict):
            raise Unusable("manifest.schema.json is not usable")
        self.schema = schema
        self.evaluator = SchemaEvaluator(schema)
        self.definitions = as_dict(schema.get("definitions"))
        self.descriptors_dir = descriptors_dir or DEFAULT_DESCRIPTORS
        self._descriptors = None

    def definition_errors(self, name, value):
        if name not in self.definitions:
            raise Unusable("manifest.schema.json lacks definitions/%s" % name)
        return self.evaluator.validate(value, {"$ref": "#/definitions/%s" % name})

    def definition_ok(self, name, value):
        return not self.definition_errors(name, value)

    @property
    def descriptors(self):
        if self._descriptors is None:
            self._descriptors = load_descriptors(self.descriptors_dir)
        return self._descriptors


def load_descriptors(directory):
    if not os.path.isdir(directory):
        raise Unusable("descriptors directory not found: %s" % directory)
    schema = load_json_strict(DESCRIPTOR_SCHEMA_PATH, "descriptor.schema.json")
    evaluator = SchemaEvaluator(schema)
    found = {}
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".json"):
            continue
        label = "descriptor %s" % name
        document = load_json_strict(os.path.join(directory, name), label)
        errors = evaluator.validate(document)
        if errors:
            raise Unusable("%s violates descriptor.schema.json: %s %s"
                           % (label, pointer(errors[0][0]), errors[0][1]))
        stem = name[:-len(".json")]
        if document.get("id") != stem:
            raise Unusable("%s: id %s does not equal the file name" % (label, brief(document.get("id"))))
        found[stem] = document
    if not found:
        raise Unusable("no descriptors found in %s" % directory)
    return found


# --------------------------------------------------------------------------
# Failure report
# --------------------------------------------------------------------------

class Report(object):
    def __init__(self):
        self.failures = []
        self.dropped = 0
        self._seen = set()

    def add(self, code, path, message):
        text = one_line(message)
        key = (code, pointer(path), text)
        if key in self._seen:
            return
        if len(self.failures) >= MAX_FAILURES:
            self.dropped += 1
            return
        self._seen.add(key)
        self.failures.append({"code": code, "path": pointer(path), "message": text})

    @property
    def codes(self):
        return sorted(set(item["code"] for item in self.failures))


# --------------------------------------------------------------------------
# Scope derivation shared by the validator and `scope end`
# --------------------------------------------------------------------------

def fingerprint_of(entries):
    """SHA-256 of the canonical JSON of entries (sorted by path, sorted keys, ASCII)."""
    canonical = json.dumps(sorted(entries, key=lambda entry: entry["path"]), sort_keys=True,
                           separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(canonical.encode("ascii")).hexdigest()


def under_where(path, where):
    for prefix in where:
        if path == prefix or path.startswith(prefix + "/"):
            return True
    return False


def entry_map(snapshot):
    result = {}
    for entry in as_list(as_dict(snapshot).get("entries")):
        if isinstance(entry, dict) and isinstance(entry.get("path"), str):
            result[entry["path"]] = entry
    return result


def committed_map(committed):
    """{path: change} from a committed_changes list; the first entry for a path wins."""
    result = {}
    for item in as_list(committed):
        if isinstance(item, dict) and isinstance(item.get("path"), str) \
                and isinstance(item.get("change"), str):
            result.setdefault(item["path"], item["change"])
    return result


def derive_changed(start, end, where, reported, committed):
    """WT-SCOPE-CHANGED: {path: {change, in_where, reported, attribution}} for the observed set O.

    With a start snapshot O holds every path whose entry exists in only one
    snapshot or differs in state or sha256, plus every committed_changes path.
    Without one, O is exactly the reported paths and every change is unknown.
    """
    reported_set = set(reported)
    where = [item for item in where if isinstance(item, str)]
    if start is None:
        return {
            path: {"change": "unknown", "in_where": under_where(path, where), "reported": True,
                   "attribution": "before unavailable"}
            for path in sorted(reported_set)}
    before, after = entry_map(start), entry_map(end)
    from_commits = committed_map(committed)
    observed = set(from_commits)
    for path in set(before) | set(after):
        old, new = before.get(path), after.get(path)
        if old is None or new is None or old.get("state") != new.get("state") \
                or old.get("sha256") != new.get("sha256"):
            observed.add(path)
    result = {}
    for path in sorted(observed):
        new = after.get(path)
        if new is not None:
            state = new.get("state")
            if state == "untracked":
                change = "modified" if path in before else "added"
            else:
                change = state
        elif path in from_commits:
            change = from_commits[path]
        else:
            change = "unknown"
        result[path] = {
            "change": change, "in_where": under_where(path, where), "reported": path in reported_set,
            "attribution": ("reported-and-observed" if path in reported_set
                            else "observed-only: attribution uncertain")}
    return result


def derive_discrepancy_requirements(start, end, changed, reported, shared_tree):
    """WT-SCOPE-DISCREPANCY: the exact set of (kind, path) pairs, one entry each."""
    required = set()
    if start is None:
        required.add(("before-unavailable", None))
    for path in changed:
        if not changed[path]["in_where"]:
            required.add(("outside-where", path))
        if not changed[path]["reported"]:
            required.add(("observed-not-reported", path))
    for path in set(reported) - set(changed):
        required.add(("reported-not-observed", path))
    for snapshot in (start, end):
        if snapshot is None:
            continue
        for path, entry in entry_map(snapshot).items():
            if "omitted" in entry:
                required.add(("fingerprint-omitted", path))
    if shared_tree:
        required.add(("shared-tree: attribution uncertain", None))
    return required


DISCREPANCY_ORDER = ("before-unavailable", "outside-where", "observed-not-reported",
                     "reported-not-observed", "fingerprint-omitted",
                     "shared-tree: attribution uncertain")


def discrepancy_sort_key(item):
    kind, path = item
    return (DISCREPANCY_ORDER.index(kind) if kind in DISCREPANCY_ORDER else len(DISCREPANCY_ORDER),
            path or "")


# WT-TARGET-IDENTITY: allowed target.identity key sets per platform.
IDENTITY_KEY_SETS = {
    "web": (frozenset(("origin",)),),
    "electron": (frozenset(("origin",)), frozenset(("app_name", "window_title", "bundle_id"))),
    "macos": (frozenset(("app_name", "window_title", "bundle_id")),),
    "ios-simulator": (frozenset(("udid", "bundle_id")), frozenset(("udid", "bundle_id", "device"))),
    "android-emulator": (frozenset(("device", "bundle_id")),),
}
# WT-RECEIPT-BINDING: the target keys an installed binding must repeat.
INSTALLED_BINDING_KEYS = {
    "macos": ("bundle_id",),
    "ios-simulator": ("udid", "bundle_id"),
    "android-emulator": ("device", "bundle_id"),
}
COMMITTED_STATUS = {"A": "added", "D": "deleted", "M": "modified", "T": "type-changed"}


def receipt_binding_problems(receipt, target):
    """WT-RECEIPT-BINDING: reasons the receipt's binding does not fit its kind and the target."""
    problems = []
    kind = receipt.get("kind")
    binding = as_dict(receipt.get("binding"))
    bound = binding.get("kind")
    platform = target.get("platform")
    identity = as_dict(target.get("identity"))
    if kind == "web-build-info" and bound != "origin":
        problems.append("web-build-info requires an origin binding")
    if kind == "native-build" and bound != "installed":
        problems.append("native-build requires an installed binding")
    if bound == "origin":
        if platform not in ("web", "electron"):
            problems.append("an origin binding requires platform web or electron")
        elif binding.get("origin") != identity.get("origin"):
            problems.append("binding.origin must equal target.identity.origin")
    elif bound == "installed":
        keys = INSTALLED_BINDING_KEYS.get(platform)
        if keys is None:
            problems.append("an installed binding requires platform macos, ios-simulator or android-emulator")
        else:
            expected = dict((key, identity[key]) for key in keys if key in identity)
            if len(expected) != len(keys) or not json_equal(binding.get("identity"), expected):
                problems.append("binding.identity must equal the target's %s" % " and ".join(keys))
    return problems


def derive_freshness(receipt, target, head_end, end_snapshot):
    """WT-BUILD-FRESHNESS: the derived value, or None when the receipt is not derivable."""
    if receipt is None:
        return "unverified"
    if not isinstance(receipt, dict) or not isinstance(receipt.get("source"), dict) \
            or not isinstance(receipt.get("binding"), dict) or not isinstance(end_snapshot, dict):
        return None
    source, binding = receipt["source"], receipt["binding"]
    installed = binding.get("kind") == "installed"
    if receipt_binding_problems(receipt, target):
        return "contradicted"
    if installed and binding.get("installed_sha256") is not None \
            and binding.get("installed_sha256") != binding.get("product_sha256"):
        return "contradicted"
    if source.get("revision") != head_end:
        return "contradicted"
    if source.get("fingerprint") is not None and source.get("fingerprint") != end_snapshot.get("fingerprint"):
        return "contradicted"
    if installed and binding.get("installed_sha256") is None:
        return "unverified"
    if source.get("fingerprint") is None and as_list(end_snapshot.get("entries")):
        return "verified-commit-only"
    return "verified"


def derive_unbound_paths(freshness, end_snapshot):
    """WT-BUILD-UNBOUND: sorted unique working-tree paths the receipt does not bind."""
    entries = entry_map(end_snapshot)
    if freshness == "verified-commit-only":
        return sorted(entries)
    if freshness == "verified":
        return sorted(path for path, entry in entries.items() if "omitted" in entry)
    return []


# --------------------------------------------------------------------------
# Git and run-directory containment
# --------------------------------------------------------------------------

def clean_git_env():
    env = dict(os.environ)
    for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_PREFIX",
                 "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE"):
        env.pop(name, None)
    env["GIT_OPTIONAL_LOCKS"] = "0"
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["LC_ALL"] = "C"
    return env


def run_git(cwd, args, timeout=300):
    """Run a read-only git command; return (returncode, stdout bytes, stderr bytes)."""
    try:
        proc = subprocess.run(["git", "-C", cwd] + list(args), stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              env=clean_git_env(), timeout=timeout)
    except FileNotFoundError:
        raise Unusable("git is required but was not found on PATH")
    except subprocess.TimeoutExpired:
        raise Unusable("git %s timed out" % args[0])
    return proc.returncode, proc.stdout, proc.stderr


def git_toplevel(directory):
    rc, out, _ = run_git(directory, ["rev-parse", "--show-toplevel"])
    if rc != 0:
        raise Unusable("not inside a git work tree: %s" % directory)
    top = out.decode("utf-8", "surrogateescape").rstrip("\n")
    return os.path.realpath(top)


def commit_available(root, sha):
    rc, _, _ = run_git(root, ["cat-file", "-e", sha + "^{commit}"])
    return rc == 0


def is_ancestor(root, older, newer):
    """True or False, or None when git cannot tell."""
    rc, _, _ = run_git(root, ["merge-base", "--is-ancestor", older, newer])
    if rc == 0:
        return True
    if rc == 1:
        return False
    return None


def committed_diff(root, start_head, end_head):
    """WT-HEAD-DRIFT: the endpoint diff of two commits as a path-sorted [{path, change}] list.

    Renames are not detected (--no-renames), so every machine derives the same list.
    """
    rc, out, err = run_git(root, ["diff", "--name-status", "-z", "--no-renames",
                                  start_head, end_head, "--"])
    if rc != 0:
        first = err.decode("utf-8", "replace").strip().splitlines()[:1]
        raise Unusable("git diff failed (exit %d)%s" % (rc, ": " + first[0] if first else ""))
    tokens = out.split(b"\0")
    if tokens and tokens[-1] == b"":
        tokens.pop()
    if len(tokens) % 2:
        raise Unusable("unexpected git diff --name-status output")
    changes = []
    for index in range(0, len(tokens), 2):
        letter = tokens[index].decode("ascii", "replace")[:1]
        change = COMMITTED_STATUS.get(letter)
        if change is None:
            raise Unusable("unsupported git diff status %s" % brief(letter))
        try:
            path = tokens[index + 1].decode("utf-8")
        except UnicodeDecodeError:
            raise Unusable("a committed path is not valid UTF-8 and cannot be recorded")
        changes.append({"path": path, "change": change})
    changes.sort(key=lambda item: item["path"])
    return changes


def split_components(abs_path):
    return [part for part in abs_path.split(os.sep) if part]


def location_problems(abs_dir, root_real, must_exist):
    """Problems with a run directory's place in the repository. Never writes."""
    parts = split_components(abs_dir)
    base = None
    current = os.sep
    for index, part in enumerate(parts):
        current = os.path.join(current, part)
        if os.path.realpath(current) == root_real:
            base = index
            break
    if base is None:
        return ["run directory is not inside the repository root %s" % root_real]
    below = parts[base + 1:]
    if not below:
        return ["run directory must be below the repository root, not the root itself"]
    if below[0] == ".git":
        return ["run directory must not be inside .git"]
    problems = []
    current = os.path.join(os.sep, *parts[:base + 1])
    for part in below:
        current = os.path.join(current, part)
        try:
            info = os.lstat(current)
        except FileNotFoundError:
            if must_exist:
                problems.append("run directory does not exist: %s" % abs_dir)
            break
        except OSError as exc:
            problems.append("cannot inspect %s: %s" % (current, exc.strerror or exc))
            break
        if stat.S_ISLNK(info.st_mode):
            problems.append("run directory path has a symlink component: %s" % current)
            break
        if not stat.S_ISDIR(info.st_mode):
            problems.append("run directory path component is not a directory: %s" % current)
            break
        if info.st_uid != os.geteuid():
            problems.append("run directory path component is not owned by you: %s" % current)
            break
    return problems


def ignore_problems(abs_dir, root_real):
    """The run directory (or its nearest existing ancestor) must be git-ignored."""
    parts = split_components(abs_dir)
    base = None
    current = os.sep
    for index, part in enumerate(parts):
        current = os.path.join(current, part)
        if os.path.realpath(current) == root_real:
            base = index
            break
    if base is None:
        return []
    below = parts[base + 1:]
    candidates = [below]
    if not os.path.lexists(abs_dir):
        for size in range(len(below) - 1, 0, -1):
            ancestor = os.path.join(os.sep, *(parts[:base + 1] + below[:size]))
            if os.path.isdir(ancestor):
                candidates.append(below[:size])
                break
    detail = "git check-ignore did not report the run directory as ignored"
    for candidate in candidates:
        rc, _, err = run_git(root_real, ["check-ignore", "-q", "--", "/".join(candidate)])
        if rc == 0:
            return []
        if rc != 1:
            first = err.decode("utf-8", "replace").strip().splitlines()[:1]
            return ["git check-ignore failed (exit %d)%s" % (rc, ": " + first[0] if first else "")]
    return [detail + " (the helper never edits ignore rules)"]


def check_run_dir(abs_dir, root_real, must_exist=True):
    problems = location_problems(abs_dir, root_real, must_exist)
    if not problems:
        problems = ignore_problems(abs_dir, root_real)
    return problems


def contained_run_dir(run_dir):
    """Write containment for an existing run directory; returns (absolute path, repository root).

    Every command that writes into a run directory calls this before it takes the
    lock (the lock itself writes) and again once it holds the lock. The answer never
    depends on where the manifest came from: --manifest selects the input file only.
    """
    abs_dir = os.path.abspath(run_dir)
    root = git_toplevel(abs_dir)
    problems = check_run_dir(abs_dir, root, must_exist=True)
    if problems:
        raise Unusable("; ".join(problems))
    return abs_dir, root


# --------------------------------------------------------------------------
# Asset inspection
# --------------------------------------------------------------------------

class AssetProblem(Exception):
    pass


def inspect_asset(run_dir, relative):
    """Hash an asset under run_dir/assets without following symlinks.

    Returns (sha256, size, leading bytes). Raises AssetProblem when the file is
    not an owned regular file reached without a symlink component.
    """
    name = relative.split("/", 1)[1]
    flags_dir = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        dir_fd = os.open(os.path.join(run_dir, "assets"), flags_dir)
    except OSError as exc:
        raise AssetProblem("the assets directory is missing or a symlink (%s)" % (exc.strerror or exc))
    try:
        info = os.fstat(dir_fd)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
            raise AssetProblem("the assets directory is not an owned directory")
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
        try:
            fd = os.open(name, flags, dir_fd=dir_fd)
        except OSError as exc:
            raise AssetProblem("file is missing, unreadable or a symlink (%s)" % (exc.strerror or exc))
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
                raise AssetProblem("file is not an owned regular file")
            digest = hashlib.sha256()
            size = 0
            head = b""
            while True:
                chunk = os.read(fd, 1 << 20)
                if not chunk:
                    break
                if len(head) < 16:
                    head = (head + chunk)[:16]
                digest.update(chunk)
                size += len(chunk)
            return digest.hexdigest(), size, head
        finally:
            os.close(fd)
    finally:
        os.close(dir_fd)


def signature_matches(media_type, head):
    if media_type == "image/png":
        return head.startswith(b"\x89PNG\r\n\x1a\n")
    if media_type == "image/jpeg":
        return head[:3] == b"\xff\xd8\xff"
    if media_type == "image/webp":
        return head[:4] == b"RIFF" and head[8:12] == b"WEBP"
    if media_type in ("video/mp4", "video/quicktime"):
        return head[4:8] == b"ftyp"
    if media_type == "video/webm":
        return head[:4] == b"\x1a\x45\xdf\xa3"
    return True


# --------------------------------------------------------------------------
# WT-* cross-field rules
# --------------------------------------------------------------------------

class ManifestChecker(object):
    """Runs the structural pass and every WT-* rule on a parsed manifest."""

    def __init__(self, manifest, context, run_dir, run_dir_mode, report):
        self.m = manifest
        self.ctx = context
        self.run_dir = run_dir
        self.run_dir_mode = run_dir_mode
        self.report = report
        self.shape_failed = False

    def fail(self, code, path, message):
        self.report.add(code, path, message)

    # -- structure ---------------------------------------------------------

    def check_shape(self):
        for path, message in self.ctx.evaluator.validate(self.m):
            self.shape_failed = True
            self.fail("WT-SCHEMA-SHAPE", path, message)
        for path, message in find_lone_surrogates(self.m):
            self.shape_failed = True
            self.fail("WT-SCHEMA-SHAPE", path, message)

    def run_rules(self):
        rules = (
            self.rule_run_id, self.rule_run_status, self.rule_scope_start,
            self.rule_scope_snapshots, self.rule_head, self.rule_head_drift,
            self.rule_scope_changed, self.rule_scope_discrepancy, self.rule_adapter,
            self.rule_target_identity, self.rule_target_capabilities, self.rule_receipt_binding,
            self.rule_build, self.rule_chapters, self.rule_assets, self.rule_coverage,
            self.rule_privacy, self.rule_containment)
        for rule in rules:
            try:
                rule()
            except (KeyError, TypeError, AttributeError, IndexError, ValueError) as exc:
                if not self.shape_failed:
                    raise Unusable("internal error in %s on a shape-valid manifest: %r"
                                   % (rule.__name__, exc))

    # -- run ---------------------------------------------------------------

    def rule_run_id(self):
        run_id = dget(self.m, "run", "id")
        if not isinstance(run_id, str) or not self.ctx.definition_ok("run_id", run_id):
            self.fail("WT-RUN-ID", ["run", "id"], "run.id must match the run id grammar")
            return
        if self.run_dir_mode:
            name = os.path.basename(os.path.abspath(self.run_dir))
            if run_id != name:
                self.fail("WT-RUN-ID", ["run", "id"],
                          "run.id %s does not equal the run directory name %s"
                          % (brief(run_id), brief(name)))

    def rule_run_status(self):
        status = dget(self.m, "run", "status")
        if status in ("complete", "partial") and dget(self.m, "run", "finalized_at") is None:
            self.fail("WT-RUN-STATUS", ["run", "finalized_at"],
                      "status %s requires finalized_at" % status)
        if status == "complete":
            for index, chapter in enumerate(as_list(self.m.get("chapters"))):
                if dget(chapter, "status") in ("failed", "skipped"):
                    self.fail("WT-RUN-STATUS", ["chapters", index, "status"],
                              "a complete run cannot contain a %s chapter" % chapter["status"])
            for index, entry in enumerate(as_list(dget(self.m, "coverage", "paths"))):
                if dget(entry, "status") in ("failed", "skipped"):
                    self.fail("WT-RUN-STATUS", ["coverage", "paths", index, "status"],
                              "a complete run cannot contain a %s coverage entry" % entry["status"])

    # -- scope -------------------------------------------------------------

    def rule_scope_start(self):
        scope = as_dict(self.m.get("scope"))
        start = scope.get("start")
        reason = scope.get("start_unavailable_reason")
        if (start is None) != (reason is not None):
            self.fail("WT-SCOPE-START", ["scope", "start_unavailable_reason"],
                      "scope.start is null exactly when start_unavailable_reason is set")
        if start is None:
            for index, changed in enumerate(as_list(scope.get("changed_paths"))):
                if dget(changed, "attribution") != "before unavailable":
                    self.fail("WT-SCOPE-START", ["scope", "changed_paths", index, "attribution"],
                              "without a start snapshot every changed path is 'before unavailable'")
                if dget(changed, "change") != "unknown":
                    self.fail("WT-SCOPE-START", ["scope", "changed_paths", index, "change"],
                              "without a start snapshot every change is unknown")
            marks = [item for item in as_list(scope.get("discrepancies"))
                     if dget(item, "kind") == "before-unavailable" and dget(item, "path") is None]
            if len(marks) != 1:
                self.fail("WT-SCOPE-START", ["scope", "discrepancies"],
                          "exactly one before-unavailable discrepancy with path null is required "
                          "without a start snapshot (found %d)" % len(marks))

    def rule_scope_snapshots(self):
        scope = as_dict(self.m.get("scope"))
        for name in ("start", "end"):
            snapshot = scope.get(name)
            if not isinstance(snapshot, dict):
                continue
            entries = snapshot.get("entries")
            if not isinstance(entries, list):
                continue
            usable = True
            seen = set()
            for index, entry in enumerate(entries):
                where = ["scope", name, "entries", index]
                if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
                    usable = False
                    continue
                if entry["path"] in seen:
                    usable = False
                    self.fail("WT-SCOPE-FINGERPRINT", where + ["path"],
                              "entry paths must be unique for a canonical fingerprint")
                seen.add(entry["path"])
                omitted = "omitted" in entry
                both_null = entry.get("sha256") is None and entry.get("bytes") is None
                any_null = entry.get("sha256") is None or entry.get("bytes") is None
                if omitted and not both_null:
                    self.fail("WT-SCOPE-ENTRY", where, "an omitted entry must have sha256 and bytes null")
                if not omitted and any_null:
                    self.fail("WT-SCOPE-ENTRY", where, "sha256 and bytes are null only when omitted is present")
            if usable:
                expected = fingerprint_of(entries)
                if snapshot.get("fingerprint") != expected:
                    self.fail("WT-SCOPE-FINGERPRINT", ["scope", name, "fingerprint"],
                              "fingerprint does not equal the digest of the entries (expected %s)" % expected)

    def _derived_inputs(self):
        scope = as_dict(self.m.get("scope"))
        task = as_dict(self.m.get("task"))
        start, end = scope.get("start"), scope.get("end")
        if not isinstance(end, dict) or (start is not None and not isinstance(start, dict)):
            return None
        where = [item for item in as_list(task.get("where")) if isinstance(item, str)]
        reported = [item for item in as_list(task.get("reported_paths")) if isinstance(item, str)]
        return start, end, where, reported, scope.get("committed_changes")

    def rule_scope_changed(self):
        inputs = self._derived_inputs()
        if inputs is None:
            return
        start, end, where, reported, committed = inputs
        derived = derive_changed(start, end, where, reported, committed)
        seen = {}
        for index, item in enumerate(as_list(dget(self.m, "scope", "changed_paths"))):
            if not isinstance(item, dict) or not isinstance(item.get("path"), str):
                continue
            path = item["path"]
            where_path = ["scope", "changed_paths", index]
            if path in seen:
                self.fail("WT-SCOPE-CHANGED", where_path + ["path"], "changed path listed twice")
                continue
            seen[path] = index
            expected = derived.get(path)
            if expected is None:
                self.fail("WT-SCOPE-CHANGED", where_path + ["path"],
                          "%s is not in the observed set derived from the snapshots, commits and report"
                          % brief(path))
                continue
            for field in ("change", "in_where", "reported", "attribution"):
                if item.get(field) != expected[field] or type(item.get(field)) is not type(expected[field]):
                    self.fail("WT-SCOPE-CHANGED", where_path + [field],
                              "%s must be %s for %s" % (field, brief(expected[field]), brief(path)))
        for path in sorted(derived):
            if path not in seen:
                self.fail("WT-SCOPE-CHANGED", ["scope", "changed_paths"],
                          "observed path %s is missing" % brief(path))

    def rule_scope_discrepancy(self):
        inputs = self._derived_inputs()
        if inputs is None:
            return
        start, end, where, reported, committed = inputs
        derived = derive_changed(start, end, where, reported, committed)
        shared = dget(self.m, "scope", "shared_tree") is True
        required = derive_discrepancy_requirements(start, end, derived, set(reported), shared)
        seen = set()
        for index, item in enumerate(as_list(dget(self.m, "scope", "discrepancies"))):
            if not isinstance(item, dict):
                continue
            kind, path = item.get("kind"), item.get("path")
            if not isinstance(kind, str) or not (path is None or isinstance(path, str)):
                continue
            key = (kind, path)
            label = "%s%s" % (kind, "" if path is None else " " + brief(path))
            where_path = ["scope", "discrepancies", index]
            if key not in required:
                self.fail("WT-SCOPE-DISCREPANCY", where_path,
                          "discrepancy %s is not required by the scope rules" % label)
            elif key in seen:
                self.fail("WT-SCOPE-DISCREPANCY", where_path, "discrepancy %s is listed twice" % label)
            seen.add(key)
        for key in sorted(required - seen, key=discrepancy_sort_key):
            kind, path = key
            self.fail("WT-SCOPE-DISCREPANCY", ["scope", "discrepancies"],
                      "required discrepancy %s%s is missing"
                      % (kind, "" if path is None else " " + brief(path)))

    def rule_head(self):
        end_head = dget(self.m, "scope", "end", "head")
        if dget(self.m, "repository", "head_end") != end_head:
            self.fail("WT-HEAD", ["repository", "head_end"], "head_end must equal scope.end.head")
        if dget(self.m, "repository", "head_start") != dget(self.m, "scope", "start", "head"):
            self.fail("WT-HEAD", ["repository", "head_start"],
                      "head_start must equal scope.start.head, or null without a start snapshot")
        entries = dget(self.m, "scope", "end", "entries")
        if isinstance(entries, list):
            dirty = dget(self.m, "repository", "dirty_at_end")
            if isinstance(dirty, bool) and dirty != bool(entries):
                self.fail("WT-HEAD", ["repository", "dirty_at_end"],
                          "dirty_at_end must be true exactly when scope.end.entries is non-empty")

    def rule_head_drift(self):
        scope = as_dict(self.m.get("scope"))
        start, end = scope.get("start"), scope.get("end")
        committed = scope.get("committed_changes")
        if not isinstance(committed, list):
            return
        seen = set()
        for index, item in enumerate(committed):
            if isinstance(item, dict) and isinstance(item.get("path"), str):
                if item["path"] in seen:
                    self.fail("WT-HEAD-DRIFT", ["scope", "committed_changes", index, "path"],
                              "committed path listed twice")
                seen.add(item["path"])
        start_head = dget(start, "head") if isinstance(start, dict) else None
        end_head = dget(end, "head") if isinstance(end, dict) else None
        same_heads = start is None or start_head == end_head
        if same_heads and committed:
            self.fail("WT-HEAD-DRIFT", ["scope", "committed_changes"],
                      "committed_changes must be empty when there is no start snapshot or the heads are equal")
        if not self.run_dir_mode:
            return  # fixture mode cannot verify the history and trusts the manifest
        self._prove_history(same_heads, start_head, end_head, committed)

    def _prove_history(self, same_heads, start_head, end_head, committed):
        """Run-directory mode: re-derive the history from the repository; no proof is skipped.

        The proofs run in order and the first one that fails is reported: the heads are
        available commits, start.head is an ancestor of end.head, and the endpoint diff
        equals committed_changes. Unavailable or unknown history is a failure, never a pass.
        Without a start snapshot, or with equal heads, only end.head has to be a commit.
        """
        heads = [("end", end_head)] if same_heads else [("start", start_head), ("end", end_head)]
        if not all(self.ctx.definition_ok("git_sha", head) for _, head in heads):
            return  # a malformed head is already a WT-SCHEMA-SHAPE failure
        try:
            root = git_toplevel(os.path.abspath(self.run_dir))
        except Unusable:
            return  # WT-OUTPUT-CONTAINMENT reports a run directory outside a repository
        unavailable = [(name, head) for name, head in heads if not commit_available(root, head)]
        for name, head in unavailable:
            self.fail("WT-HEAD-DRIFT", ["scope", name, "head"],
                      "%s.head %s is not an available commit in this repository, so the history cannot be verified"
                      % (name, brief(head)))
        if unavailable or same_heads:
            return  # equal heads: the list was checked above and the commit exists
        ancestor = is_ancestor(root, start_head, end_head)
        if ancestor is not True:
            self.fail("WT-HEAD-DRIFT", ["scope", "start", "head"],
                      "start.head is not an ancestor of end.head; the history was rewritten or switched"
                      if ancestor is False else
                      "git could not tell whether start.head is an ancestor of end.head, so the history cannot be verified")
            return
        expected = dict((item["path"], item["change"]) for item in committed_diff(root, start_head, end_head))
        actual = committed_map(committed)
        for path in sorted(set(expected) | set(actual)):
            if expected.get(path) != actual.get(path):
                self.fail("WT-HEAD-DRIFT", ["scope", "committed_changes"],
                          "%s: the re-derived endpoint diff has %s, the manifest has %s"
                          % (brief(path), brief(expected.get(path)), brief(actual.get(path))))

    # -- target and build --------------------------------------------------

    def rule_adapter(self):
        descriptors = self.ctx.descriptors
        target = as_dict(self.m.get("target"))
        adapter = target.get("adapter")
        if isinstance(adapter, str):
            descriptor = descriptors.get(adapter)
            if descriptor is None:
                self.fail("WT-ADAPTER-UNKNOWN", ["target", "adapter"],
                          "%s does not name a shipped descriptor" % brief(adapter))
            elif target.get("platform") != descriptor.get("platform"):
                self.fail("WT-ADAPTER-UNKNOWN", ["target", "platform"],
                          "platform %s does not equal the descriptor platform %s"
                          % (brief(target.get("platform")), brief(descriptor.get("platform"))))
        for index, asset in enumerate(as_list(self.m.get("assets"))):
            tool_adapter = dget(asset, "tool", "adapter")
            if isinstance(tool_adapter, str) and tool_adapter not in descriptors:
                self.fail("WT-ADAPTER-UNKNOWN", ["assets", index, "tool", "adapter"],
                          "%s does not name a shipped descriptor" % brief(tool_adapter))

    def rule_target_identity(self):
        target = as_dict(self.m.get("target"))
        platform, identity = target.get("platform"), target.get("identity")
        allowed = IDENTITY_KEY_SETS.get(platform) if isinstance(platform, str) else None
        if allowed is None or not isinstance(identity, dict):
            return
        if frozenset(identity) not in allowed:
            options = " or ".join("{%s}" % ", ".join(sorted(keys)) for keys in allowed)
            self.fail("WT-TARGET-IDENTITY", ["target", "identity"],
                      "platform %s needs exactly the identity keys %s" % (platform, options))

    def rule_target_capabilities(self):
        target = as_dict(self.m.get("target"))
        adapter = target.get("adapter")
        descriptor = self.ctx.descriptors.get(adapter) if isinstance(adapter, str) else None
        if descriptor is None:
            return
        offered = as_dict(descriptor.get("capabilities"))
        claimed = as_dict(target.get("capabilities"))
        if claimed.get("observe") is True and offered.get("screenshot") is not True:
            self.fail("WT-TARGET-CAPABILITIES", ["target", "capabilities", "observe"],
                      "the descriptor cannot take screenshots")
        if claimed.get("record") is True and offered.get("record") is not True:
            self.fail("WT-TARGET-CAPABILITIES", ["target", "capabilities", "record"],
                      "the descriptor cannot record")
        drive = claimed.get("drive")
        if isinstance(drive, str) and drive != "none" and drive != offered.get("drive"):
            self.fail("WT-TARGET-CAPABILITIES", ["target", "capabilities", "drive"],
                      "drive %s exceeds the descriptor value %s" % (brief(drive), brief(offered.get("drive"))))

    def rule_receipt_binding(self):
        receipt = dget(self.m, "build", "receipt")
        if not isinstance(receipt, dict) or not isinstance(receipt.get("binding"), dict):
            return
        for problem in receipt_binding_problems(receipt, as_dict(self.m.get("target"))):
            self.fail("WT-RECEIPT-BINDING", ["build", "receipt", "binding"], problem)

    def rule_build(self):
        build = as_dict(self.m.get("build"))
        derived = derive_freshness(build.get("receipt"), as_dict(self.m.get("target")),
                                   dget(self.m, "repository", "head_end"), dget(self.m, "scope", "end"))
        if derived is None:
            return
        if build.get("freshness") != derived:
            self.fail("WT-BUILD-FRESHNESS", ["build", "freshness"],
                      "declared %s but the receipt derives %s" % (brief(build.get("freshness")), derived))
        if derived == "contradicted":
            self.fail("WT-BUILD-CONTRADICTED", ["build", "receipt"],
                      "the receipt contradicts the end revision, fingerprint, binding or installed product; "
                      "rebuild, recapture, validate again")
        end = dget(self.m, "scope", "end")
        if isinstance(end, dict) and isinstance(build.get("unbound_paths"), list):
            expected = derive_unbound_paths(derived, end)
            if build["unbound_paths"] != expected:
                self.fail("WT-BUILD-UNBOUND", ["build", "unbound_paths"],
                          "unbound_paths must equal the sorted unique list %s" % brief(expected, 160))

    # -- chapters ----------------------------------------------------------

    def _asset_ids(self):
        return set(asset["id"] for asset in as_list(self.m.get("assets"))
                   if isinstance(asset, dict) and isinstance(asset.get("id"), str))

    def rule_chapters(self):
        chapters = as_list(self.m.get("chapters"))
        asset_ids = self._asset_ids()
        covered = set(entry["path"] for entry in as_list(dget(self.m, "coverage", "paths"))
                      if isinstance(entry, dict) and isinstance(entry.get("path"), str))
        seen = set()
        for index, chapter in enumerate(chapters):
            if not isinstance(chapter, dict):
                continue
            where = ["chapters", index]
            chapter_id = chapter.get("id")
            if isinstance(chapter_id, str):
                if chapter_id in seen:
                    self.fail("WT-CHAPTER-ID", where + ["id"], "chapter id %s is not unique" % brief(chapter_id))
                seen.add(chapter_id)
            before, after = as_dict(chapter.get("before")), as_dict(chapter.get("after"))
            for slot, node in (("before", before), ("after", after)):
                ref = node.get("asset")
                if isinstance(ref, str) and ref not in asset_ids:
                    self.fail("WT-CHAPTER-ASSET", where + [slot, "asset"],
                              "%s does not reference an existing asset" % brief(ref))
            if (before.get("asset") is None) != (before.get("unavailable_reason") is not None):
                self.fail("WT-CHAPTER-BEFORE", where + ["before"],
                          "before.asset is null exactly when before.unavailable_reason is set")
            status = chapter.get("status")
            if status == "demonstrated":
                if after.get("asset") is None:
                    self.fail("WT-CHAPTER-EVIDENCE", where + ["after", "asset"],
                              "a demonstrated chapter needs an after asset")
                if chapter.get("observation") is None:
                    self.fail("WT-CHAPTER-EVIDENCE", where + ["observation"],
                              "a demonstrated chapter needs an observation")
                if chapter.get("captured_at") is None:
                    self.fail("WT-CHAPTER-EVIDENCE", where + ["captured_at"],
                              "a demonstrated chapter needs captured_at")
                if chapter.get("reason") is not None:
                    self.fail("WT-CHAPTER-EVIDENCE", where + ["reason"],
                              "a demonstrated chapter must have reason null")
            elif status in ("failed", "skipped") and chapter.get("reason") is None:
                self.fail("WT-CHAPTER-EVIDENCE", where + ["reason"],
                          "a %s chapter needs a reason" % status)
            for position, source in enumerate(as_list(chapter.get("source_paths"))):
                if isinstance(source, str) and source not in covered:
                    self.fail("WT-CHAPTER-SOURCE", where + ["source_paths", position],
                              "%s does not appear in coverage.paths" % brief(source))

    # -- assets ------------------------------------------------------------

    def rule_assets(self):
        assets = as_list(self.m.get("assets"))
        ids = set()
        paths = set()
        known_ids = self._asset_ids()
        for index, asset in enumerate(assets):
            if not isinstance(asset, dict):
                continue
            where = ["assets", index]
            asset_id = asset.get("id")
            if isinstance(asset_id, str):
                if asset_id in ids:
                    self.fail("WT-ASSET-ID", where + ["id"], "asset id %s is not unique" % brief(asset_id))
                ids.add(asset_id)
            source = asset.get("normalized_from")
            if isinstance(source, str) and (source not in known_ids or source == asset_id):
                self.fail("WT-ASSET-ID", where + ["normalized_from"],
                          "normalized_from must reference a different existing asset")
            self._check_asset_file(asset, where, paths)
            self._check_asset_kind(asset, where)
            self._check_asset_captions(asset, where)

    def _check_asset_file(self, asset, where, paths):
        relative = asset.get("path")
        media_type = asset.get("media_type")
        if not isinstance(relative, str) or not self.ctx.definition_ok("asset_path", relative):
            self.fail("WT-ASSET-PATH", where + ["path"],
                      "path must be a flat assets/<safe-name>.<ext> path")
            return
        if relative in paths:
            self.fail("WT-ASSET-PATH", where + ["path"], "path %s is used by another asset" % brief(relative))
        paths.add(relative)
        extension = relative.rsplit(".", 1)[1].lower()
        if isinstance(media_type, str) and MEDIA_BY_EXTENSION.get(extension) != media_type:
            self.fail("WT-ASSET-MEDIA", where + ["media_type"],
                      "extension .%s does not agree with media_type %s" % (extension, brief(media_type)))
        try:
            digest, size, head = inspect_asset(self.run_dir, relative)
        except AssetProblem as exc:
            self.fail("WT-ASSET-PATH", where + ["path"],
                      "does not resolve to an owned regular file inside the run directory: %s" % exc)
            return
        if asset.get("sha256") != digest:
            self.fail("WT-ASSET-HASH", where + ["sha256"], "sha256 does not equal the file digest %s" % digest)
        if asset.get("bytes") != size or type(asset.get("bytes")) is bool:
            self.fail("WT-ASSET-HASH", where + ["bytes"], "bytes does not equal the file size %d" % size)
        if isinstance(media_type, str) and not signature_matches(media_type, head):
            self.fail("WT-ASSET-MEDIA", where + ["media_type"],
                      "the file's leading bytes do not match the %s signature" % media_type)

    def _check_asset_kind(self, asset, where):
        media_type = asset.get("media_type")
        kind = asset.get("recording_kind")
        duration = asset.get("duration_seconds")
        codec = asset.get("codec")
        interval = asset.get("frame_interval_seconds")
        if isinstance(media_type, str) and media_type.startswith("image/"):
            if kind != "stills":
                self.fail("WT-ASSET-KIND", where + ["recording_kind"],
                          "an image is recorded as stills; a set of stills is never a continuous recording")
            for field, value in (("duration_seconds", duration), ("codec", codec),
                                 ("frame_interval_seconds", interval)):
                if value is not None:
                    self.fail("WT-ASSET-KIND", where + [field], "an image asset must have %s null" % field)
            if as_list(asset.get("captions")):
                self.fail("WT-ASSET-KIND", where + ["captions"], "an image asset cannot have captions")
        elif isinstance(media_type, str) and media_type.startswith("video/"):
            if kind not in ("continuous", "frame-sampled"):
                self.fail("WT-ASSET-KIND", where + ["recording_kind"],
                          "a video is continuous or frame-sampled")
            if duration is None:
                self.fail("WT-ASSET-KIND", where + ["duration_seconds"], "a video needs a duration")
            if codec is None:
                self.fail("WT-ASSET-KIND", where + ["codec"], "a video needs a codec (unknown is allowed)")
            if kind == "frame-sampled" and interval is None:
                self.fail("WT-ASSET-KIND", where + ["frame_interval_seconds"],
                          "a frame-sampled video needs frame_interval_seconds")
            if kind == "continuous" and interval is not None:
                self.fail("WT-ASSET-KIND", where + ["frame_interval_seconds"],
                          "a continuous video has frame_interval_seconds null")
        adapter = dget(asset, "tool", "adapter")
        descriptor = self.ctx.descriptors.get(adapter) if isinstance(adapter, str) else None
        if descriptor is not None:
            recording = as_dict(descriptor.get("recording"))
            if isinstance(kind, str) and kind not in as_list(recording.get("kinds")):
                self.fail("WT-ASSET-KIND-ADAPTER", where + ["recording_kind"],
                          "%s is not offered by descriptor %s" % (brief(kind), brief(adapter)))
            limit = recording.get("max_duration_seconds")
            if is_number(duration) and is_number(limit) and duration > limit:
                self.fail("WT-ASSET-KIND-ADAPTER", where + ["duration_seconds"],
                          "duration %s exceeds the descriptor maximum %s" % (duration, limit))
        if is_number(duration) and duration > 180:
            self.fail("WT-ASSET-DURATION", where + ["duration_seconds"], "duration %s exceeds 180 seconds" % duration)

    def _check_asset_captions(self, asset, where):
        duration = asset.get("duration_seconds")
        previous_start = previous_end = None
        for index, cue in enumerate(as_list(asset.get("captions"))):
            if not isinstance(cue, dict):
                continue
            start, end = cue.get("start"), cue.get("end")
            if not is_number(start) or not is_number(end):
                continue
            here = where + ["captions", index]
            if not start < end:
                self.fail("WT-CAPTION-RANGE", here, "a cue needs start < end")
            if not is_number(duration) or end > duration:
                self.fail("WT-CAPTION-RANGE", here + ["end"],
                          "a cue must end at or before the clip duration (%s)" % brief(duration))
            if previous_start is not None and start < previous_start:
                self.fail("WT-CAPTION-RANGE", here + ["start"], "cues must be sorted by start")
            elif previous_end is not None and start < previous_end:
                self.fail("WT-CAPTION-RANGE", here + ["start"], "cues must not overlap")
            previous_start, previous_end = start, end

    # -- coverage and privacy ----------------------------------------------

    def rule_coverage(self):
        entries = as_list(dget(self.m, "coverage", "paths"))
        chapters = {}
        for chapter in as_list(self.m.get("chapters")):
            if isinstance(chapter, dict) and isinstance(chapter.get("id"), str):
                chapters.setdefault(chapter["id"], chapter)
        inputs = self._derived_inputs()
        if inputs is not None:
            changed_by_path = dict((path, item["change"]) for path, item in derive_changed(*inputs).items())
        else:
            changed_by_path = dict(
                (item["path"], item.get("change"))
                for item in as_list(dget(self.m, "scope", "changed_paths"))
                if isinstance(item, dict) and isinstance(item.get("path"), str))
        covered = []
        for index, entry in enumerate(entries):
            if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
                continue
            path = entry["path"]
            where = ["coverage", "paths", index]
            if path in covered:
                self.fail("WT-COVERAGE-UNMAPPED", where + ["path"],
                          "coverage lists %s more than once" % brief(path))
            covered.append(path)
            status = entry.get("status")
            listed = [item for item in as_list(entry.get("chapters")) if isinstance(item, str)]
            if status == "demonstrated" and not listed:
                self.fail("WT-COVERAGE-CHAPTER", where + ["chapters"],
                          "a demonstrated entry lists at least one chapter")
            for position, chapter_id in enumerate(listed):
                chapter = chapters.get(chapter_id)
                at = where + ["chapters", position]
                if chapter is None:
                    self.fail("WT-COVERAGE-CHAPTER", at, "chapter %s does not exist" % brief(chapter_id))
                elif status == "demonstrated":
                    if chapter.get("status") != "demonstrated":
                        self.fail("WT-COVERAGE-CHAPTER", at, "chapter %s is not demonstrated" % brief(chapter_id))
                    if path not in as_list(chapter.get("source_paths")):
                        self.fail("WT-COVERAGE-CHAPTER", at,
                                  "chapter %s does not list %s in source_paths" % (brief(chapter_id), brief(path)))
            if isinstance(status, str) and (status.startswith("omitted") or status in ("failed", "skipped")) \
                    and entry.get("reason") is None:
                self.fail("WT-COVERAGE-REASON", where + ["reason"], "a %s entry needs a reason" % status)
            if status == "omitted: unobserved":
                change = changed_by_path.get(path)
                if change is not None and change != "unknown":
                    self.fail("WT-COVERAGE-REASON", where + ["status"],
                              "omitted: unobserved is for a path whose change is unknown, not %s" % brief(change))
        scoped = set(item["path"] for item in as_list(dget(self.m, "scope", "changed_paths"))
                     if isinstance(item, dict) and isinstance(item.get("path"), str))
        scoped |= set(item for item in as_list(dget(self.m, "task", "reported_paths")) if isinstance(item, str))
        listed_paths = set(covered)
        for path in sorted(scoped - listed_paths):
            self.fail("WT-COVERAGE-UNMAPPED", ["coverage", "paths"],
                      "scoped path %s has no coverage entry" % brief(path))
        for path in sorted(listed_paths - scoped):
            self.fail("WT-COVERAGE-UNMAPPED", ["coverage", "paths"],
                      "coverage path %s is neither a changed nor a reported path" % brief(path))

    def rule_privacy(self):
        if dget(self.m, "privacy", "capture_scope") == "desktop" \
                and not as_list(dget(self.m, "privacy", "notes")):
            self.fail("WT-PRIVACY", ["privacy", "notes"], "desktop capture requires at least one privacy note")

    # -- output containment -------------------------------------------------

    def rule_containment(self):
        if not self.run_dir_mode:
            return
        abs_dir = os.path.abspath(self.run_dir)
        try:
            root = git_toplevel(abs_dir)
        except Unusable as exc:
            self.fail("WT-OUTPUT-CONTAINMENT", [], "run directory is not inside a git repository: %s" % exc)
            return
        for problem in check_run_dir(abs_dir, root, must_exist=True):
            self.fail("WT-OUTPUT-CONTAINMENT", [], problem)
        run_id = dget(self.m, "run", "id")
        if isinstance(run_id, str) and os.path.basename(abs_dir) != run_id:
            self.fail("WT-OUTPUT-CONTAINMENT", [],
                      "run directory name %s does not equal run.id %s"
                      % (brief(os.path.basename(abs_dir)), brief(run_id)))


def find_lone_surrogates(node, path=None):
    """Lone UTF-16 surrogates cannot be written to a page or a file; report them as shape errors."""
    path = [] if path is None else path
    found = []
    pattern = re.compile("[%s-%s]" % (chr(0xD800), chr(0xDFFF)))
    stack = [(node, path)]
    while stack:
        current, where = stack.pop()
        if isinstance(current, str):
            if pattern.search(current):
                found.append((where, "string contains a lone surrogate code point"))
        elif isinstance(current, dict):
            for key, value in current.items():
                if isinstance(key, str) and pattern.search(key):
                    found.append((where + [key], "property name contains a lone surrogate code point"))
                stack.append((value, where + [key]))
        elif isinstance(current, list):
            for index, value in enumerate(current):
                stack.append((value, where + [index]))
    found.sort(key=lambda item: pointer(item[0]))
    return found


# --------------------------------------------------------------------------
# validate
# --------------------------------------------------------------------------

def validate_manifest(manifest_path, run_dir, context, run_dir_mode):
    """Return (Report, manifest document or None, raw bytes of the manifest)."""
    raw = read_regular_bytes(manifest_path, "manifest")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise Unusable("manifest is not valid UTF-8 (%s): %s" % (exc.reason, manifest_path))
    if text.startswith(BOM):
        raise Unusable("manifest starts with a byte-order mark: %s" % manifest_path)
    document, problems = parse_json_text(text, "manifest")
    report = Report()
    if problems:
        for path, message in problems:
            report.add("WT-JSON-DUPLICATE-KEY", path, message)
        return report, None, raw
    if not isinstance(document, dict):
        report.add("WT-SCHEMA-SHAPE", [], "the manifest must be a JSON object")
        return report, None, raw
    version = document.get("schema_version")
    if not json_equal(version, 1):
        report.add("WT-SCHEMA-VERSION", ["schema_version"],
                   "schema_version must be 1, got %s" % brief(version))
        return report, None, raw
    checker = ManifestChecker(document, context, run_dir, run_dir_mode, report)
    checker.check_shape()
    checker.run_rules()
    return report, document, raw


def resolve_validate_target(args):
    """(manifest file, absolute run directory, run-directory mode).

    --manifest only selects the input file and keeps fixture-mode trust for validate.
    Commands that write into the run directory check its location themselves.
    """
    run_dir = os.path.abspath(args.run_dir)
    if not os.path.isdir(run_dir):
        raise Unusable("run directory not found: %s" % args.run_dir)
    if args.manifest:
        return args.manifest, run_dir, False
    return os.path.join(run_dir, "manifest.json"), run_dir, True


def print_report(report, label, as_json):
    valid = not report.failures
    if as_json:
        print(json.dumps({"valid": valid, "failures": report.failures}, indent=2, ensure_ascii=True))
        return
    for item in report.failures:
        print("%s %s %s" % (item["code"], item["path"], item["message"]))
    if report.dropped:
        print("... %d further failure(s) not shown" % report.dropped)
    if valid:
        print("valid: %s (0 failures)" % label)
    else:
        print("invalid: %d failure(s) in %s [%s]"
              % (len(report.failures) + report.dropped, label, ", ".join(report.codes)))


def cmd_validate(args):
    manifest_path, run_dir, run_dir_mode = resolve_validate_target(args)
    context = Context(args.descriptors)
    report, _, _ = validate_manifest(manifest_path, run_dir, context, run_dir_mode)
    print_report(report, manifest_path, args.json)
    return EXIT_INVALID if report.failures else EXIT_OK


# --------------------------------------------------------------------------
# render
# --------------------------------------------------------------------------

# Code points that are invisible or change text direction; shown as [U+XXXX] instead of acting.
UNSAFE_RANGES = ((0x00, 0x08), (0x0B, 0x1F), (0x7F, 0x9F), (0xAD, 0xAD), (0x61C, 0x61C), (0x180E, 0x180E),
                 (0x200B, 0x200F), (0x2028, 0x202E), (0x2060, 0x206F), (0xFEFF, 0xFEFF), (0xFFF9, 0xFFFB))
_DISPLAY_UNSAFE = re.compile("[" + "".join(
    re.escape(chr(low)) + ("-" + re.escape(chr(high)) if high != low else "")
    for low, high in UNSAFE_RANGES) + "]")

KIND_LABELS = {
    "stills": "Stills (individual screenshots)",
    "continuous": "Continuous recording",
    "frame-sampled": "Frame-sampled recording (frames captured at an interval; not a continuous recording)",
}

CSP = ("default-src 'none'; img-src 'self' file:; media-src 'self' file:; "
       "style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'")

PAGE_CSS = """
:root{color-scheme:light}
*{box-sizing:border-box}
body{font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;margin:0;color:#1d2125;background:#f6f7f9}
header,main,footer{max-width:68rem;margin:0 auto;padding:1rem 1.25rem}
h1{font-size:1.5rem;margin:.2rem 0}
h2{font-size:1.2rem;margin:1.6rem 0 .5rem;border-bottom:1px solid #cfd4da;padding-bottom:.2rem}
h3{font-size:1.05rem;margin:0 0 .4rem}
h4{font-size:.8rem;margin:.8rem 0 .2rem;text-transform:uppercase;letter-spacing:.03em;color:#4a5560}
code{font:13px ui-monospace,Menlo,Consolas,monospace;word-break:break-all}
dl.facts{display:grid;grid-template-columns:max-content 1fr;gap:.2rem 1rem;margin:.4rem 0}
dt{font-weight:600}
dd{margin:0}
.lede{color:#4a5560;margin:.2rem 0 .6rem}
.badge{display:inline-block;padding:0 .5rem;border-radius:.75rem;font-size:.78rem;font-weight:400;border:1px solid currentColor}
.status-complete,.status-demonstrated,.fresh-verified{color:#17663a}
.status-partial,.status-skipped,.status-cancelled,.fresh-unverified,.fresh-verified-commit-only{color:#8a5a00}
.status-failed,.fresh-contradicted{color:#a1261b}
ul.notices{list-style:none;margin:0;padding:0;display:grid;gap:.5rem}
.banner{border:1px solid #cfd4da;border-left-width:.35rem;background:#fff;padding:.5rem .75rem;border-radius:.25rem}
.banner.warn{border-left-color:#c98a00;background:#fff8e6}
.banner.bad{border-left-color:#a1261b;background:#fdecea}
.banner.info{border-left-color:#2563a8}
.banner ul{margin:.3rem 0 0;padding-left:1.2rem}
article.chapter{background:#fff;border:1px solid #cfd4da;border-radius:.4rem;padding:.9rem 1rem;margin:0 0 1rem}
.media-pair{display:grid;grid-template-columns:repeat(auto-fit,minmax(18rem,1fr));gap:.75rem;margin:.6rem 0;align-items:start}
figure{margin:0}
figure img,figure video{max-width:100%;height:auto;border:1px solid #cfd4da;background:#eef0f2}
figcaption{font-size:.82rem;color:#4a5560;margin-top:.2rem}
.clip{position:relative}
.overlay{position:absolute;left:.5rem;right:.5rem;bottom:3.2rem;padding:.25rem .5rem;background:rgba(0,0,0,.72);color:#fff;border-radius:.25rem;text-align:center}
.overlay[hidden]{display:none}
.before-unavailable,.no-capture{border:1px dashed #c98a00;background:#fff8e6;padding:.6rem .75rem;border-radius:.25rem}
.scenario,.observation{white-space:pre-wrap}
table{border-collapse:collapse;width:100%;font-size:.88rem;background:#fff}
th,td{border:1px solid #cfd4da;padding:.3rem .5rem;text-align:left;vertical-align:top}
ol.cues{font-size:.85rem;padding-left:1.4rem;margin:.3rem 0}
.time{font:12px ui-monospace,Menlo,Consolas,monospace;color:#4a5560}
""".strip()

PAGE_SCRIPT_TEMPLATE = r"""
(function () {
  "use strict";
  var node = document.getElementById("walkthrough-manifest");
  if (!node) { return; }
  var manifest;
  try { manifest = JSON.parse(node.textContent); } catch (error) { return; }
  var cues = {};
  (manifest.assets || []).forEach(function (asset) { cues[asset.id] = asset.captions || []; });
  var unsafe = /[__UNSAFE__]/g;
  function clean(text) {
    return String(text).replace(unsafe, function (ch) {
      return "[U+" + ("0000" + ch.charCodeAt(0).toString(16).toUpperCase()).slice(-4) + "]";
    });
  }
  function bind(video) {
    var list = cues[video.getAttribute("data-asset")] || [];
    var overlay = video.parentNode.querySelector(".overlay");
    if (!overlay) { return; }
    function show() {
      var now = video.currentTime;
      var text = "";
      for (var i = 0; i < list.length; i++) {
        if (now >= list[i].start && now < list[i].end) { text = list[i].text; break; }
      }
      overlay.textContent = clean(text);
      overlay.hidden = text === "";
    }
    ["timeupdate", "seeked", "loadedmetadata", "ended"].forEach(function (name) {
      video.addEventListener(name, show);
    });
    show();
  }
  var videos = document.querySelectorAll("video[data-asset]");
  for (var i = 0; i < videos.length; i++) { bind(videos[i]); }
})();
""".strip()


def _js_class():
    """The same unsafe ranges as a JavaScript character-class body."""
    parts = []
    for low, high in UNSAFE_RANGES:
        parts.append("\\u%04x" % low + ("-\\u%04x" % high if high != low else ""))
    return "".join(parts)


PAGE_SCRIPT = PAGE_SCRIPT_TEMPLATE.replace("__UNSAFE__", _js_class())


def visible(text):
    """Make invisible and bidirectional control characters visible instead of active."""
    return _DISPLAY_UNSAFE.sub(lambda match: "[U+%04X]" % ord(match.group()), text)


def h(value):
    """Escape a value for HTML text or an attribute; the result is ASCII only.

    A URL scheme separator is written as character references so no rendered
    text can read as a link or an external reference.
    """
    text = html.escape(visible(str(value)), quote=True).replace("://", ":&#x2F;&#x2F;")
    return text.encode("ascii", "xmlcharrefreplace").decode("ascii")


def seconds(value):
    return "%g" % value


def manifest_json(manifest):
    """The inline copy of the manifest; safe inside a script element."""
    text = json.dumps(manifest, ensure_ascii=True)
    for raw, safe in (("<", "\\u003c"), (">", "\\u003e"), ("&", "\\u0026")):
        text = text.replace(raw, safe)
    return text.replace("://", ":\\/\\/")


def render_list(items, css_class=None, ordered=False):
    if not items:
        return ""
    tag = "ol" if ordered else "ul"
    attr = ' class="%s"' % css_class if css_class else ""
    return "<%s%s>%s</%s>" % (tag, attr, "".join("<li>%s</li>" % item for item in items), tag)


def code_list(paths):
    return ", ".join("<code>%s</code>" % h(path) for path in paths) or "none"


def render_asset(asset, role, title):
    """One image or clip with its recording-kind label and, for clips, every cue as text."""
    kind = asset["recording_kind"]
    label = KIND_LABELS[kind]
    path = h(asset["path"])
    parts = ['<figure class="slot %s" data-slot="%s" data-asset-id="%s" data-recording-kind="%s">'
             % (role, role, h(asset["id"]), h(kind))]
    if asset["media_type"].startswith("image/"):
        parts.append('<img src="%s" alt="%s">' % (path, h("%s: %s" % (role.capitalize(), title))))
    else:
        parts.append('<div class="clip"><video controls preload="metadata" src="%s" data-asset="%s">'
                     '<a href="%s">Open the clip file</a></video><div class="overlay" hidden></div></div>'
                     % (path, h(asset["id"]), path))
    detail = [h(role.capitalize()), '<span class="kind">%s</span>' % h(label)]
    if is_number(asset.get("duration_seconds")):
        detail.append("%s s" % h(seconds(asset["duration_seconds"])))
    if is_number(asset.get("frame_interval_seconds")):
        detail.append("one frame every %s s" % h(seconds(asset["frame_interval_seconds"])))
    parts.append("<figcaption>%s</figcaption>" % " &middot; ".join(detail))
    cues = asset.get("captions") or []
    if cues:
        items = ['<span class="time">%s s to %s s</span> %s'
                 % (h(seconds(cue["start"])), h(seconds(cue["end"])), h(cue["text"])) for cue in cues]
        parts.append('<ol class="cues" data-asset="%s">%s</ol>'
                     % (h(asset["id"]), "".join("<li>%s</li>" % item for item in items)))
    parts.append("</figure>")
    return "".join(parts)


def render_chapter(chapter, assets):
    status = chapter["status"]
    cid = h(chapter["id"])
    title = chapter["title"]
    parts = ['<article class="chapter chapter-%s" id="ch-%s" data-chapter="%s" data-status="%s">'
             % (h(status), cid, cid, h(status)),
             '<h3>%s <span class="badge status-%s">%s</span></h3>' % (h(title), h(status), h(status)),
             '<p class="scenario">%s</p>' % h(chapter["scenario"]),
             "<p>Source paths: %s</p>" % code_list(chapter["source_paths"])]
    if chapter.get("reason") is not None:
        parts.append('<p class="reason"><strong>%s:</strong> %s</p>'
                     % (h(status.capitalize()), h(chapter["reason"])))
    before, after = chapter["before"], chapter["after"]
    parts.append('<div class="media-pair">')
    if before["asset"] is None:
        parts.append('<div class="slot before before-unavailable" data-slot="before">'
                     '<p><strong>Before unavailable:</strong> %s</p></div>' % h(before["unavailable_reason"]))
    else:
        parts.append(render_asset(assets[before["asset"]], "before", title))
    if after["asset"] is None:
        parts.append('<div class="slot after no-capture" data-slot="after">'
                     '<p><strong>No capture:</strong> this chapter is %s.</p></div>' % h(status))
    else:
        parts.append(render_asset(assets[after["asset"]], "after", title))
    parts.append("</div>")
    if chapter.get("observation") is not None:
        parts.append('<h4>Observation</h4><p class="observation">%s</p>' % h(chapter["observation"]))
    if chapter["actions"]:
        parts.append("<h4>Actions</h4>" + render_list([h(item) for item in chapter["actions"]], ordered=True))
    if chapter["checkpoints"]:
        parts.append("<h4>Checkpoints</h4>" + render_list([h(item) for item in chapter["checkpoints"]]))
    if chapter["assertions"]:
        parts.append("<h4>Assertions reported by the executor (not verified here)</h4>" + render_list(
            ["<code>%s</code> &mdash; %s" % (h(item["ref"]), h(item["result"])) for item in chapter["assertions"]]))
    if chapter.get("captured_at") is not None:
        parts.append('<p class="when">Captured %s</p>' % h(chapter["captured_at"]))
    parts.append("</article>")
    return "".join(parts)


def render_notices(m):
    run, build, scope = m["run"], m["build"], m["scope"]
    chapters = m["chapters"]
    items = []

    def banner(kind, tag, body):
        items.append('<li class="banner %s" data-notice="%s">%s</li>' % (kind, tag, body))

    def chapter_link(chapter):
        return '<a href="#ch-%s">%s</a>' % (h(chapter["id"]), h(chapter["title"]))

    if run["status"] != "complete":
        banner("bad" if run["status"] == "failed" else "warn", "run-status",
               "<strong>Run status: %s.</strong> This report is not a complete walkthrough." % h(run["status"]))
    freshness = build["freshness"]
    reason = build["reason"] if build["reason"].endswith((".", "!", "?")) else build["reason"] + "."
    text = '<strong>Build freshness</strong> <span class="badge fresh-%s" data-freshness="%s">%s</span>. %s' % (
        h(freshness), h(freshness), h(freshness), h(reason))
    if freshness == "verified-commit-only":
        text += " The commit is bound; the working-tree paths listed below are not."
    elif freshness == "verified" and build["unbound_paths"]:
        text += " The paths listed below were omitted from the fingerprint, so their bytes are not bound."
    elif freshness == "unverified":
        text += " The running target is not tied to this source."
    if build["unbound_paths"]:
        text += render_list(["<code>%s</code>" % h(path) for path in build["unbound_paths"]], "unbound")
    banner("info" if freshness == "verified" and not build["unbound_paths"] else "warn",
           "build-freshness", text)
    missing = [chapter for chapter in chapters if chapter["before"]["asset"] is None]
    if missing:
        banner("warn", "before-unavailable", "<strong>Before unavailable</strong> for %d chapter(s): %s"
               % (len(missing), ", ".join(chapter_link(chapter) for chapter in missing)))
    broken = [chapter for chapter in chapters if chapter["status"] != "demonstrated"]
    if broken:
        banner("bad", "failed-chapters", "<strong>%d chapter(s) failed or were skipped.</strong>%s" % (
            len(broken), render_list(["%s &mdash; %s: %s" % (
                chapter_link(chapter), h(chapter["status"]), h(chapter["reason"])) for chapter in broken])))
    if scope["committed_changes"]:
        banner("info", "committed-changes", "<strong>Committed changes</strong> between the start and end HEAD:%s"
               % render_list(["<code>%s</code> (%s)" % (h(item["path"]), h(item["change"]))
                              for item in scope["committed_changes"]]))
    if scope["discrepancies"]:
        banner("warn", "discrepancies", "<strong>%d scope discrepancy(ies).</strong>%s" % (
            len(scope["discrepancies"]), render_list(["%s%s &mdash; %s" % (
                h(item["kind"]), "" if item["path"] is None else " <code>%s</code>" % h(item["path"]),
                h(item["detail"])) for item in scope["discrepancies"]])))
    limitations = list(scope["limitations"]) + list(m["coverage"]["limitations"])
    if limitations:
        banner("info", "limitations", "<strong>Limitations.</strong>%s"
               % render_list([h(item) for item in limitations]))
    return '<ul class="notices">%s</ul>' % "".join(items)


def definition_list(pairs):
    return '<dl class="facts">%s</dl>' % "".join(
        "<dt>%s</dt><dd>%s</dd>" % (h(key), value) for key, value in pairs)


def render_page(m):
    """Render a validated manifest to one self-contained, deterministic HTML document."""
    run, repo, task, scope = m["run"], m["repository"], m["task"], m["scope"]
    target, build, coverage, privacy = m["target"], m["build"], m["coverage"], m["privacy"]
    assets = dict((asset["id"], asset) for asset in m["assets"])
    out = []
    add = out.append
    add('<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n')
    add('<meta http-equiv="Content-Security-Policy" content="%s">\n' % h(CSP))
    add('<meta name="viewport" content="width=device-width, initial-scale=1">\n')
    add("<title>Walkthrough %s</title>\n<style>\n%s\n</style>\n</head>\n<body>\n" % (h(run["id"]), PAGE_CSS))
    add("<header>\n<h1>Walkthrough <code>%s</code></h1>\n" % h(run["id"]))
    add('<p class="lede">What changed in the running application, as observed by one executor. '
        'This page is provenance only: not a test result, an approval or an upload.</p>\n')
    add(definition_list([
        ("Run status", '<span class="badge status-%s">%s</span>' % (h(run["status"]), h(run["status"]))),
        ("Created", h(run["created_at"])),
        ("Finalized", h(run["finalized_at"]) if run["finalized_at"] else "not finalized"),
        ("Generator", h("%s %s (%s)" % (run["generator"]["plugin"], run["generator"]["version"],
                                        run["generator"]["provider"]))),
        ("Host", h("%s%s" % (run["host"]["platform"],
                              "" if run["host"]["os_version"] is None else " " + run["host"]["os_version"]))),
    ]))
    add("</header>\n<main>\n")
    add('<section id="notices"><h2>Notices</h2>%s</section>\n' % render_notices(m))
    chapters = "".join(render_chapter(chapter, assets) for chapter in m["chapters"])
    add('<section id="chapters"><h2>Chapters</h2>%s</section>\n'
        % (chapters or "<p>No chapters were recorded.</p>"))
    add('<section id="scope"><h2>Scope</h2>')
    add(definition_list([
        ("Project", "<code>%s</code>" % h(repo["project_id"])),
        ("Branch", h(repo["branch"]) if repo["branch"] else "detached or unknown"),
        ("HEAD at start", "<code>%s</code>" % h(repo["head_start"]) if repo["head_start"] else "not recorded"),
        ("HEAD at end", "<code>%s</code>" % h(repo["head_end"])),
        ("Dirty at end", "yes" if repo["dirty_at_end"] else "no"),
        ("Workflow / task / executor", h(" / ".join(
            str(value) for value in (task["workflow_id"], task["task_id"], task["executor"])
            if value is not None) or "not recorded")),
        ("Task WHERE paths", code_list(task["where"])),
        ("Executor-reported paths", code_list(task["reported_paths"])),
        ("Shared checkout", "yes; attribution is uncertain" if scope["shared_tree"] else "no"),
        ("Start snapshot", h(scope["start"]["captured_at"]) if scope["start"] else
         "unavailable: %s" % h(scope["start_unavailable_reason"])),
        ("End snapshot", h(scope["end"]["captured_at"])),
    ]))
    rows = ["<tr><td><code>%s</code></td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>" % (
        h(item["path"]), h(item["change"]), "yes" if item["in_where"] else "no",
        "yes" if item["reported"] else "no", h(item["attribution"])) for item in scope["changed_paths"]]
    if rows:
        add("<table><thead><tr><th>Changed path</th><th>Change</th><th>In WHERE</th><th>Reported</th>"
            "<th>Attribution</th></tr></thead><tbody>%s</tbody></table>" % "".join(rows))
    else:
        add("<p>No changed paths.</p>")
    add("</section>\n")
    add('<section id="target"><h2>Target and build</h2>')
    viewport = target["viewport"]
    add(definition_list([
        ("Platform", h(target["platform"])),
        ("Adapter", "<code>%s</code>" % h(target["adapter"])),
        ("Identity", "; ".join("%s=%s" % (h(key), h(value)) for key, value in target["identity"].items())),
        ("Viewport", "not recorded" if viewport is None else h(
            "%s x %s @%sx" % (viewport["width"], viewport["height"], seconds(viewport["scale"])))),
        ("Tool versions", "; ".join("%s %s" % (h(key), h(value))
                                    for key, value in target["tool_versions"].items()) or "none"),
        ("Claimed capabilities", h("observe=%s, record=%s, drive=%s" % (
            str(target["capabilities"]["observe"]).lower(), str(target["capabilities"]["record"]).lower(),
            target["capabilities"]["drive"]))),
    ]))
    receipt = build["receipt"]
    if receipt is None:
        add("<p>Build receipt: none.</p>")
    else:
        binding = receipt["binding"]
        bound = ("origin <code>%s</code> path <code>%s</code>" % (h(binding["origin"]), h(binding["path"]))
                 if binding["kind"] == "origin" else
                 "installed %s; product <code>%s</code>; installed <code>%s</code>" % (
                     h(", ".join("%s=%s" % pair for pair in binding["identity"].items())),
                     h(binding["product_sha256"]),
                     h(binding["installed_sha256"]) if binding["installed_sha256"] else "not read back"))
        add(definition_list([
            ("Receipt", h(receipt["kind"])),
            ("Source revision", "<code>%s</code>" % h(receipt["source"]["revision"])),
            ("Source fingerprint", "<code>%s</code>" % h(receipt["source"]["fingerprint"])
             if receipt["source"]["fingerprint"] else "none (commit only)"),
            ("Binding", bound),
            ("Reference", h(receipt["reference"]) if receipt["reference"] else "none"),
            ("Recorded", h(receipt["recorded_at"])),
        ]))
    add("</section>\n")
    cover_rows = ["<tr><td><code>%s</code></td><td>%s</td><td>%s</td><td>%s</td></tr>" % (
        h(item["path"]), h(item["status"]),
        ", ".join('<a href="#ch-%s">%s</a>' % (h(cid), h(cid)) for cid in item["chapters"]) or "none",
        h(item["reason"]) if item["reason"] else "") for item in coverage["paths"]]
    add('<section id="coverage"><h2>Coverage</h2>%s</section>\n' % (
        "<table><thead><tr><th>Path</th><th>Status</th><th>Chapters</th><th>Reason</th></tr></thead>"
        "<tbody>%s</tbody></table>" % "".join(cover_rows) if cover_rows else "<p>No scoped paths.</p>"))
    asset_rows = ["<tr><td><code>%s</code></td><td><a href=\"%s\">%s</a></td><td>%s</td>"
                  "<td data-recording-kind=\"%s\">%s</td><td>%s</td><td><code>%s</code></td><td>%s</td></tr>" % (
                      h(asset["id"]), h(asset["path"]), h(asset["path"]), h(asset["media_type"]),
                      h(asset["recording_kind"]), h(KIND_LABELS[asset["recording_kind"]]),
                      h(asset["bytes"]), h(asset["sha256"]), h(asset["privacy_review"]))
                  for asset in m["assets"]]
    add('<section id="assets"><h2>Assets</h2>%s</section>\n' % (
        "<table><thead><tr><th>Id</th><th>File</th><th>Media type</th><th>Recording kind</th><th>Bytes</th>"
        "<th>SHA-256</th><th>Privacy review</th></tr></thead><tbody>%s</tbody></table>" % "".join(asset_rows)
        if asset_rows else "<p>No assets.</p>"))
    add('<section id="privacy"><h2>Privacy</h2>')
    add(definition_list([
        ("Demo data", h(privacy["demo_data"])),
        ("Capture scope", h(privacy["capture_scope"])),
        ("Egress", h(privacy["egress"])),
        ("Notes", render_list([h(item) for item in privacy["notes"]]) or "none"),
    ]))
    add("</section>\n</main>\n")
    add('<script type="application/json" id="walkthrough-manifest">%s</script>\n' % manifest_json(m))
    add("<script>\n%s\n</script>\n</body>\n</html>\n" % PAGE_SCRIPT)
    return "".join(out)


OUTPUT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}\.html?\Z")


def resolve_output(run_dir, output):
    """The page goes directly into the run directory so its relative assets/ links resolve."""
    base = os.path.abspath(run_dir)
    destination = os.path.abspath(output) if output else os.path.join(base, "index.html")
    parent, name = os.path.dirname(destination), os.path.basename(destination)
    if os.path.islink(parent) or os.path.realpath(parent) != os.path.realpath(base):
        raise Unusable("--output must name a file directly inside the run directory")
    if not OUTPUT_NAME.match(name):
        raise Unusable("--output file name must match %s" % OUTPUT_NAME.pattern)
    try:
        info = os.lstat(destination)
    except FileNotFoundError:
        info = None
    if info is not None and (stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode)):
        raise Unusable("refusing to replace a symlink or non-regular file: %s" % destination)
    return destination


def write_atomic(destination, data):
    """Write through a temp file in the same directory, then rename over the destination."""
    descriptor, temp = tempfile.mkstemp(prefix=".write-", suffix=".tmp", dir=os.path.dirname(destination))
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, destination)
    except BaseException:
        try:
            os.unlink(temp)
        except OSError:
            pass
        raise


def cmd_render(args):
    """Order: containment, lock, containment again, read and validate, render, write, unlock.

    The manifest and the assets are read only while the lock is held, so the page
    always matches the evidence it was validated against. A failure after the lock
    is taken releases it and writes nothing.
    """
    manifest_path, run_dir, run_dir_mode = resolve_validate_target(args)
    context = Context(args.descriptors)
    run_dir, _ = contained_run_dir(run_dir)
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(143))
    timeout = env_int("SESSION_WALKTHROUGH_LOCK_TIMEOUT_SECS", DEFAULT_LOCK_TIMEOUT_SECS, 0)
    destination = None
    with RunLock(run_dir, timeout):
        contained_run_dir(run_dir)  # the wait can be long; check the location again
        report, document, raw = validate_manifest(manifest_path, run_dir, context, run_dir_mode)
        if not report.failures:
            destination = resolve_output(run_dir, args.output)
            write_atomic(destination, render_page(document).encode("ascii"))
    if report.failures:
        print_report(report, manifest_path, False)
        print("render refused: the manifest is invalid", file=sys.stderr)
        return EXIT_INVALID
    print("rendered: %s" % destination)
    print("manifest-sha256: %s" % hashlib.sha256(raw).hexdigest())
    return EXIT_OK


# --------------------------------------------------------------------------
# Run-directory lock
# --------------------------------------------------------------------------

def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return True
    return True


def read_lock_pid(lock_path):
    """The holder pid recorded in lock_path/pid, or None when absent or malformed."""
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        fd = os.open(os.path.join(lock_path, "pid"), flags)
    except OSError:
        return None
    try:
        text = os.read(fd, 64).decode("ascii", "replace").strip()
    except OSError:
        return None
    finally:
        os.close(fd)
    if re.fullmatch(r"[0-9]{1,10}", text) and int(text) >= 1:
        return int(text)
    return None


class RunLock(object):
    """mkdir lock with a pid file; recheck before refusing; dead holders are reclaimed.

    The reclaim works on the lock directory's own descriptor, so a holder that
    releases (renames the directory away) and a newcomer that creates a fresh
    lock at the same path can never be touched by a slow reclaimer.
    """

    def __init__(self, run_dir, timeout):
        self.path = os.path.join(run_dir, ".lock")
        self.timeout = timeout
        self.held = False

    def __enter__(self):
        self.acquire()
        return self

    def __exit__(self, *exc_info):
        self.release()
        return False

    def acquire(self):
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                os.mkdir(self.path, 0o700)
            except FileExistsError:
                pass
            except OSError as exc:
                raise Unusable("cannot create the run lock %s: %s" % (self.path, exc.strerror or exc))
            else:
                self._record_holder()
                self.held = True
                return
            try:
                info = os.lstat(self.path)
            except FileNotFoundError:
                continue  # the holder released between the two calls
            except OSError as exc:
                raise Unusable("cannot inspect the run lock %s: %s" % (self.path, exc.strerror or exc))
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
                if not os.path.lexists(self.path):
                    continue  # recheck: it vanished, so it was not unsafe
                raise Unusable("unsafe run lock (symlink, not a directory, or not owned by you): %s" % self.path)
            holder = read_lock_pid(self.path)
            if holder is not None and not pid_alive(holder) and self._reclaim(holder):
                self.held = True
                return
            if time.monotonic() >= deadline:
                raise Unusable(
                    "could not lock the run directory within %ds (held by pid %s; lock: %s)%s"
                    % (self.timeout, holder if holder is not None else "unknown", self.path,
                       "" if holder is not None else
                       "; the lock has no holder pid, so remove it by hand once no helper is running"))
            time.sleep(0.05)

    def _record_holder(self):
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        try:
            fd = os.open(os.path.join(self.path, "pid"), flags, 0o600)
            try:
                os.write(fd, ("%d\n" % os.getpid()).encode("ascii"))
            finally:
                os.close(fd)
        except OSError as exc:
            try:
                shutil.rmtree(self.path)
            except OSError:
                pass
            raise Unusable("could not record the lock holder pid: %s" % (exc.strerror or exc))

    def _reclaim(self, expected):
        """Take over a lock whose recorded holder is dead; True only on a clean takeover."""
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            anchor = os.open(self.path, flags)
        except OSError:
            return False
        try:
            try:
                os.mkdir("reclaim", dir_fd=anchor)
            except OSError:
                return False
            try:
                pid_flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
                try:
                    fd = os.open("pid", pid_flags, dir_fd=anchor)
                except OSError:
                    return False
                try:
                    current = os.read(fd, 64).decode("ascii", "replace").strip()
                    if current != str(expected):
                        return False
                    os.lseek(fd, 0, os.SEEK_SET)
                    os.ftruncate(fd, 0)
                    os.write(fd, ("%d\n" % os.getpid()).encode("ascii"))
                    return True
                finally:
                    os.close(fd)
            finally:
                try:
                    os.rmdir("reclaim", dir_fd=anchor)
                except OSError:
                    pass
        finally:
            os.close(anchor)

    def release(self):
        """Release only a lock this process holds; one rename retires the whole directory."""
        if not self.held:
            return
        self.held = False
        try:
            if read_lock_pid(self.path) != os.getpid():
                return
            retired = tempfile.mkdtemp(prefix=".release.", dir=os.path.dirname(self.path))
            try:
                os.rename(self.path, os.path.join(retired, "lock"))
            except OSError:
                os.rmdir(retired)
                return
            shutil.rmtree(retired, ignore_errors=True)
        except OSError:
            pass


# --------------------------------------------------------------------------
# scope
# --------------------------------------------------------------------------

UNMERGED = frozenset(("DD", "AU", "UD", "UA", "DU", "AA", "UU"))


def map_state(code):
    """Map a git status XY code to the fingerprint_entry state enum."""
    if code == "??":
        return "untracked"
    if code in UNMERGED:
        return "modified"
    index, tree = code[0], code[1]
    if tree == "D" or (index == "D" and tree == " "):
        return "deleted"
    if "T" in code:
        return "type-changed"
    if index == "A":
        return "added"
    return "modified"


def decode_status_path(token):
    try:
        return token.decode("utf-8")
    except UnicodeDecodeError:
        raise Unusable("a changed path is not valid UTF-8 and cannot be recorded")


def parse_status(raw):
    """Split `git status --porcelain=v1 -z --no-renames` output into (XY code, path) records.

    With --no-renames a staged rename is a deletion plus an addition, as in committed_diff.
    A rename or copy record (`XY new NUL original NUL`) should not appear. If one does,
    no path is dropped: the new path is an addition, and the original of a rename is a
    deletion. A copy leaves its source in place, so the source is listed only when git
    reports it in a record of its own.
    """
    tokens = raw.split(b"\0")
    if tokens and tokens[-1] == b"":
        tokens.pop()
    records = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        index += 1
        if len(token) < 4 or token[2:3] != b" ":
            raise Unusable("unexpected git status record")
        code = token[:2].decode("ascii", "replace")
        path = decode_status_path(token[3:])
        if "R" in code or "C" in code:
            if index >= len(tokens):
                raise Unusable("unexpected git status record: a rename or copy has no original path")
            original = decode_status_path(tokens[index])
            index += 1
            records.append(("A ", path))
            if "R" in code:
                records.append(("D ", original))
            continue
        records.append((code, path))
    return records


class TooLarge(Exception):
    pass


def hash_regular_file(path, limit):
    """SHA-256 and size of an owned-or-readable regular file, refusing symlinks and anything over limit."""
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    fd = os.open(path, flags)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError("not a regular file")
        digest = hashlib.sha256()
        total = 0
        while True:
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                break
            total += len(chunk)
            if total > limit:
                raise TooLarge()
            digest.update(chunk)
        return digest.hexdigest(), total
    finally:
        os.close(fd)


def fingerprint_entry(context, root, code, path, max_bytes):
    state = map_state(code)
    is_directory = path.endswith("/")
    if is_directory:
        path = path.rstrip("/")
    errors = context.definition_errors("repo_path", path)
    if errors:
        raise Unusable("path %s cannot be recorded: %s" % (brief(path), errors[0][1]))
    entry = {"path": path, "state": state, "sha256": None, "bytes": None}
    if state == "deleted":
        entry["omitted"] = "deleted"
        return entry
    full = os.path.join(root, *path.split("/"))
    try:
        info = os.lstat(full)
    except FileNotFoundError:
        entry["state"] = "deleted"
        entry["omitted"] = "deleted"
        return entry
    except OSError:
        entry["omitted"] = "unreadable"
        return entry
    if is_directory or not stat.S_ISREG(info.st_mode):
        entry["omitted"] = "type"
    elif info.st_size > max_bytes:
        entry["omitted"] = "size"
    else:
        try:
            entry["sha256"], entry["bytes"] = hash_regular_file(full, max_bytes)
        except TooLarge:
            entry["omitted"] = "size"
        except OSError:
            entry["omitted"] = "unreadable"
    return entry


def capture_snapshot(context, root, max_bytes):
    """A scope_snapshot of the repository at root. Read-only git; contents are never stored."""
    rc, out, _ = run_git(root, ["rev-parse", "--verify", "HEAD"])
    head = out.decode("ascii", "replace").strip()
    if rc != 0 or not context.definition_ok("git_sha", head):
        raise Unusable("cannot read a 40-hex HEAD commit (an unborn branch or a non-SHA-1 repository is unsupported)")
    rc, out, _ = run_git(root, ["symbolic-ref", "--short", "-q", "HEAD"])
    branch = out.decode("utf-8", "replace").strip() if rc == 0 else None
    if branch is not None and not context.definition_ok("line", branch):
        branch = None
    rc, out, err = run_git(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames"])
    if rc != 0:
        first = err.decode("utf-8", "replace").strip().splitlines()[:1]
        raise Unusable("git status failed (exit %d)%s" % (rc, ": " + first[0] if first else ""))
    records = parse_status(out)
    if len(records) > MAX_SNAPSHOT_ENTRIES:
        raise Unusable("the working tree lists %d changed entries (limit %d); ignore generated output first"
                       % (len(records), MAX_SNAPSHOT_ENTRIES))
    entries = [fingerprint_entry(context, root, code, path, max_bytes) for code, path in records]
    entries.sort(key=lambda entry: entry["path"])
    return {"captured_at": utc_now_text(), "head": head, "branch": branch, "entries": entries,
            "fingerprint": fingerprint_of(entries), "max_bytes": max_bytes}


def write_json_file(path, document):
    """Atomically write a JSON document; a symlink or special file at the destination is refused."""
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        info = None
    if info is not None and (stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode)):
        raise Unusable("refusing to replace a symlink or non-regular file: %s" % path)
    write_atomic(path, (json.dumps(document, indent=2, ensure_ascii=True) + "\n").encode("ascii"))


def load_start_snapshot(context, path):
    document = load_json_strict(path, "scope-start.json")
    errors = context.definition_errors("scope_snapshot", document)
    if errors:
        raise Unusable("scope-start.json is invalid (%s %s); remove it to record the before-unavailable form"
                       % (pointer(errors[0][0]), errors[0][1]))
    if document["fingerprint"] != fingerprint_of(document["entries"]):
        raise Unusable("scope-start.json fingerprint does not match its entries; remove it and start a new run")
    return document


def unique_in_order(items):
    seen = set()
    result = []
    for item in items:
        if item not in seen:
            seen.add(item)
            result.append(item)
    return result


def check_arguments(context, args):
    """Validate every user-supplied value against the manifest schema's own grammar."""
    def paths(values, flag):
        cleaned = unique_in_order(values or [])
        for value in cleaned:
            errors = context.definition_errors("repo_path", value)
            if errors:
                raise Unusable("%s %s is not a repository-relative POSIX path: %s"
                               % (flag, brief(value), errors[0][1]))
        return cleaned

    where, reported = paths(args.where, "--where"), paths(args.reported, "--reported")
    if args.phase == "end" and not where:
        raise Unusable("scope end needs at least one --where path")
    for flag, value, definition in (("--task", args.task, "identifier"), ("--workflow", args.workflow, "identifier"),
                                    ("--executor", args.executor, "identifier"),
                                    ("--project-id", args.project_id, "identifier"),
                                    ("--run", args.run, "run_id"),
                                    ("--start-unavailable-reason", args.start_unavailable_reason, "line")):
        if value is not None:
            errors = context.definition_errors(definition, value)
            if errors:
                raise Unusable("%s %s is invalid: %s" % (flag, brief(value), errors[0][1]))
    return where, reported


def default_project_id(context, root):
    candidate = re.sub(r"[^A-Za-z0-9._-]", "-", os.path.basename(root))[:64].lstrip("._-")
    return candidate if candidate and context.definition_ok("identifier", candidate) else "project"


def resolve_run_dir(context, args, root):
    if args.run_dir:
        run_dir = os.path.abspath(args.run_dir)
    else:
        output_root = os.environ.get("SESSION_WALKTHROUGH_OUTPUT_ROOT") or DEFAULT_OUTPUT_ROOT
        errors = context.definition_errors("repo_path", output_root)
        if errors:
            raise Unusable("SESSION_WALKTHROUGH_OUTPUT_ROOT must be a repository-relative path: %s" % errors[0][1])
        run_id = args.run
        if run_id is None:
            run_id = "wt-%s-%s" % (time.strftime("%Y%m%d-%H%M%S", time.gmtime()), secrets.token_hex(2))
            print("WARN: no --run or --run-dir given; generated run id %s" % run_id, file=sys.stderr)
        run_dir = os.path.join(root, *(output_root.split("/") + [run_id]))
    if not context.definition_ok("run_id", os.path.basename(run_dir)):
        raise Unusable("the run directory name %s must match the run id grammar" % brief(os.path.basename(run_dir)))
    return run_dir


def prepare_run_dir(run_dir, root):
    """Contain, create and re-check the run directory; return the directories this call created.

    On a containment failure the directories made here are removed again.
    """
    problems = check_run_dir(run_dir, root, must_exist=False)
    if problems:
        raise Unusable("; ".join(problems))
    missing = []
    current = run_dir
    while not os.path.lexists(current):
        missing.append(current)
        current = os.path.dirname(current)
    created = []
    try:
        for directory in reversed(missing):
            try:
                os.mkdir(directory, 0o700 if directory == run_dir else 0o777)
                created.append(directory)
            except FileExistsError:
                continue  # another helper made it first; the re-check below still inspects it
        problems = check_run_dir(run_dir, root, must_exist=True)
    except OSError as exc:
        problems = ["cannot create the run directory: %s" % (exc.strerror or exc)]
    if problems:
        for directory in reversed(created):
            try:
                os.rmdir(directory)
            except OSError:
                pass
        raise Unusable("; ".join(problems))
    return created


def discrepancy_detail(kind, path, start, end, reported):
    if kind == "before-unavailable":
        return "No start snapshot; changed paths are the executor's report"
    if kind == "outside-where":
        return ("Reported by the executor; outside the task WHERE paths" if path in reported
                else "Observed in the working tree or commits; outside the task WHERE paths")
    if kind == "observed-not-reported":
        return "Observed in the working tree or commits; not in the executor's reported paths"
    if kind == "reported-not-observed":
        return "Reported by the executor; no change observed between scope start and end"
    if kind == "fingerprint-omitted":
        parts = []
        for label, snapshot in (("start", start), ("end", end)):
            entry = entry_map(snapshot).get(path) if snapshot is not None else None
            if entry is not None and "omitted" in entry:
                parts.append("%s in the %s snapshot" % (entry["omitted"], label))
        return "Fingerprint omitted: " + "; ".join(parts)
    return "Other panes share this checkout; fingerprints do not prove authorship"


def build_summary(context, args, root, where, reported, start, end, committed, reason):
    derived = derive_changed(start, end, where, reported, committed)
    required = derive_discrepancy_requirements(start, end, derived, set(reported), args.shared_tree)
    limitations = [BASE_LIMITATION]
    if start is not None and start["max_bytes"] != end["max_bytes"]:
        limitations.append("The fingerprint size limit differed between scope start and end")
    return {
        "repository": {
            "project_id": args.project_id or default_project_id(context, root),
            "head_start": start["head"] if start is not None else None,
            "head_end": end["head"],
            "branch": end["branch"],
            "dirty_at_end": bool(end["entries"]),
        },
        "task": {"workflow_id": args.workflow, "task_id": args.task, "executor": args.executor,
                 "where": where, "reported_paths": reported},
        "scope": {
            "start": start,
            "start_unavailable_reason": reason,
            "end": end,
            "committed_changes": committed,
            "changed_paths": [
                {"path": path, "change": item["change"], "in_where": item["in_where"],
                 "reported": item["reported"], "attribution": item["attribution"]}
                for path, item in sorted(derived.items())],
            "discrepancies": [
                {"kind": kind, "path": path, "detail": discrepancy_detail(kind, path, start, end, set(reported))}
                for kind, path in sorted(required, key=discrepancy_sort_key)],
            "shared_tree": bool(args.shared_tree),
            "limitations": limitations,
        },
    }


def scope_start(context, args, root, run_dir, max_bytes):
    target = os.path.join(run_dir, "scope-start.json")
    if os.path.lexists(target):
        raise Unusable("scope-start.json already exists in %s; remove it deliberately or start a new run" % run_dir)
    snapshot = capture_snapshot(context, root, max_bytes)
    write_json_file(target, snapshot)
    print("wrote: %s" % target)
    print("head: %s" % snapshot["head"])
    print("entries: %d" % len(snapshot["entries"]))
    print("fingerprint: %s" % snapshot["fingerprint"])


def scope_end(context, args, root, run_dir, max_bytes, where, reported):
    start_path = os.path.join(run_dir, "scope-start.json")
    start, reason = None, None
    if os.path.lexists(start_path):
        if args.start_unavailable_reason is not None:
            raise Unusable("scope-start.json exists; --start-unavailable-reason would contradict it")
        start = load_start_snapshot(context, start_path)
    else:
        reason = args.start_unavailable_reason or DEFAULT_START_REASON
    end = capture_snapshot(context, root, max_bytes)
    committed = []
    if start is not None and start["head"] != end["head"]:
        if not commit_available(root, start["head"]):
            raise Unusable("the scope start HEAD is not available in this repository")
        if is_ancestor(root, start["head"], end["head"]) is not True:
            raise Unusable("the scope start HEAD is not an ancestor of the current HEAD; the history was "
                           "rewritten or switched, so start a new run")
        committed = committed_diff(root, start["head"], end["head"])
        for item in committed:
            errors = context.definition_errors("repo_path", item["path"])
            if errors:
                raise Unusable("committed path %s cannot be recorded: %s" % (brief(item["path"]), errors[0][1]))
    summary = build_summary(context, args, root, where, reported, start, end, committed, reason)
    write_json_file(os.path.join(run_dir, "scope-end.json"), end)
    write_json_file(os.path.join(run_dir, "scope-summary.json"), summary)
    block = summary["scope"]
    kinds = {}
    for item in block["discrepancies"]:
        kinds[item["kind"]] = kinds.get(item["kind"], 0) + 1
    print("wrote: %s" % os.path.join(run_dir, "scope-end.json"))
    print("wrote: %s" % os.path.join(run_dir, "scope-summary.json"))
    print("start: %s" % ("recorded" if start is not None else "unavailable (%s)" % reason))
    print("changed-paths: %d; committed-changes: %d" % (len(block["changed_paths"]), len(committed)))
    print("discrepancies: %s" % (", ".join("%s=%d" % pair for pair in sorted(kinds.items())) or "none"))


def cmd_scope(args):
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(143))
    context = Context()
    where, reported = check_arguments(context, args)
    root = git_toplevel(os.path.abspath(args.repo))
    max_bytes = env_int("SESSION_WALKTHROUGH_FINGERPRINT_MAX_BYTES", DEFAULT_FINGERPRINT_MAX_BYTES, 1)
    timeout = env_int("SESSION_WALKTHROUGH_LOCK_TIMEOUT_SECS", DEFAULT_LOCK_TIMEOUT_SECS, 0)
    run_dir = resolve_run_dir(context, args, root)
    created = prepare_run_dir(run_dir, root)
    print("run-dir: %s" % run_dir)
    finished = False
    try:
        with RunLock(run_dir, timeout):
            problems = check_run_dir(run_dir, root, must_exist=True)  # the wait can be long; check again
            if problems:
                raise Unusable("; ".join(problems))
            if args.phase == "start":
                scope_start(context, args, root, run_dir, max_bytes)
            else:
                scope_end(context, args, root, run_dir, max_bytes, where, reported)
        finished = True
    finally:
        if not finished:
            for directory in reversed(created):  # a failed run leaves no empty directories it made
                try:
                    os.rmdir(directory)
                except OSError:
                    pass
    return EXIT_OK


# --------------------------------------------------------------------------
# command line
# --------------------------------------------------------------------------

def build_parser():
    parser = argparse.ArgumentParser(
        prog="walkthrough.py",
        description="session-walkthrough helper: validate a manifest, render its page, record a scope. "
                    "Exit codes: 0 ok, 1 invalid, 2 unusable input, unsafe location or lock refusal.")
    commands = parser.add_subparsers(dest="command", required=True)

    def manifest_arguments(sub):
        sub.add_argument("--manifest", help="manifest file to read; without it the manifest is RUN_DIR/manifest.json "
                                            "and validate also checks the run directory's place and committed history. "
                                            "render checks the run directory's place either way")
        sub.add_argument("--run-dir", required=True, help="the run directory that holds assets/")
        sub.add_argument("--descriptors", help="descriptor directory (default: scripts/descriptors)")

    validate = commands.add_parser("validate", help="check a manifest against the schema and every WT-* rule")
    manifest_arguments(validate)
    validate.add_argument("--json", action="store_true", help="print {valid, failures[]} instead of lines")
    validate.set_defaults(func=cmd_validate)

    render = commands.add_parser("render", help="validate, then write index.html into the run directory (holds the run lock)")
    manifest_arguments(render)
    render.add_argument("--output", help="page file, directly inside the run directory (default index.html)")
    render.set_defaults(func=cmd_render)

    scope = commands.add_parser("scope", help="record a scope snapshot at the start or end of a task")
    scope.add_argument("phase", choices=("start", "end"))
    group = scope.add_mutually_exclusive_group()
    group.add_argument("--run-dir", help="run directory (default: <repo>/<output root>/<run id>)")
    group.add_argument("--run", help="run id under the output root (default: generated)")
    scope.add_argument("--repo", required=True, help="the git work tree to fingerprint")
    scope.add_argument("--where", action="append", nargs="+", default=[], metavar="PATH",
                       help="task WHERE path prefix; repeatable; required for end")
    scope.add_argument("--reported", action="append", nargs="+", default=[], metavar="PATH",
                       help="path the executor reports as changed; repeatable")
    scope.add_argument("--task", help="task id")
    scope.add_argument("--workflow", help="workflow id")
    scope.add_argument("--executor", help="executor name")
    scope.add_argument("--project-id", help="project id (default: derived from the repository directory name)")
    scope.add_argument("--shared-tree", action="store_true", help="another pane shares this checkout")
    scope.add_argument("--start-unavailable-reason", help="end only: why no scope start exists")
    scope.set_defaults(func=cmd_scope)
    return parser


def flatten(values):
    return [item for group in values for item in group]


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    for name in ("where", "reported"):
        if hasattr(args, name):
            setattr(args, name, flatten(getattr(args, name)))
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="backslashreplace")
        except (AttributeError, ValueError):
            pass
    try:
        return args.func(args)
    except Unusable as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return EXIT_UNUSABLE
    except KeyboardInterrupt:
        print("ERROR: interrupted", file=sys.stderr)
        return 130
    except Exception as exc:  # an unexpected failure must never look like an invalid manifest
        frame = traceback.extract_tb(exc.__traceback__)[-1]
        print("ERROR: internal error %r at line %d" % (exc, frame.lineno), file=sys.stderr)
        return EXIT_UNUSABLE


if __name__ == "__main__":
    sys.exit(main())
