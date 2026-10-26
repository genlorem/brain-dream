"""tools/finding-retire.py: в архив уходит только старая, несвязанная, неоткрытая находка."""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("finding_retire", Path(__file__).parents[1] / "tools" / "finding-retire.py")
fr = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fr)

NOW = dt.datetime(2026, 10, 26, tzinfo=dt.timezone.utc)


def node(directory: Path, name: str, nid: str, observed: str, links: str = "[]", body: str = "тело") -> Path:
    path = directory / name
    path.write_text(f"---\nid: {nid}\ntype: lesson\ntitle: '{name}'\nobserved_at: '{observed}'\n"
                    f"links: {links}\n---\n{body}\n", encoding="utf-8")
    return path


class FindingRetireTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.repo = base / "dreams"
        self.nodes = self.repo / "nodes"
        self.nodes.mkdir(parents=True)
        self.other = base / "personal" / "nodes"
        self.other.mkdir(parents=True)
        old, young = "2026-07-01T00:00:00Z", "2026-10-20T00:00:00Z"
        node(self.nodes, "finding-old.md", "finding:aaaaaaaa00000001", old)
        node(self.nodes, "finding-young.md", "finding:aaaaaaaa00000002", young)
        node(self.nodes, "finding-linked.md", "finding:aaaaaaaa00000003", old,
             links="[{rel: relates-to, to: 'note:x'}]")
        node(self.nodes, "finding-referenced.md", "finding:aaaaaaaa00000004", old)
        node(self.nodes, "finding-opened.md", "finding:aaaaaaaa00000005", old)
        node(self.nodes, "finding-selfref.md", "finding:aaaaaaaa00000006", old, body="см. finding:aaaaaaaa00000006")
        node(self.nodes, "dream-2026-07-01.md", "dream:2026-07-01", old)
        node(self.other, "note-x.md", "note:x", old, body="вывод из finding:aaaaaaaa00000004")
        self.clicks = base / "clicks.ndjson"
        self.clicks.write_text("\n".join(json.dumps(r) for r in [
            {"kind": "click", "id": "finding:aaaaaaaa00000005"},
            {"kind": "search", "ids": ["finding:aaaaaaaa00000001"]},
        ]), encoding="utf-8")
        self.roots = [str(self.nodes), str(self.other)]
        for cmd in (["init", "-q"], ["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"]):
            subprocess.run(["git", "-C", str(self.repo), *cmd], check=True)

    def tearDown(self):
        self.tmp.cleanup()

    def test_only_old_unlinked_unopened_findings_retire(self):
        items, stats = fr.candidates(str(self.nodes), 60, self.roots, str(self.clicks), NOW)
        self.assertEqual(sorted(i["id"] for i in items), ["finding:aaaaaaaa00000001", "finding:aaaaaaaa00000006"])
        self.assertEqual((stats["young"], stats["own_links"], stats["referenced"], stats["opened"]), (1, 1, 1, 1))
        self.assertEqual(stats["findings"], 6, "dream-узлы не трогаем")

    def test_apply_moves_out_of_nodes_and_commits(self):
        items, _ = fr.candidates(str(self.nodes), 60, self.roots, str(self.clicks), NOW)
        self.assertEqual(fr.apply(items, str(self.nodes), 60), 2)
        self.assertFalse((self.nodes / "finding-old.md").exists())
        self.assertTrue((self.repo / "archive" / "findings" / "2026-07" / "finding-old.md").exists())
        self.assertTrue((self.nodes / "finding-young.md").exists())
        log = subprocess.run(["git", "-C", str(self.repo), "log", "--oneline", "-1"], capture_output=True, text=True).stdout
        self.assertIn("finding-retire: 2", log)
        status = subprocess.run(["git", "-C", str(self.repo), "status", "--short"], capture_output=True, text=True).stdout
        self.assertEqual(status.strip(), "")


if __name__ == "__main__":
    unittest.main()
