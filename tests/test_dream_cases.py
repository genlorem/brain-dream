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


if __name__ == "__main__":
    unittest.main()
