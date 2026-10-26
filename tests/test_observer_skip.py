"""tools/observer_skip.py: session-observer пропускает фоновые вызовы конвейера снов."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "tools"))
import observer_skip  # noqa: E402


def session(first: str, content_as_list: bool = False) -> str:
    content = [{"type": "text", "text": first}] if content_as_list else first
    rows = [{"type": "system", "subtype": "init"},
            {"type": "user", "message": {"role": "user", "content": content}},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "ок"}]}}]
    fh = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False, encoding="utf-8")
    fh.write("\n".join(json.dumps(r, ensure_ascii=False) for r in rows))
    fh.close()
    return fh.name


class ObserverSkipTest(unittest.TestCase):
    def test_pipeline_prompts_are_skipped(self):
        cases = {
            "Перепиши каждое предложение из списка по правилу стиля владельца. Правило: …": "style-gate",
            "ping": "ping",
            "Найди 10x-возможности: малые действия": "lens",
            "Найди неочевидные риски, слабые сигналы": "lens",
            "Найди, что застряло, заброшено": "lens",
            "Найди белые пятна: чего не хватает": "lens",
            "Ты синтезатор. Из этих кандидатов-инсайтов собери ТОП-10": "synth",
            "В контексте два разнородных блока: PRACTICE DIGEST — агрегат": "practice",
            "Открытые дела — эти проблемы уже известны и ведутся": "open-cases",
        }
        for text, rule in cases.items():
            self.assertEqual(observer_skip.pipeline_rule(session(text)), rule, text)
        self.assertEqual(observer_skip.pipeline_rule(session("ping", content_as_list=True)), "ping")

    def test_work_sessions_are_kept(self):
        for text in [
            "Ты — SWA-оператор отдела продаж бренда одежды SKVO",
            "Режим треда: qa. Разговор идёт по задаче VIP-7773.",
            "# Задача PA-5253: Все API. Песочница.",
            "Найди мне билеты в Астану",
            "ping сервер gena-vps и скажи, жив ли",
            "",
        ]:
            self.assertIsNone(observer_skip.pipeline_rule(session(text)), text)
        self.assertIsNone(observer_skip.pipeline_rule("/nonexistent.jsonl"))


if __name__ == "__main__":
    unittest.main()
