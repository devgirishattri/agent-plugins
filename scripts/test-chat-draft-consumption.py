#!/usr/bin/env python3
"""Exercise both dispatch wrappers with deterministic read/delivery failures.

Transport is replaced by a recorder; filesystem validation and cleanup use the
actual provider library. Real tmux delivery/queue recovery belongs to each
provider's session-chat suite. Script-directory overrides support original-code
regression evidence without modifying the checkout.
"""

import argparse
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--provider", choices=("all", "claude", "codex"), default="all")
parser.add_argument("--claude-scripts", type=Path,
                    default=ROOT / "plugins/session-chat/scripts")
parser.add_argument("--codex-scripts", type=Path,
                    default=ROOT / "codex/plugins/session-chat/scripts")
options, test_args = parser.parse_known_args()
SOURCES = {"claude": options.claude_scripts, "codex": options.codex_scripts}
if options.provider != "all":
    SOURCES = {options.provider: SOURCES[options.provider]}

SHIMS = r'''
ensure_tmux() { return 0; }
get_my_name() { printf 'sender\n'; }
cat() {
  if [ "$#" -eq 1 ] && [ "$1" = "$DRAFT_PROBE_FILE" ]; then
    case "${DRAFT_PROBE_READ:-ok}" in
      fail) echo 'injected read failure' >&2; return 1 ;;
      partial) printf 'PARTIAL'; echo 'injected partial read failure' >&2; return 1 ;;
    esac
  fi
  command cat "$@"
}
dispatch_message() {
  printf '%s' "$2" > "$DRAFT_PROBE_SENT"
  case "${DRAFT_PROBE_DELIVERY:-live}" in
    fail) return 1 ;;
    queued) return 3 ;;
  esac
  if [ "${DRAFT_PROBE_EDIT:-0}" = 1 ]; then
    printf '\n' >> "$DRAFT_PROBE_FILE"
  fi
  return 0
}
'''


class DraftConsumption(unittest.TestCase):
    def run_case(self, provider, *, read="ok", delivery="live", edit=False,
                 keep=False, mode=0o600, shape="own"):
        with tempfile.TemporaryDirectory(prefix="chat-draft-") as raw:
            base = Path(raw).resolve()
            scripts = SOURCES[provider].resolve()
            wrapper = base / "dispatch-to-session.sh"
            shutil.copyfile(scripts / wrapper.name, wrapper)
            (base / "lib.sh").write_text(
                "source " + shlex.quote(str(scripts / "lib.sh")) + "\n" + SHIMS)
            store = base / "messages"
            drafts = store / "drafts/sender"
            drafts.mkdir(parents=True)
            for directory in (store, store / "drafts", drafts):
                directory.chmod(0o700)
            draft = drafts / "verdict.md"
            if shape == "plain":
                draft = base / "prompt.md"
            elif shape == "foreign":
                draft = store / "drafts/peer/verdict.md"
                draft.parent.mkdir(mode=0o700)
            elif shape == "extension":
                draft = drafts / "verdict.sh"
            elif shape == "long":
                draft = drafts / ("n" * 130 + ".md")
            body = b"COMPLETE VERDICT\nsecond line\n"
            draft.write_bytes(body)
            draft.chmod(mode)
            if shape == "symlink":
                target = base / "linked-source.md"
                draft.rename(target)
                draft.symlink_to(target)
            elif shape == "hardlink":
                os.link(draft, base / "other-link.md")
            elif shape in {"root-link", "parent-link", "own-link"}:
                directory = {"root-link": store, "parent-link": store / "drafts",
                             "own-link": drafts}[shape]
                target = base / "linked-directory"
                directory.rename(target)
                directory.symlink_to(target, target_is_directory=True)
            elif shape in {"root-writable", "parent-writable", "own-writable"}:
                directory = {"root-writable": store,
                             "parent-writable": store / "drafts",
                             "own-writable": drafts}[shape]
                directory.chmod(0o777)
            sent = base / "sent"
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith(("SESSION_", "KNOWLEDGE_", "BASH_FUNC_"))
                   and key not in {"TMUX", "TMUX_PANE", "BASH_ENV", "ENV"}}
            env.update({
                "SESSION_CHAT_TARGET_MESSAGES_DIR": str(store),
                "SESSION_CHAT_KEEP_DRAFTS": "1" if keep else "0",
                "DRAFT_PROBE_FILE": str(draft),
                "DRAFT_PROBE_SENT": str(sent),
                "DRAFT_PROBE_READ": read,
                "DRAFT_PROBE_DELIVERY": delivery,
                "DRAFT_PROBE_EDIT": "1" if edit else "0",
            })
            run = subprocess.run(["bash", str(wrapper), "receiver", str(draft)],
                                 env=env, capture_output=True, text=True, timeout=15)
            return {"code": run.returncode, "stdout": run.stdout,
                    "stderr": run.stderr,
                    "remaining": draft.read_bytes() if draft.exists() else None,
                    "sent": sent.read_bytes() if sent.exists() else None,
                    "body": body}

    def control(self, provider, **kwargs):
        result = self.run_case(provider, **kwargs)
        self.assertEqual(result["code"], 0, result)
        self.assertIsNone(result["remaining"], result)
        # Existing dispatch transports shell text, normalizing trailing newlines.
        self.assertEqual(result["sent"], result["body"].rstrip(b"\n"), result)
        self.assertIn("Removed delivered draft:", result["stdout"], result)

    def test_read_errors_keep_source_and_never_dispatch(self):
        for provider in SOURCES:
            for failure in ("fail", "partial"):
                with self.subTest(provider=provider, read=failure):
                    self.control(provider)
                    result = self.run_case(provider, read=failure)
                    self.assertNotEqual(result["code"], 0, result)
                    self.assertIsNone(result["sent"], result)
                    self.assertEqual(result["remaining"], result["body"], result)

    def test_mode_policy_has_native_writer_control(self):
        for provider in SOURCES:
            with self.subTest(provider=provider):
                self.control(provider, mode=0o644)
                result = self.run_case(provider, mode=0o664)
                self.assertEqual(result["code"], 0, result)
                self.assertEqual(result["remaining"], result["body"], result)
                self.assertEqual(result["sent"], result["body"].rstrip(b"\n"), result)

    def test_opt_out_and_failed_delivery_keep_source(self):
        for provider in SOURCES:
            for variant in ({"keep": True}, {"delivery": "fail"}):
                with self.subTest(provider=provider, variant=variant):
                    self.control(provider)
                    result = self.run_case(provider, **variant)
                    self.assertEqual(result["remaining"], result["body"], result)
                    if variant.get("delivery") == "fail":
                        self.assertNotEqual(result["code"], 0, result)
                    else:
                        self.assertEqual(result["code"], 0, result)

    def test_ineligible_sources_are_not_consumed(self):
        shapes = ("plain", "foreign", "extension", "long", "symlink", "hardlink",
                  "root-link", "parent-link", "own-link", "root-writable",
                  "parent-writable", "own-writable")
        for provider in SOURCES:
            for shape in shapes:
                with self.subTest(provider=provider, shape=shape):
                    self.control(provider)
                    result = self.run_case(provider, shape=shape)
                    self.assertEqual(result["code"], 0, result)
                    self.assertEqual(result["remaining"], result["body"], result)
                    self.assertEqual(result["sent"], result["body"].rstrip(b"\n"), result)

    def test_newline_edit_is_not_deleted(self):
        for provider in SOURCES:
            with self.subTest(provider=provider):
                self.control(provider)
                result = self.run_case(provider, edit=True)
                self.assertEqual(result["code"], 0, result)
                self.assertEqual(result["remaining"], result["body"] + b"\n", result)
                self.assertEqual(result["sent"], result["body"].rstrip(b"\n"), result)

    def test_wrapper_accepts_durable_queue_return(self):
        # This covers wrapper rc handling only, not the real queue persistence.
        for provider in SOURCES:
            with self.subTest(provider=provider):
                self.control(provider, delivery="queued")


if __name__ == "__main__":
    unittest.main(argv=[__file__, *test_args])
