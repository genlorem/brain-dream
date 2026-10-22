"""Тесты журнала дел сна (tools/dream-cases.py) без сети, Jev и моделей эмбеддингов."""
from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

MODULE_PATH = Path(__file__).parents[1] / "tools" / "dream-cases.py"
SPEC = importlib.util.spec_from_file_location("dream_cases", MODULE_PATH)
dc = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = dc
SPEC.loader.exec_module(dc)

DREAM = """# Сон
## Синтез
# ТОП-10 инсайтов
## 1. Открыта панель Dokploy
**Суть:** порт 3000 без VPN.
**Действие:** закрыть порт.
**Источники:** note:x
## 2. ОСАГО просрочено
**Суть:** полис истёк.
**Действие:** продлить.
## Статистика
"""

TABLE = """## Синтез
| # | Заголовок | Суть | Почему | Действие | Источники |
|---|---|---|---|---|---|
| 1 | Дубль A | суть a | важно | сделать a | note:a |
"""


def vec(i, dim=8):
    v = np.zeros(dim, dtype=np.float32)
    v[i] = 1.0
    return v


def jev_answer(case="new", conf=0.9, known=0.1, actor="agent", sev="high", ver=0.9):
    return {"case": {"choice": case, "confidence": conf, "probabilities": {case: conf}},
            "known": {"noul": known},
            "actor": {"choice": actor, "probabilities": {actor: 0.9}},
            "severity": {"choice": sev, "probabilities": {sev: 0.9}},
            "verifiable": {"noul": ver}}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.dreams = root / "dreams"
        self.dreams.mkdir()
        self.state = root / "state"
        self.patches = [mock.patch.object(dc, "DREAMS", str(self.dreams)),
                        mock.patch.object(dc, "evidence", return_value=[]),
                        mock.patch.object(dc, "MODE", "shadow")]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in self.patches:
            p.stop()
        self.tmp.cleanup()

    def write(self, date, text=DREAM):
        (self.dreams / f"dream-{date}.md").write_text(text, encoding="utf-8")

    def events(self):
        return [json.loads(x) for x in (self.state / "events.jsonl").read_text().splitlines()]


class ParseTest(Base):
    def test_headers_format(self):
        self.write("2026-10-01")
        items = dc.parse_top10("2026-10-01")
        self.assertEqual([x["n"] for x in items], [1, 2])
        self.assertEqual(items[0]["action"], "закрыть порт.")
        self.assertEqual(items[0]["id"], "2026-10-01#1")

    def test_table_format(self):
        self.write("2026-10-01", TABLE)
        items = dc.parse_top10("2026-10-01")
        self.assertEqual(items[0]["title"], "Дубль A")
        self.assertEqual(items[0]["action"], "сделать a")

    def test_missing_file(self):
        self.assertEqual(dc.parse_top10("2099-01-01"), [])


class NightTest(Base):
    def run_night(self, date, answers, vecs):
        with mock.patch.object(dc, "jev", side_effect=answers), \
                mock.patch.object(dc, "embed", return_value=np.array(vecs)):
            return dc.run_night(str(self.state), date)

    def test_opens_cases_and_routes_by_actor(self):
        self.write("2026-10-01")
        m = self.run_night("2026-10-01", [jev_answer(actor="agent"), jev_answer(actor="owner")], [vec(0), vec(1)])
        self.assertEqual(m["open"], 2)
        kinds = {e["event"] for e in self.events()}
        self.assertTrue({"would_spawn", "would_card"} <= kinds)

    def test_known_before_is_dropped(self):
        self.write("2026-10-01")
        m = self.run_night("2026-10-01", [jev_answer(known=0.95), jev_answer()], [vec(0), vec(1)])
        self.assertEqual(m["known"], 1)
        self.assertEqual(m["open"], 1)

    def test_repeat_merges_into_open_case(self):
        self.write("2026-10-01")
        self.run_night("2026-10-01", [jev_answer(), jev_answer()], [vec(0), vec(1)])
        self.write("2026-10-02")
        m = self.run_night("2026-10-02", [jev_answer(case="C1"), jev_answer(case="new")], [vec(0), vec(2)])
        self.assertEqual(m["merge"], 1)
        merged = [e for e in self.events() if e["event"] == "merge"]
        self.assertEqual(merged[0]["case"], "case:2026-10-01-1")

    def test_jev_failure_falls_back_to_cosine(self):
        self.write("2026-10-01")
        self.run_night("2026-10-01", [jev_answer(), jev_answer()], [vec(0), vec(1)])
        self.write("2026-10-02")
        m = self.run_night("2026-10-02", [None, None], [vec(0), vec(3)])
        self.assertEqual(m["merge"], 1)
        self.assertEqual(m["open"], 1)
        self.assertEqual(m["watch"], 1)  # без Jev нет исполнителя — дело без адресата

    def test_unverifiable_goes_to_watch(self):
        self.write("2026-10-01")
        m = self.run_night("2026-10-01", [jev_answer(ver=0.2), jev_answer()], [vec(0), vec(1)])
        self.assertEqual(m["watch"], 1)

    def test_caps(self):
        text = "## Синтез\n" + "".join(f"## {i}. Т{i}\n**Суть:** с\n**Действие:** д\n" for i in range(1, 6))
        self.write("2026-10-01", text)
        with mock.patch.object(dc, "CAP_SPAWNS", 2):
            m = self.run_night("2026-10-01", [jev_answer(actor="agent")] * 5, [vec(i) for i in range(5)])
        self.assertEqual(m["would_spawn"], 2)
        self.assertEqual(m["capped_spawn"], 3)

    def test_second_run_same_date_is_noop(self):
        self.write("2026-10-01")
        self.run_night("2026-10-01", [jev_answer(), jev_answer()], [vec(0), vec(1)])
        self.assertIsNone(self.run_night("2026-10-01", [], [vec(0), vec(1)]))

    def test_close_by_later_evidence(self):
        self.write("2026-10-01")
        self.run_night("2026-10-01", [jev_answer(), jev_answer()], [vec(0), vec(1)])
        later = [{"id": "decision:x", "date": "2026-10-03", "title": "закрыли", "text": "порт закрыт"}]
        led = dc.Ledger(str(self.state))
        with mock.patch.object(dc, "evidence", return_value=later), \
                mock.patch.object(dc, "jev", return_value={"resolved": {"noul": 0.95}}):
            m = dc.verify_open(led, "2026-10-04")
        self.assertEqual(m["close"], 2)
        self.assertEqual(led.open_cases(), [])


class RouteTest(unittest.TestCase):
    def test_agent_only_when_confident(self):
        self.assertEqual(dc.pick_route({"actor": {"agent": 0.95, "owner": 0.05}}, 0.9), "agent")
        self.assertEqual(dc.pick_route({"actor": {"agent": 0.8, "owner": 0.2}}, 0.9), "owner")
        self.assertEqual(dc.pick_route({"actor": {"agent": 0.3, "watch": 0.6}}, 0.9), "watch")
        self.assertEqual(dc.pick_route({"actor": {"agent": 0.99}}, 0.2), "watch")
        self.assertEqual(dc.pick_route(None, None), "watch")

    def test_low_case_conf_opens_new_case(self):
        self.assertGreaterEqual(dc.T_CASE, 0.7)


class PhaseThreeTest(NightTest):
    """mode=on: карточка и спарк уходят наружу (заглушки), ответы и итоги закрывают дела."""

    def setUp(self):
        super().setUp()
        self.sent, self.spawned = [], []
        self.on = [mock.patch.object(dc, "MODE", "on"),
                   mock.patch.object(dc, "send_card",
                                     side_effect=lambda c, s, w: self.sent.append(c["id"]) or
                                     {"cardId": dc.card_id(c["id"]), "channel": "bridge"}),
                   mock.patch.object(dc, "spawn_spark",
                                     side_effect=lambda c, d: self.spawned.append(c["id"]) or
                                     {"session": "s", "result": "spawned"})]
        for p in self.on:
            p.start()

    def tearDown(self):
        for p in self.on:
            p.stop()
        super().tearDown()

    def answer(self, cid, choice, at="2026-10-02T08:00:00Z"):
        with open(self.state / "answers.jsonl", "a") as f:
            f.write(json.dumps({"cardId": dc.card_id(cid), "choice": choice, "at": at}) + "\n")

    def test_dispatch_card_and_spark(self):
        self.write("2026-10-01")
        self.run_night("2026-10-01", [jev_answer(actor="agent"), jev_answer(actor="owner")], [vec(0), vec(1)])
        self.assertEqual(self.spawned, ["case:2026-10-01-1"])
        self.assertEqual(self.sent, ["case:2026-10-01-2"])
        self.assertEqual({e["event"] for e in self.events()} & {"card", "spawn"}, {"card", "spawn"})

    def test_answers_close_drop_and_task(self):
        text = "## Синтез\n" + "".join(f"## {i}. Т{i}\n**Суть:** с\n**Действие:** д\n" for i in range(1, 4))
        self.write("2026-10-01", text)
        self.run_night("2026-10-01", [jev_answer(actor="owner")] * 3, [vec(i) for i in range(3)])
        self.answer("case:2026-10-01-1", "ack")
        self.answer("case:2026-10-01-2", "noise")
        self.answer("case:2026-10-01-3", "task")
        self.write("2026-10-02", "## Синтез\n")
        self.run_night("2026-10-02", [], [])
        led = dc.Ledger(str(self.state))
        st = {c["id"]: c["status"] for c in led.cases.values()}
        self.assertEqual(st["case:2026-10-01-1"], "closed")
        self.assertEqual(st["case:2026-10-01-2"], "dropped")
        self.assertIn("case:2026-10-01-3", self.spawned)  # «Сделай задачу» → спарк
        # повторная свёртка тех же нажатий ничего не добавляет
        n = len(self.events())
        dc.ingest_answers(led, "2026-10-03")
        self.assertEqual(len(self.events()), n)

    def test_outcome_pr_then_merged_closes(self):
        self.write("2026-10-01")
        self.run_night("2026-10-01", [jev_answer(actor="agent"), jev_answer(actor="agent")], [vec(0), vec(1)])
        led = dc.Ledger(str(self.state))
        self.assertEqual(dc.outcome(led, "case:2026-10-01-1", "pr", "https://github.com/genlorem/x/pull/1"),
                         "verifying")
        self.assertEqual(dc.outcome(led, "case:2026-10-01-2", "report", "нужен владелец"), "escalate")
        with mock.patch.object(dc, "pr_state", return_value="MERGED"):
            m = dc.verify_open(dc.Ledger(str(self.state)), "2026-10-02")
        self.assertEqual(m["close"], 1)
        led = dc.Ledger(str(self.state))
        self.assertEqual(led.cases["case:2026-10-01-1"]["status"], "closed")
        self.assertEqual(led.cases["case:2026-10-01-2"]["pending"], "owner")

    def test_no_second_spark_on_severity_up(self):
        self.write("2026-10-01")
        self.run_night("2026-10-01", [jev_answer(actor="agent", sev="medium"), jev_answer(actor="owner")],
                       [vec(0), vec(1)])
        self.write("2026-10-02")
        self.run_night("2026-10-02", [jev_answer(case="C1", sev="critical"), jev_answer(case="new")],
                       [vec(0), vec(2)])
        self.assertEqual(self.spawned.count("case:2026-10-01-1"), 1)


if __name__ == "__main__":
    unittest.main()
