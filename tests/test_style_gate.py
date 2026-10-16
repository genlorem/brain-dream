"""Тесты ворот стиля tools/style_gate.py: подставной переписчик, без сети и модели."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "tools" / "style_gate.py"
# Подставной переписчик: срезает хвост «, а не …» до точки, отвечает как claude -p --output-format json.
FAKE = (
    "import json,re,sys; t=sys.stdin.read(); a=json.loads(t[t.index('Список:')+8:]);"
    "print(json.dumps({'result': json.dumps([re.sub(r',\\s+а\\s+не\\s+[^.]*', '', s) for s in a],"
    " ensure_ascii=False)}))"
)


class StyleGateTest(unittest.TestCase):
    def run_gate(self, mode: str, data: str, **env) -> tuple[str, list]:
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "gate.jsonl"
            full = os.environ | {
                "STYLE_GATE_REWRITER": f"{sys.executable} -c \"{FAKE}\"",
                "STYLE_GATE_LOG": str(log),
                "STYLE_GATE_SOURCE": "test",
            } | env
            out = subprocess.run([sys.executable, str(SCRIPT), mode], input=data, text=True,
                                 capture_output=True, env=full, check=True).stdout
            rows = [json.loads(x) for x in log.read_text().splitlines()] if log.exists() else []
        return out, rows

    def test_fields_rewrites_only_hit_sentence(self):
        obj = {"title": "Таймауты CDP", "insight": "Сбой вызван таймаутом, а не ошибкой кода. Повтор в 4 сессиях.",
               "why": "Чинится чисткой вкладок.", "ruled_out": "", "confidence": 0.8}
        out, rows = self.run_gate("fields", json.dumps(obj, ensure_ascii=False))
        got = json.loads(out)
        self.assertEqual(got["insight"], "Сбой вызван таймаутом. Повтор в 4 сессиях.")
        self.assertEqual(got["why"], obj["why"])
        self.assertEqual(got["confidence"], 0.8)
        self.assertEqual(rows[0]["hits"], 1)
        self.assertEqual(rows[0]["fixed"], 1)
        self.assertEqual(rows[0]["left"], 0)
        self.assertEqual(rows[0]["labels"], ["Y, а не X"])

    def test_clean_text_passes_without_call_and_log(self):
        text = "## 1. Заголовок\n\nСбой вызван таймаутом.\n"
        out, rows = self.run_gate("text", text, STYLE_GATE_REWRITER="false")
        self.assertEqual(out, text)
        self.assertEqual(rows, [])

    def test_text_keeps_code_fence_and_layout(self):
        text = "Суть: дело в кеше, а не в сети.\n\n```\nx, а не y\n```\nКонец.\n"
        out, _ = self.run_gate("text", text)
        self.assertEqual(out, "Суть: дело в кеше.\n\n```\nx, а не y\n```\nКонец.\n")

    def test_rewriter_failure_is_transparent(self):
        obj = {"title": "T", "insight": "Дело в кеше, а не в сети.", "why": "w"}
        raw = json.dumps(obj, ensure_ascii=False)
        out, rows = self.run_gate("fields", raw, STYLE_GATE_REWRITER="false")
        self.assertEqual(json.loads(out), obj)
        self.assertIsNotNone(rows[0]["error"])
        self.assertEqual(rows[0]["left"], 1)

    def test_off_switch(self):
        raw = json.dumps({"title": "T", "insight": "Дело в кеше, а не в сети.", "why": "w"}, ensure_ascii=False)
        out, rows = self.run_gate("fields", raw, STYLE_GATE_OFF="1")
        self.assertEqual(json.loads(out), json.loads(raw))
        self.assertEqual(rows, [])


if __name__ == "__main__":
    unittest.main()
