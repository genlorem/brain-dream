#!/usr/bin/env python3
"""Ворота стиля у записи: противопоставления «не X, а Y» и хедж-вставки в тексте конвейера.

Решение владельца 16.10.2026 (decision:ncf-style-by-audience-pipeline-skip-write-gate-ruled-out-2026-10-16):
Stop-хук no-contrast-framing пропускает фоновые `claude -p` (CC_AUDIENCE=pipeline), стиль того, что
становится знанием, проверяется здесь — перед записью кандидата и синтеза. Детектор общий с хуком
(~/.claude/hooks/ncf_patterns.py). Найденные предложения переписывает один короткий вызов модели
(по умолчанию haiku); остальной текст не трогается.

  style_gate.py fields   stdin: JSON-объект одной строкой → stdout: тот же объект с исправленными полями
  style_gate.py text     stdin: текст (Markdown) → stdout: исправленный текст

env: STYLE_GATE_FIELDS (title,insight,why,ruled_out), STYLE_GATE_REWRITER (команда, промпт в stdin,
ответ JSON claude -p), STYLE_GATE_LOG (~/.cache/session-manager/metrics/style-gate.jsonl),
STYLE_GATE_SOURCE (метка в лог), STYLE_GATE_OFF=1 — пропуск, NCF_PATTERNS_DIR (~/.claude/hooks).
Любой сбой — текст уходит как был, в лог пишется error: ворота ночь не роняют.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
import time

sys.path.insert(0, os.path.expanduser(os.environ.get("NCF_PATTERNS_DIR", "~/.claude/hooks")))
try:
    from ncf_patterns import find_plain  # noqa: E402
except ImportError:  # детектора нет — ворота прозрачны
    find_plain = None

FIELDS = [f for f in os.environ.get("STYLE_GATE_FIELDS", "title,insight,why,ruled_out").split(",") if f]
REWRITER = os.environ.get("STYLE_GATE_REWRITER",
                          "claude-pool --headless -- -p --model haiku --output-format json")
LOG_FILE = os.path.expanduser(os.environ.get("STYLE_GATE_LOG",
                                             "~/.cache/session-manager/metrics/style-gate.jsonl"))
TIMEOUT_S = 90
# Предложение: до .!? с пробелом или до перевода строки; разделители сохраняются для склейки.
SPLIT_RE = re.compile(r"((?<=[.!?…])[ \t]+|\n)")
FENCE_RE = re.compile(r"```.*?```", re.S)

PROMPT = """Перепиши каждое предложение из списка по правилу стиля владельца.
Правило: без противопоставлений «не X, а Y», «Y, а не X», «— Y, не X», «(не X)» и без вставок «стоит отметить», «важно понимать». Утверждение прямо. Если X важен читателю, дай его отдельным предложением с причиной.
Смысл, числа, имена и id сохрани, ничего нового не добавляй, Markdown-разметку сохрани.
Примеры:
«Сбой вызван таймаутом, а не ошибкой кода.» → «Сбой вызван таймаутом: запрос висел 30 с.»
«Это системная проблема, а не разовая опечатка.» → «Это системная проблема: повтор в 4 сессиях.»
Верни только JSON-массив строк той же длины и в том же порядке, без пояснений.
Список:
"""


def hits_in(text: str) -> list:
    return find_plain(FENCE_RE.sub(" ", text)) if find_plain and text else []


def split_keep(text: str) -> list:
    return SPLIT_RE.split(text)


def rewrite(sentences: list) -> list:
    """Один вызов модели на все предложения; ответ — массив той же длины."""
    payload = PROMPT + json.dumps(sentences, ensure_ascii=False)
    proc = subprocess.run(shlex.split(REWRITER), input=payload, capture_output=True, text=True,
                          timeout=TIMEOUT_S, check=False)
    out = proc.stdout.strip()
    try:
        out = json.loads(out).get("result", out)
    except (ValueError, AttributeError):
        pass
    m = re.search(r"\[.*\]", out or "", re.S)
    if not m:
        raise ValueError(f"rewriter: нет JSON-массива (rc={proc.returncode})")
    arr = json.loads(m.group(0))
    if not isinstance(arr, list) or len(arr) != len(sentences) or not all(isinstance(s, str) for s in arr):
        raise ValueError("rewriter: длина или тип ответа не совпали")
    return arr


def fix_texts(texts: dict, stat: dict) -> dict:
    """texts: имя → текст. Переписывает только предложения с попаданиями, одним вызовом на все."""
    parts = {k: split_keep(v) for k, v in texts.items()}
    targets = []  # (ключ, индекс части)
    for k, ps in parts.items():
        in_fence = False
        for i, p in enumerate(ps):
            if i % 2:  # разделитель
                continue
            if p.count("```") % 2:
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            h = hits_in(p)
            if h:
                targets.append((k, i))
                stat["labels"].extend(x["label"] for x in h)
    stat["hits"] = len(targets)
    if not targets:
        return texts
    t0 = time.monotonic()
    new = rewrite([parts[k][i] for k, i in targets])
    stat["rewriter_ms"] = int((time.monotonic() - t0) * 1000)
    for (k, i), s in zip(targets, new):
        if len(hits_in(s)) <= len(hits_in(parts[k][i])):
            parts[k][i] = s
            stat["fixed"] += 0 if hits_in(s) else 1
    stat["left"] = sum(1 for k, i in targets if hits_in(parts[k][i]))
    return {k: "".join(ps) for k, ps in parts.items()}


def log(rec: dict) -> None:
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except OSError:
        pass


def run(mode: str, raw: str) -> str:
    if os.environ.get("STYLE_GATE_OFF") == "1" or find_plain is None:
        return raw
    stat = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "mode": mode,
            "source": os.environ.get("STYLE_GATE_SOURCE", ""), "hits": 0, "fixed": 0, "left": 0,
            "labels": [], "error": None}
    try:
        if mode == "fields":
            obj = json.loads(raw)
            texts = {f: obj[f] for f in FIELDS if isinstance(obj.get(f), str) and obj[f]}
            fixed = fix_texts(texts, stat)
            obj.update(fixed)
            out = json.dumps(obj, ensure_ascii=False)
        else:
            out = fix_texts({"text": raw}, stat)["text"]
    except Exception as exc:  # noqa: BLE001 — ворота прозрачны при любом сбое
        stat["error"] = f"{type(exc).__name__}: {exc}"[:200]
        stat["left"] = stat["hits"]
        out = raw.rstrip("\n") if mode == "fields" else raw
    if stat["hits"] or stat["error"]:
        log(stat)
    return out


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode not in ("fields", "text"):
        print(__doc__, file=sys.stderr)
        return 2
    raw = sys.stdin.read()
    out = run(mode, raw.strip() if mode == "fields" else raw)
    sys.stdout.write(out if mode == "text" else out + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
