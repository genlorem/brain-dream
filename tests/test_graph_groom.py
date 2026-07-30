"""Тесты graph-groom без numpy, движка и сети."""
from __future__ import annotations

import importlib.util
import io
import sqlite3
import struct
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).parents[1] / "tools" / "graph-groom.py"
SPEC = importlib.util.spec_from_file_location("graph_groom", MODULE_PATH)
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


@dataclass
class Edge:
    from_id: str
    to_id: str


class FakeVault:
    def __init__(self, nodes, edges=()):
        self.index = nodes
        self.edges = list(edges)

    def _iter_edges(self):
        return iter(self.edges)


def node(kind="note", domain="personal"):
    return Node(kind, Root(domain))


class GraphGroomTests(unittest.TestCase):
    def setUp(self):
        self.numpy = graph_groom.np
        graph_groom.np = None
        self.today = date(2026, 7, 30)

    def tearDown(self):
        graph_groom.np = self.numpy

    def test_orphan_detected_but_incoming_node_is_not(self):
        vault = FakeVault(
            {"note:orphan": node(), "note:linked": node(), "note:source": node()},
            [Edge("note:source", "note:linked")],
        )
        self.assertEqual(graph_groom.find_orphans(vault), ["note:orphan"])

    def test_min_similarity_threshold(self):
        vault = FakeVault({"note:a": node(), "note:b": node(), "note:c": node()})
        vectors = {"note:a": (1.0, 0.0), "note:b": (0.8, 0.6), "note:c": (0.0, 1.0)}
        pairs = graph_groom.orphan_candidates(
            vault, ["note:a"], vectors, min_sim=0.75, top_neighbors=5,
        )
        self.assertEqual([(pair.b, round(pair.sim, 2)) for pair in pairs], [("note:b", 0.8)])

    def test_cross_domain_is_propose(self):
        vault = FakeVault({"note:a": node(domain="personal"), "note:b": node(domain="infra")})
        pair = graph_groom.Pair("note:a", "note:b", 0.99, "orphan")
        auto, proposed = graph_groom.classify([pair], vault, 0.90)
        self.assertEqual(auto, [])
        self.assertEqual(proposed, [pair])

    def test_max_links_caps_fake_linker_calls(self):
        vault = FakeVault(
            {"note:a": node(), "note:b": node(), "note:c": node()},
        )
        calls = []
        with tempfile.TemporaryDirectory() as tmp:
            result = graph_groom.run_groom(
                vault,
                ["note:a", "note:b", "note:c"],
                [(1.0, 0.0), (0.99, 0.01), (0.98, 0.02)],
                Path(tmp),
                apply=True,
                linker=lambda pairs: calls.extend(pairs),
                today=self.today,
                min_sim=0.90,
                auto_sim=0.90,
                max_links=1,
                top_neighbors=2,
            )
        self.assertEqual(len(calls), 1)
        self.assertEqual(result["auto_applied"], 1)
        self.assertGreater(result["auto_pending"], 0)

    def test_dry_run_does_not_call_linker(self):
        vault = FakeVault({"note:a": node(), "note:b": node()})
        calls = []
        with tempfile.TemporaryDirectory() as tmp:
            result = graph_groom.run_groom(
                vault,
                ["note:a", "note:b"],
                [(1.0, 0.0), (1.0, 0.0)],
                Path(tmp),
                linker=lambda pairs: calls.extend(pairs),
                today=self.today,
            )
        self.assertEqual(calls, [])
        self.assertEqual(result["auto_applied"], 0)
        self.assertEqual(result["auto_pending"], 1)

    def test_kill_switch_returns_exit_two_before_loading(self):
        with tempfile.TemporaryDirectory() as tmp:
            disabled = Path(tmp) / "dream-groom-disabled"
            disabled.touch()
            output = io.StringIO()
            with mock.patch.object(graph_groom, "kill_switch_path", return_value=disabled), \
                    mock.patch.object(graph_groom, "load_vault") as load, \
                    redirect_stdout(output):
                rc = graph_groom.main([])
        self.assertEqual(rc, 2)
        load.assert_not_called()
        self.assertEqual(__import__("json").loads(output.getvalue())["error"], "guard_refused")

    def test_ledger_parsing_age_and_linked_dedup(self):
        vault = FakeVault(
            {"note:a": node(), "note:b": node(), "note:c": node()},
            [Edge("note:a", "note:b")],
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            proposals = root / "edge-proposals"
            proposals.mkdir()
            (proposals / "2026-07-30.md").write_text(
                "- [ ] `note:a` <-> `note:b`\n- [ ] `note:a` <-> `note:c`\n",
                encoding="utf-8",
            )
            (proposals / "2026-06-01.md").write_text(
                "- [ ] `note:b` <-> `note:c`\n", encoding="utf-8",
            )
            orphans, pairs = graph_groom.collect_candidates(
                vault,
                ["note:a", "note:b", "note:c"],
                [(1.0, 0.0), (1.0, 0.0), (0.0, 1.0)],
                proposals,
                root / "groom-reports" / "2026-07-30.md",
                self.today,
                min_sim=1.1,
                top_neighbors=5,
                proposals_days=30,
            )
        self.assertEqual(orphans, ["note:c"])
        self.assertEqual([(pair.a, pair.b) for pair in pairs], [("note:a", "note:c")])

    def test_report_is_created_and_contains_pair(self):
        vault = FakeVault({"note:a": node(), "note:b": node(domain="infra")})
        with tempfile.TemporaryDirectory() as tmp:
            result = graph_groom.run_groom(
                vault,
                ["note:a", "note:b"],
                [(1.0, 0.0), (1.0, 0.0)],
                Path(tmp),
                today=self.today,
            )
            report = Path(result["report"])
            text = report.read_text(encoding="utf-8")
        self.assertTrue(report.name == "2026-07-30.md")
        self.assertIn("`note:a` <-> `note:b`", text)
        self.assertIn("reason=orphan", text)

    def test_float32_blob_decoding_and_sqlite_loading(self):
        blob = struct.pack("<3f", 1.25, -2.5, 3.0)
        self.assertEqual(graph_groom.decode_vector(blob), (1.25, -2.5, 3.0))
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / "index.db"
            with sqlite3.connect(db) as con:
                con.execute("CREATE TABLE embeddings (id TEXT, vec BLOB)")
                con.execute("INSERT INTO embeddings VALUES (?, ?)", ("note:a", blob))
            ids, vectors = graph_groom.load_vectors(db)
        self.assertEqual(ids, ["note:a"])
        self.assertEqual(vectors, [(1.25, -2.5, 3.0)])


if __name__ == "__main__":
    unittest.main()
