#!/usr/bin/env python3
"""Пропустить ли сессию в session-observer: фоновый вызов самого конвейера снов.

Разбор 26.10.2026: из 1 372 находок за 20–26.10 699 (51 %) извлечены из фоновых
`claude -p` в ~/.claude/projects/-home-genlorem/, и около 85 % из них — вызовы
конвейера: ворота стиля, линзы сна, синтезатор, ping. Отсюда же крупнейшие
кластеры дублей находок. Рабочие фоновые вызовы (оператор SKVO, треды задач,
ревьюер) не трогаем: решение только по первому промпту сессии.

Выход: 0 — пропустить (печатает метку правила), 1 — разбирать.
"""
from __future__ import annotations

import json
import re
import sys

# Префиксы первого промпта (после схлопывания пробелов). Новая ступень конвейера —
# строкой сюда; проверка — tests/test_observer_skip.py.
PIPELINE_PROMPTS = [
    ("style-gate", r"Перепиши каждое предложение из списка по правилу стиля владельца"),
    ("ping", r"ping$"),
    ("lens", r"Найди(?: (?:10x-возможности|неочевидные риски|неочевидное важное открытие|противоречия между нодами"
             r"|переносимые аналогии|проблемы и болевые точки|белые пятна)|, что застряло)"),
    ("synth", r"Ты синтезатор\."),
    ("practice", r"В контексте два разнородных блока: PRACTICE DIGEST"),
    ("open-cases", r"Открытые дела — эти проблемы уже известны"),
]
_RULES = [(name, re.compile(pattern)) for name, pattern in PIPELINE_PROMPTS]


def first_prompt(path: str, max_lines: int = 200) -> str:
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return ""
    with fh:
        for i, line in enumerate(fh):
            if i >= max_lines:
                break
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if obj.get("type") != "user":
                continue
            content = (obj.get("message") or {}).get("content")
            if isinstance(content, list):
                content = " ".join(b.get("text", "") for b in content if isinstance(b, dict))
            if isinstance(content, str) and content.strip():
                return " ".join(content.split())
    return ""


def pipeline_rule(path: str) -> str | None:
    text = first_prompt(path)
    for name, rx in _RULES:
        if rx.match(text):
            return name
    return None


if __name__ == "__main__":
    rule = pipeline_rule(sys.argv[1]) if len(sys.argv) > 1 else None
    if rule:
        print(rule)
        sys.exit(0)
    sys.exit(1)
