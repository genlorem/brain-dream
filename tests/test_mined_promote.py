"""Тесты mined-promote без fastmcp, subprocess и сети."""
from __future__ import annotations

import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import date
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).parents[1] / "tools" / "mined-promote.py"
SPEC = importlib.util.spec_from_file_location("mined_promote", MODULE_PATH)
mined_promote = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = mined_promote
SPEC.loader.exec_module(mined_promote)


class FakeGateway:
    def __init__(self, results=()):
        self.results = list(results)
        self.searches = []
        self.adds = []
        self.links = []

    def search(self, query, limit=5):
        self.searches.append((query, limit))
        return self.results

    def add(self, node, root):
        self.adds.append((node, root))
        return {"id": node["id"]}

    def link(self, src_id, rel, to_id, **kwargs):
        self.links.append((src_id, rel, to_id, kwargs))
        return {"ok": True}


class MinedPromoteTests(unittest.TestCase):
    def setUp(self):
        self.today = date(2026, 7, 30)

    def write_candidate(
        self,
        root: Path,
        name: str,
        *,
        node_id: str | None = None,
        tags: str = "[mined-candidate, lesson]",
        confidence: float = 0.91,
        title: str | None = None,
    ) -> str:
        candidate_id = node_id or f"candidate:mined-{name}"
        nodes = root / "nodes"
        nodes.mkdir(parents=True, exist_ok=True)
        (nodes / f"{name}.md").write_text(
            "---\n"
            f"id: {candidate_id}\n"
            f"title: {title or name}\n"
            f"tags: {tags}\n"
            f"confidence: {confidence}\n"
            "chat: archive-chat\n"
            "message_ids: [m1, m2]\n"
            "mined_at: 2026-07-29T04:00:00Z\n"
            "---\n"
            f"Durable statement for {name}.\n",
            encoding="utf-8",
        )
        return candidate_id

    @staticmethod
    def promote_decision(**changes):
        value = {
            "action": "promote",
            "domain": "personal",
            "node_type": "lesson",
            "title": "Promoted fact",
            "links": [],
            "confidence": 0.92,
            "reason": "durable knowledge",
        }
        value.update(changes)
        return value

    def test_scan_filters_tag_confidence_and_terminal_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            good = self.write_candidate(root, "good")
            deferred = self.write_candidate(root, "retry")
            blocked = self.write_candidate(root, "blocked")
            self.write_candidate(root, "low", confidence=0.5)
            self.write_candidate(root, "wrong-tag", tags="[lesson]")
            state = root / "promote-log" / "decisions.jsonl"
            state.parent.mkdir()
            state.write_text(
                json.dumps({"id": blocked, "action": "promote"}) + "\n"
                + json.dumps({"id": deferred, "action": "defer"}) + "\n",
                encoding="utf-8",
            )
            candidates = mined_promote.scan_candidates(root, min_conf=0.85)
        self.assertEqual({item.id for item in candidates}, {good, deferred})

    def test_links_are_filtered_to_search_result_ids(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_candidate(root, "abc123")
            gateway = FakeGateway([{"id": "note:allowed", "title": "Allowed"}])
            decision = self.promote_decision(
                links=["note:allowed", "note:hallucinated"],
            )
            prompts = []
            mined_promote.run_promote(
                root,
                apply=True,
                gateway=gateway,
                judge=lambda prompt: prompts.append(prompt) or decision,
                today=self.today,
            )
        relates = [call for call in gateway.links if call[1] == "relates-to"]
        self.assertEqual([call[2] for call in relates], ["note:allowed"])
        self.assertIn("links — ТОЛЬКО id", prompts[0])

    def test_dry_run_has_no_mcp_writes_or_decisions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_candidate(root, "abc123")
            gateway = FakeGateway()
            result = mined_promote.run_promote(
                root,
                gateway=gateway,
                judge=lambda prompt: self.promote_decision(),
                today=self.today,
            )
            state = root / "promote-log" / "decisions.jsonl"
            report = Path(result["report"]).read_text(encoding="utf-8")
        self.assertEqual(gateway.adds, [])
        self.assertEqual(gateway.links, [])
        self.assertFalse(state.exists())
        self.assertEqual(result["would_promote"], 1)
        self.assertIn("[would-promote]", report)

    def test_apply_adds_superseded_by_link_from_candidate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            candidate_id = self.write_candidate(root, "abc123")
            gateway = FakeGateway()
            mined_promote.run_promote(
                root,
                apply=True,
                gateway=gateway,
                judge=lambda prompt: self.promote_decision(),
                today=self.today,
            )
        supersede = [call for call in gateway.links if call[1] == "superseded-by"]
        self.assertEqual(len(supersede), 1)
        self.assertEqual(supersede[0][:3], (
            candidate_id,
            "superseded-by",
            "lesson:mined-abc123",
        ))
        self.assertEqual(supersede[0][3]["at"], "2026-07-30")
        self.assertIn("observed_at", gateway.adds[0][0])
        self.assertEqual(gateway.adds[0][0]["links"], [])

    def test_decisions_log_makes_promote_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.write_candidate(root, "abc123")
            gateway = FakeGateway()
            first = mined_promote.run_promote(
                root,
                apply=True,
                gateway=gateway,
                judge=lambda prompt: self.promote_decision(),
                today=self.today,
            )
            second = mined_promote.run_promote(
                root,
                apply=True,
                gateway=gateway,
                judge=lambda prompt: self.promote_decision(),
                today=self.today,
            )
            records = [
                json.loads(line)
                for line in (
                    root / "promote-log" / "decisions.jsonl"
                ).read_text(encoding="utf-8").splitlines()
            ]
        self.assertEqual(first["promoted"], 1)
        self.assertEqual(second["considered"], 0)
        self.assertEqual(len(gateway.adds), 1)
        self.assertEqual([item["action"] for item in records], ["promote"])

    def test_kill_switch_exits_two_before_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            disabled = Path(tmp) / "mined-promote-disabled"
            disabled.touch()
            output = io.StringIO()
            with mock.patch.object(
                mined_promote,
                "kill_switch_path",
                return_value=disabled,
            ), mock.patch.object(mined_promote, "run_promote") as run, redirect_stdout(output):
                rc = mined_promote.main([])
        self.assertEqual(rc, 2)
        run.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())["error"], "guard_refused")

    def test_invalid_judge_domain_defers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            candidate_id = self.write_candidate(root, "abc123")
            gateway = FakeGateway()
            result = mined_promote.run_promote(
                root,
                apply=True,
                gateway=gateway,
                judge=lambda prompt: self.promote_decision(domain="unknown"),
                today=self.today,
            )
            record = json.loads(
                (root / "promote-log" / "decisions.jsonl").read_text(
                    encoding="utf-8",
                ),
            )
        self.assertEqual(result["deferred"], 1)
        self.assertEqual(gateway.adds, [])
        self.assertEqual(record["id"], candidate_id)
        self.assertEqual(record["action"], "defer")


if __name__ == "__main__":
    unittest.main()
