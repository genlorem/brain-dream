#!/usr/bin/env python3
"""Дедуп ежедневной ленты dream-digest против недавних ночей перед публикацией в TG.

brain-dream варит каждую ночь изолированно: один и тот же вывод (например
«Prisma молча отменяет заявки») может всплыть несколько ночей подряд под чуть
разной формулировкой. Content-hash дедуп кандидатов (.insight-hashes.jsonl) это
не ловит — он работает на кандидатах ДО синтеза, а Claude в синтезе
переформулирует. Здесь — отдельный слой поверх готового топ-10: Gemini Flash
сверяет сегодняшние инсайты с теми, что реально показывались в ленте за
последние N дней, и гасит near-duplicate, чтобы лента читалась без самоповторов.

Отлично от:
  - longitudinal-meta  — месячные темы, а не дневные повторы;
  - brain-node-dedup   — ноды графа, а не лента;
  - finding-dedup.py   — finding-узлы session-observer (локальные эмбеддинги);
  - .insight-hashes    — exact content-hash кандидатов до синтеза.

Источник «что показывали» — реестр .digest-published.jsonl (по строке на
показанный инсайт: {date,title,gist}). Сегодняшние инсайты тащим из секции
«## Синтез» итогового dream-<date>.md — той же, что уходит в ленту.

Режим:
  render --synthesis <md> --registry <jsonl> --today YYYY-MM-DD
         [--days N] [--gemini <gemini.sh>] [--model flash] [--max-titles 10]

    stdout: нумерованный блок оставленных заголовков (+ футер про скрытые) —
            прямо в подпись Telegram. Пусто => вызывающий падает на свой
            extract_top_titles (fallback).
    stderr: одна строка-сводка status=... today=.. recent=.. suppressed=..
    side-effect: показанные (kept) инсайты дописываются в реестр; реестр
                 компактится до окна.

Fail-open железно: нет недавних / нет ключа / Gemini упал / парс не удался —
печатаем ВСЕ заголовки без подавления и всё равно пишем в реестр. Лента важнее
дедупа; подавляем только при уверенном вердикте.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import date, timedelta

DEFAULT_DAYS = 5
DEFAULT_MAX_TITLES = 10
GEMINI_TIMEOUT_S = 90

# Начало пункта топ-10. Claude пишет по-разному ночь к ночи:
#   «## #1 — Заголовок», «#### 1) Заголовок», «1. Заголовок», «## 1. Заголовок».
ITEM_RE = re.compile(r"^(?:#{1,6}\s*)?#?\s*(\d+)\s*[—–.):\-]\s*(.+?)\s*$")


def log(msg: str) -> None:
    print(msg, file=sys.stderr)


def strip_md(s: str) -> str:
    s = re.sub(r"\*\*([^*]*)\*\*", r"\1", s)
    s = re.sub(r"`([^`]*)`", r"\1", s)
    s = s.replace("**", "").replace("`", "")
    return s.strip()


def extract_synthesis(md_path: str) -> str:
    """Вернуть текст секции «## Синтез» (до следующего H2) из dream-<date>.md."""
    try:
        text = open(md_path, encoding="utf-8").read()
    except OSError:
        return ""
    lines = text.splitlines()
    out, inside = [], False
    for ln in lines:
        if re.match(r"^##\s+Синтез", ln):
            inside = True
            continue
        if inside and re.match(r"^##\s+\S", ln) and not re.match(r"^##\s*#?\s*\d", ln):
            break
        if inside:
            out.append(ln)
    return "\n".join(out)


def parse_insights(synthesis: str, max_titles: int) -> list[dict]:
    """[{idx,title,gist}] в порядке документа. gist = строки до следующего пункта."""
    lines = synthesis.splitlines()
    starts = []  # (line_no, title)
    for i, ln in enumerate(lines):
        # H1 «# ТОП-10 …» и заголовки-разделы не должны ловиться: требуем цифру
        # сразу после необязательных #/пробелов.
        m = ITEM_RE.match(ln)
        if not m:
            continue
        title = strip_md(m.group(2))
        if title:
            starts.append((i, title))
    insights = []
    for k, (line_no, title) in enumerate(starts):
        end = starts[k + 1][0] if k + 1 < len(starts) else len(lines)
        body = []
        for ln in lines[line_no + 1 : end]:
            t = strip_md(ln)
            if not t or t.startswith("---"):
                continue
            body.append(t)
        gist = " ".join(body)[:400]
        insights.append({"idx": len(insights) + 1, "title": title, "gist": gist})
        if len(insights) >= max_titles:
            break
    return insights


def load_recent(registry: str, today: str, days: int) -> list[dict]:
    """Записи реестра строго раньше today и не старше окна. date — YYYY-MM-DD,
    лексикографическое сравнение корректно."""
    if not os.path.exists(registry):
        return []
    try:
        cutoff = (date.fromisoformat(today) - timedelta(days=days)).isoformat()
    except ValueError:
        cutoff = "0000-00-00"
    rows = []
    with open(registry, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            d = r.get("date", "")
            if cutoff <= d < today:
                rows.append(r)
    return rows


def compact_and_append(registry: str, today: str, days: int, kept: list[dict]) -> None:
    """Дописать показанные инсайты и подрезать реестр до окна [today-days .. today]."""
    try:
        cutoff = (date.fromisoformat(today) - timedelta(days=days)).isoformat()
    except ValueError:
        cutoff = "0000-00-00"
    existing = []
    if os.path.exists(registry):
        with open(registry, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except json.JSONDecodeError:
                    continue
                # Старое окна выкидываем; сегодняшние перезапишем свежими kept.
                if r.get("date", "") >= cutoff and r.get("date", "") != today:
                    existing.append(r)
    for ins in kept:
        existing.append({"date": today, "title": ins["title"], "gist": ins.get("gist", "")})
    tmp = registry + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for r in existing:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.replace(tmp, registry)


def ask_gemini(gemini_sh: str, model: str, today: list[dict], recent: list[dict]) -> set[int]:
    """Вернуть множество idx сегодняшних инсайтов, которые Gemini счёл повтором.
    Любая осечка => пустое множество (fail-open, ничего не подавляем)."""
    instruction = (
        "Ты — дедупликатор ленты ежедневных инсайтов. Дано: СЕГОДНЯ — инсайты, "
        "которые выходят в ленту сегодня; НЕДАВНО — инсайты, уже показанные в "
        "прошлые ночи. Найди среди СЕГОДНЯ те, что являются near-duplicate уже "
        "показанного НЕДАВНО: та же мысль/тот же вывод другими словами. НЕ считай "
        "повтором просто общую тему или соседнюю проблему — только если суть и "
        "вывод по-настоящему совпадают. Верни СТРОГО JSON-массив без markdown, "
        "по объекту на каждый инсайт СЕГОДНЯ: "
        '[{"id": <int>, "duplicate": <true|false>, "of": "<ref недавнего или null>", '
        '"reason": "<коротко>"}]. id — это поле id из входа.'
    )
    payload = json.dumps(
        {
            "today": [{"id": t["idx"], "title": t["title"], "gist": t["gist"]} for t in today],
            "recent": [
                {"ref": r.get("date", "?"), "title": r.get("title", ""), "gist": r.get("gist", "")}
                for r in recent
            ],
        },
        ensure_ascii=False,
    )
    try:
        proc = subprocess.run(
            ["bash", gemini_sh, "-m", model, "stdin", instruction],
            input=payload,
            capture_output=True,
            text=True,
            timeout=GEMINI_TIMEOUT_S,
        )
    except (subprocess.TimeoutExpired, OSError) as e:
        log(f"digest-dedup gemini_error={type(e).__name__}")
        return set()
    if proc.returncode != 0 or not proc.stdout.strip():
        log(f"digest-dedup gemini_failed rc={proc.returncode} err={proc.stderr.strip()[:200]}")
        return set()
    verdicts = parse_verdicts(proc.stdout)
    if verdicts is None:
        log("digest-dedup parse_failed")
        return set()
    valid_ids = {t["idx"] for t in today}
    dup = set()
    for v in verdicts:
        try:
            vid = int(v.get("id"))
        except (TypeError, ValueError):
            continue
        if vid in valid_ids and bool(v.get("duplicate")):
            dup.add(vid)
    return dup


def parse_verdicts(raw: str):
    """Достать JSON-массив вердиктов из ответа Gemini (терпим к ```json-обёртке)."""
    s = raw.strip()
    s = re.sub(r"^```(?:json)?\s*", "", s)
    s = re.sub(r"\s*```$", "", s.strip())
    try:
        obj = json.loads(s)
        if isinstance(obj, list):
            return obj
    except json.JSONDecodeError:
        pass
    m = re.search(r"\[.*\]", raw, re.S)
    if m:
        try:
            obj = json.loads(m.group(0))
            if isinstance(obj, list):
                return obj
        except json.JSONDecodeError:
            return None
    return None


def render(args) -> int:
    synthesis = extract_synthesis(args.synthesis)
    insights = parse_insights(synthesis, args.max_titles)
    if not insights:
        log("digest-dedup status=no_insights")
        return 1  # вызывающий упадёт на свой extract_top_titles

    recent = load_recent(args.registry, args.today, args.days)
    dup: set[int] = set()
    status = "checked"

    if not recent:
        status = "no_recent"
    elif not gemini_ready(args.gemini):
        status = "no_gemini"
    else:
        dup = ask_gemini(args.gemini, args.model, insights, recent)
        if not dup:
            status = "checked_clean"

    kept = [ins for ins in insights if ins["idx"] not in dup]
    suppressed = len(insights) - len(kept)

    # Реестр пишем ВСЕГДА (даже fail-open): показанным считаем kept — повторы
    # уже якорятся своей старой записью, дубль в реестре не нужен.
    try:
        compact_and_append(args.registry, args.today, args.days, kept)
    except OSError as e:
        log(f"digest-dedup registry_write_failed={e}")

    out = []
    for n, ins in enumerate(kept, 1):
        out.append(f"{n}. {ins['title']}")
    if suppressed > 0:
        out.append(f"\n↩︎ {suppressed} скрыто как повтор недавних ночей")
    sys.stdout.write("\n".join(out) + "\n")

    log(
        f"digest-dedup status={status} today={len(insights)} "
        f"recent={len(recent)} suppressed={suppressed}"
    )
    return 0


def gemini_ready(gemini_sh: str) -> bool:
    if not gemini_sh or not os.path.exists(gemini_sh):
        return False
    # Бэкенд cli (OAuth) авторизуется через локальный gemini CLI — API-ключ не нужен.
    if os.environ.get("GEMINI_BACKEND") == "cli":
        return True
    if os.environ.get("GEMINI_API_KEY"):
        return True
    cfg = os.path.expanduser("~/.config/gemini/config.env")
    if os.path.exists(cfg):
        try:
            for ln in open(cfg, encoding="utf-8"):
                m = re.match(r"\s*GEMINI_API_KEY\s*=\s*(\S+)", ln)
                if m and m.group(1).strip("\"'"):
                    return True
        except OSError:
            return False
    return False


def main() -> None:
    ap = argparse.ArgumentParser(description="Дедуп ленты dream-digest против недавних ночей")
    sub = ap.add_subparsers(dest="mode", required=True)
    r = sub.add_parser("render")
    r.add_argument("--synthesis", required=True, help="dream-<date>.md с секцией ## Синтез")
    r.add_argument("--registry", required=True, help=".digest-published.jsonl")
    r.add_argument("--today", required=True, help="UTC-дата YYYY-MM-DD")
    r.add_argument("--days", type=int, default=DEFAULT_DAYS)
    r.add_argument("--gemini", default="", help="путь к gemini.sh")
    r.add_argument("--model", default="flash")
    r.add_argument("--max-titles", type=int, default=DEFAULT_MAX_TITLES)
    r.set_defaults(func=render)
    args = ap.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
