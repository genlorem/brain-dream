"""Digest rendering stays deterministic and preserves the publication registry."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location(
    'digest', Path(__file__).resolve().parents[1] / 'tools/dream-digest-dedup.py')
digest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(digest)


class DigestRegistryTest(unittest.TestCase):
    def test_render_keeps_titles_and_compacts_registry(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            md, registry = root / 'dream.md', root / 'registry.jsonl'
            md.write_text('## Синтез\n\n1. Повтор\nОписание\n2. Новый\nДетали\n')
            rows = [
                {'date': '2026-10-01', 'title': 'Старый'},
                {'date': '2026-11-02', 'title': 'Повтор'},
            ]
            registry.write_text(''.join(json.dumps(row) + '\n' for row in rows))
            args = SimpleNamespace(synthesis=str(md), registry=str(registry),
                                   today='2026-11-03', days=5, max_titles=10)
            # Повторный render не дублирует сегодняшние записи.
            for _ in range(2):
                out, err = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    self.assertEqual(digest.render(args), 0)
                self.assertEqual(out.getvalue(), '1. Повтор\n2. Новый\n')
                self.assertIn('status=registry_only', err.getvalue())
                self.assertIn('suppressed=0', err.getvalue())
            saved = [json.loads(line) for line in registry.read_text().splitlines()]
            self.assertEqual(len(saved), 3)
            self.assertEqual(saved[0]['date'], '2026-11-02')

    def test_missing_synthesis_returns_fallback_status(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(digest.render(SimpleNamespace(
                synthesis='/nonexistent/dream.md', max_titles=10)), 1)


if __name__ == '__main__':
    unittest.main()
