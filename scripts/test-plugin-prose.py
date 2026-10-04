#!/usr/bin/env python3
"""Offline controls for the advisory prose checker."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('prose', HERE / 'lint-plugin-prose.py')
prose = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prose)


class ProseChecks(unittest.TestCase):
    def test_sentence_targets_have_boundary_controls(self):
        for marker, limit in [('', 25), ('- ', 20), ('1. ', 20)]:
            with self.subTest(marker=marker):
                self.assertEqual(prose.lint(marker + 'word ' * limit + '.', 'x'), [])
                found = prose.lint(marker + 'word ' * (limit + 1) + '.', 'x')
                self.assertEqual([f['rule'] for f in found], ['sentence-length'])

    def test_wrapped_paragraph_and_sentence_split(self):
        self.assertEqual(prose.lint('word ' * 20 + '.\n' + 'word ' * 20 + '.', 'x'), [])
        self.assertEqual(len(prose.lint('word ' * 20 + '\n' + 'word ' * 10 + '.', 'x')), 1)

    def test_preferred_words_have_controls(self):
        for term in prose.PREFER:
            self.assertEqual(prose.lint('Please ' + term.upper() + ' the file.', 'x')[0]['rule'], 'word-choice')
        self.assertEqual(prose.lint('Use the file. Start the task.', 'x'), [])
        self.assertEqual(prose.lint('commencement', 'x'), [])

    def test_literal_and_nonprose_regions(self):
        cases = [
            '---\nname: utilize\n---\n',
            '```sh\nutilize\n```\n',
            '~~~~md\n```\nutilize\n~~~~\n',
            '    utilize\n', '# utilize\n', '> utilize\n',
            '| utilize | field |\n', '<!-- utilize\nutilize -->\n',
            'Term | Meaning\n--- | ---\nutilize | field\n',
            'Run `utilize` now.\n', 'Run ``a `utilize` b`` now.\n',
            '[label](https://example.invalid/utilize)\n',
            '[link]: https://example.invalid/utilize\n',
        ]
        for text in cases:
            with self.subTest(text=text):
                self.assertEqual(prose.lint(text + '\nUse the file.', 'x'), [])
                self.assertEqual(len(prose.lint(text + '\nUtilize the file.', 'x')), 1)

    def test_comment_inside_fence_cannot_hide_later_prose(self):
        self.assertEqual(len(prose.lint('```\n<!--\n```\nUtilize the file.', 'x')), 1)
        self.assertEqual(prose.lint('<!--\n```\n-->\nUse the file.', 'x'), [])

    def test_code_comment_marker_cannot_hide_later_prose(self):
        self.assertEqual(len(prose.lint('Write `<!--` markers.\n\nUtilize the file.', 'x')), 1)
        self.assertEqual(prose.lint('<!--\nUtilize the file.\n-->', 'x'), [])

    def test_nested_list_and_code_are_distinct(self):
        self.assertEqual(len(prose.lint('- Parent\n    - Utilize the file.', 'x')), 1)
        self.assertEqual(len(prose.lint('- Parent\n    - Item\n      Utilize the file.', 'x')), 1)
        self.assertEqual(prose.lint('- Parent\n\n      Utilize the file.', 'x'), [])
        self.assertEqual(len(prose.lint('- Item\n\n    Utilize the file.', 'x')), 1)
        self.assertEqual(len(prose.lint('Paragraph.\n    Utilize the file.', 'x')), 1)

    def test_list_fence_and_following_prose(self):
        for fence in ['```', '~~~']:
            text = f'1. Step\n\n    {fence}sh\n    utilize --x\n    {fence}\n'
            self.assertEqual(prose.lint(text, 'x'), [])
            self.assertEqual(len(prose.lint(text + '\n    Utilize the file.', 'x')), 1)

    def test_unclosed_frontmatter_and_thematic_break(self):
        self.assertEqual(len(prose.lint('---\nname: example\nUtilize the file.', 'x')), 1)
        self.assertEqual(len(prose.lint('---\nUtilize the file.\n---', 'x')), 1)
        self.assertEqual(prose.lint('---\nname: utilize\n---\nUse the file.', 'x'), [])

    def test_table_header_and_cell_count(self):
        self.assertEqual(prose.lint('Utilize | Meaning\n-|-\nUse | item\n', 'x'), [])
        self.assertEqual(len(prose.lint('Utilize\n---|---\n', 'x')), 1)

    def test_urls_html_and_crlf(self):
        self.assertEqual(prose.lint('See https://example.invalid/utilize now.', 'x'), [])
        self.assertEqual(len(prose.lint('See utilize now.', 'x')), 1)
        self.assertEqual(prose.lint('<span title="utilize">Use</span>', 'x'), [])
        self.assertEqual(len(prose.lint('<span>Utilize</span>', 'x')), 1)
        self.assertEqual(prose.lint('```sh\r\nutilize\r\n```\r\n', 'x'), [])
        self.assertEqual(len(prose.lint('```sh\r\nuse\r\n```\r\nUtilize the file.', 'x')), 1)

    def test_link_label_is_prose(self):
        self.assertEqual(len(prose.lint('[Utilize](https://example.invalid)', 'x')), 1)

    def test_line_location(self):
        self.assertEqual(prose.lint('# Header\n\nUtilize the file.', 'x')[0]['line'], 3)

    def test_default_scope_excludes_fixtures_and_stores(self):
        for path in ['plugins/a/skills/b/SKILL.md', 'codex/plugins/a/assets/example.md', 'shared/PLUGIN_WRITING.md']:
            self.assertTrue(prose.eligible(path), path)
        for path in ['plugins/a/evals/b/prompt.md', 'plugins/a/evals/skills/x.md', '.agents/memory/example.md', '.tmp/output.md', 'plugins/a/scripts/code.py']:
            self.assertFalse(prose.eligible(path), path)

    def test_cli_is_advisory_and_does_not_write(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'example.md'
            for text, expected in [('Utilize the file.', 1), ('Use the file.', 0)]:
                path.write_text(text)
                before = path.stat().st_mtime_ns
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    self.assertEqual(prose.main([str(path), '--json']), 0)
                report = json.loads(out.getvalue())
                self.assertTrue(report['advisory_only'])
                self.assertEqual(len(report['findings']), expected)
                self.assertEqual(path.read_text(), text)
                self.assertEqual(path.stat().st_mtime_ns, before)

    def test_bad_inputs_fail_without_partial_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); regular = root / 'good.md'; regular.write_text('Use the file.')
            link = root / 'link.md'; link.symlink_to(regular)
            binary = root / 'binary.md'; binary.write_bytes(b'\xff')
            other = root / 'good.txt'; other.write_text('Use the file.')
            for path in [root / 'missing.md', root, link, binary, other]:
                out, err = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    self.assertEqual(prose.main([str(path), '--json']), 2)
                self.assertEqual(out.getvalue(), '')
                self.assertIn('ERROR:', err.getvalue())

    def test_changed_revision_uses_current_tracked_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def git(*args):
                return subprocess.check_output(['git', *args], cwd=root, stderr=subprocess.PIPE)
            git('init', '-q'); git('config', 'user.email', 'fixture@example.invalid'); git('config', 'user.name', 'Fixture')
            path = root / 'plugins/example/skills/demo/SKILL.md'; path.parent.mkdir(parents=True)
            path.write_text('Use the file.'); git('add', '.'); git('commit', '-qm', 'baseline')
            self.assertEqual(prose.tracked_paths(root, 'HEAD'), [])
            path.write_text('Utilize the file.')
            new = path.parent / 'new.md'; new.write_text('Not tracked.')
            self.assertEqual(prose.tracked_paths(root, 'HEAD'), [path])
            self.assertEqual(prose.tracked_paths(root), [path])
            with patch.object(prose, 'ROOT', root), contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(prose.main(['--json']), 0)
            self.assertEqual(json.loads(out.getvalue())['files'], 1)
            self.assertEqual(len(prose.lint(path.read_text(), str(path))), 1)
            with self.assertRaises(subprocess.CalledProcessError):
                prose.tracked_paths(root, '--not-a-revision')
            path.unlink()
            self.assertEqual(prose.tracked_paths(root, 'HEAD'), [])
            self.assertEqual(prose.tracked_paths(root), [])


if __name__ == '__main__':
    unittest.main()
