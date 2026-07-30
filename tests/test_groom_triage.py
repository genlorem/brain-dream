"""Тесты LLM-triage graph-groom без subprocess, движка и сети."""
from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).parents[1] / "tools" / "graph-groom.py"
SPEC = importlib.util.spec_from_file_location("graph_groom_triage", MODULE_PATH)
graph_groom = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = graph_groom
SPEC.loader.exec_module(graph_groom)


@dataclass
class Root:
    name: str


@dataclass
class Node:
    type: str
    root: Root
    title: str
    path: Path


class FakeVault:
    def __init__(self, nodes):
        self.index = nodes

    def _iter_edges(self):
        return iter(())


class GroomTriageTests(unittest.TestCase):
    def setUp(self):
        self.numpy = graph_groom.np
        graph_groom.np = None
        self.today = date(2026, 7, 30)

    def tearDown(self):
        graph_groom.np = self.numpy

    def make_vault(self, root: Path, domains):
        nodes = {}
        for name, domain in domains.items():
            path = root / f"{name}.md"
            path.write_text(
                f"---\nid: note:{name}\ntitle: {name}\n---\nBody for {name}.\n",
                encoding="utf-8",
            )
            nodes[f"note:{name}"] = Node("note", Root(domain), name, path)
        return FakeVault(nodes)

    def add_proposals(self, root: Path, pairs):
        proposals = root / "edge-proposals"
        proposals.mkdir(parents=True, exist_ok=True)
        (proposals / "2026-07-29.md").write_text(
            "".join(f"- [ ] `{a}` <-> `{b}`\n" for a, b in pairs),
            encoding="utf-8",
        )

    def run_triage(self, vault, root, ids, vectors, judge, **kwargs):
        calls = []
        result = graph_groom.run_groom(
            vault,
            ids,
            vectors,
            root,
            apply=True,
            linker=lambda pairs: calls.extend(pairs),
            today=self.today,
            min_sim=1.1,
            llm_triage=True,
            judge=judge,
            **kwargs,
        )
        return result, calls

    def test_link_is_applied_with_llm_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            vault = self.make_vault(root, {"a": "personal", "b": "infra"})
            self.add_proposals(root, [("note:a", "note:b")])
            result, calls = self.run_triage(
                vault,
                root,
                ["note:a", "note:b"],
                [(1.0, 0.0), (0.8, 0.6)],
                lambda prompt: {
                    "verdict": "link",
                    "confidence": 0.91,
                    "reason": "same durable topic",
                },
            )
            report = Path(result["report"]).read_text(encoding="utf-8")
        self.assertEqual(result["triage_linked"], 1)
        self.assertEqual(len(calls), 1)
        self.assertEqual(
            graph_groom.pair_evidence(calls[0], self.today.isoformat()),
            "dream-groom 2026-07-30 llm-triage, sim=0.80, judge=0.91",
        )
        self.assertIn("### Triage", report)
        self.assertIn("[linked]", report)

    def test_reject_is_ledgered_and_excluded_forever(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            vault = self.make_vault(root, {"a": "personal", "b": "infra"})
            self.add_proposals(root, [("note:a", "note:b")])
            result, calls = self.run_triage(
                vault,
                root,
                ["note:a", "note:b"],
                [(1.0, 0.0), (0.8, 0.6)],
                lambda prompt: {
                    "verdict": "reject",
                    "confidence": 0.88,
                    "reason": "surface similarity only",
                },
            )
            ledger = root / "edge-proposals" / "2026-07-30.md"
            text = ledger.read_text(encoding="utf-8")
            _, candidates = graph_groom.collect_candidates(
                vault,
                ["note:a", "note:b"],
                [(1.0, 0.0), (0.8, 0.6)],
                root / "edge-proposals",
                root / "groom-reports" / "future.md",
                date(2026, 8, 30),
                min_sim=0.0,
                top_neighbors=5,
                proposals_days=365,
            )
        self.assertEqual(calls, [])
        self.assertEqual(result["triage_rejected"], 1)
        self.assertTrue(graph_groom.REJECTED_RE.search(text))
        self.assertEqual(candidates, [])

    def test_defer_stays_proposed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            vault = self.make_vault(root, {"a": "personal", "b": "infra"})
            self.add_proposals(root, [("note:a", "note:b")])
            result, calls = self.run_triage(
                vault,
                root,
                ["note:a", "note:b"],
                [(1.0, 0.0), (0.8, 0.6)],
                lambda prompt: {
                    "verdict": "defer",
                    "confidence": 0.95,
                    "reason": "insufficient context",
                },
            )
            report = Path(result["report"]).read_text(encoding="utf-8")
        self.assertEqual(calls, [])
        self.assertEqual(result["proposed"], 1)
        self.assertIn("[propose] `note:a` <-> `note:b`", report)
        self.assertIn("[deferred] `note:a` <-> `note:b`", report)

    def test_auto_pairs_have_priority_in_shared_max_links_cap(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            vault = self.make_vault(
                root,
                {"a": "personal", "b": "personal", "c": "personal", "d": "infra"},
            )
            self.add_proposals(
                root,
                [("note:a", "note:b"), ("note:c", "note:d")],
            )
            result, calls = self.run_triage(
                vault,
                root,
                ["note:a", "note:b", "note:c", "note:d"],
                [(1.0, 0.0), (1.0, 0.0), (0.99, 0.01), (0.98, 0.02)],
                lambda prompt: {
                    "verdict": "link",
                    "confidence": 0.99,
                    "reason": "strong conceptual relation",
                },
                max_links=1,
            )
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0].key, frozenset(("note:a", "note:b")))
        self.assertIsNone(calls[0].judge_confidence)
        self.assertEqual(result["auto_applied"], 1)
        self.assertEqual(result["triage_linked"], 0)
        self.assertEqual(result["triage_deferred"], 1)

    def test_invalid_json_is_deferred(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            vault = self.make_vault(root, {"a": "personal", "b": "infra"})
            self.add_proposals(root, [("note:a", "note:b")])
            result, calls = self.run_triage(
                vault,
                root,
                ["note:a", "note:b"],
                [(1.0, 0.0), (0.8, 0.6)],
                lambda prompt: "not-json",
            )
        self.assertEqual(calls, [])
        self.assertEqual(result["triage_deferred"], 1)
        self.assertEqual(result["proposed"], 1)

    def test_without_flag_judge_is_not_called(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            vault = self.make_vault(root, {"a": "personal", "b": "infra"})
            self.add_proposals(root, [("note:a", "note:b")])
            calls = []
            with mock.patch.object(graph_groom, "subprocess_judge") as subprocess_call:
                graph_groom.run_groom(
                    vault,
                    ["note:a", "note:b"],
                    [(1.0, 0.0), (0.8, 0.6)],
                    root,
                    apply=True,
                    linker=lambda pairs: None,
                    today=self.today,
                    min_sim=1.1,
                    judge=lambda prompt: calls.append(prompt),
                )
        self.assertEqual(calls, [])
        subprocess_call.assert_not_called()


if __name__ == "__main__":
    unittest.main()
