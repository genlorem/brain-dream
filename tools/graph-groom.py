#!/usr/bin/env python3
"""graph-groom — еженедельная гигиена графа Brain.

Ищет значимые ноды без рёбер, подбирает им embedding-соседей и разбирает
накопленный ledger edge-proposals. По умолчанию только пишет отчёт; --apply
создаёт безопасные auto-рёбра исключительно через MCP brain_link.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import math
import os
import re
import sqlite3
import struct
import sys
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Iterable, Mapping, Sequence

try:
    import numpy as np
except Exception:
    np = None


ENGINE = Path(os.environ.get("BRAIN_ENGINE", str(Path.home() / "brain" / "engine")))
DREAMS = Path(os.environ.get("DREAM_NODE_ROOT", str(Path.home() / "brain" / "dreams")))

KNOWLEDGE_TYPES = {
    "decision", "lesson", "note", "procedure", "project", "agent", "person", "repo",
}
DEFAULT_ROOTS = ":".join(
    str(Path.home() / "brain" / domain)
    for domain in ("personal", "infra", "marquiz", "travelmart", "skvo", "indie", "govori")
) + ":" + str(Path.home() / "life" / "brain")
PAIR_RE = re.compile(r"`(\S+)`\s*<->\s*`(\S+)`")
# из отчёта в дедуп идут только реально применённые пары: pending/propose
# должны оставаться кандидатами при повторном прогоне в тот же день
# (сценарий «утром dry-run → ревью → --apply»)
APPLIED_RE = re.compile(r"-\s*\[(?:applied|x)\]\s*`(\S+)`\s*<->\s*`(\S+)`")
DATE_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})")


@dataclass(frozen=True)
class Pair:
    """Кандидат на одно неориентированное relates-to ребро."""

    a: str
    b: str
    sim: float
    reason: str

    @property
    def key(self) -> frozenset[str]:
        return frozenset((self.a, self.b))


def load_vault():
    """Загрузить реальный федеративный vault движка."""
    os.environ.setdefault("TM_BRAIN_ROOTS", DEFAULT_ROOTS)
    sys.path.insert(0, str(ENGINE))
    import server  # noqa: E402

    return server.BrainVault(server.vault_roots())


def decode_vector(blob: bytes) -> tuple[float, ...]:
    """Декодировать sqlite BLOB little-endian float32 без numpy."""
    raw = bytes(blob)
    if len(raw) % 4:
        raise ValueError("embedding BLOB length is not divisible by 4")
    return struct.unpack(f"<{len(raw) // 4}f", raw)


def load_vectors(db_path: Path | None = None):
    """Прочитать id и embedding-вектора из index.db."""
    path = db_path or ENGINE / "index.db"
    with sqlite3.connect(str(path)) as con:
        rows = con.execute("SELECT id, vec FROM embeddings").fetchall()
    ids = [row[0] for row in rows]
    if np is None:
        return ids, [decode_vector(row[1]) for row in rows]
    vectors = [np.frombuffer(row[1], dtype=np.float32) for row in rows]
    return ids, np.vstack(vectors) if vectors else np.empty((0, 0), dtype=np.float32)


def linked_pairs(vault) -> set[frozenset[str]]:
    """Все существующие рёбра без учёта направления."""
    return {
        frozenset((edge.from_id, edge.to_id))
        for edge in vault._iter_edges()
    }


def find_orphans(vault) -> list[str]:
    """Значимые ноды вне dreams, не имеющие ни входящих, ни исходящих рёбер."""
    touched = {
        node_id
        for edge in vault._iter_edges()
        for node_id in (edge.from_id, edge.to_id)
    }
    return sorted(
        node_id
        for node_id, node in vault.index.items()
        if node.type in KNOWLEDGE_TYPES
        and node.root.name != "dreams"
        and node_id not in touched
    )


def vector_map(ids: Sequence[str], vectors) -> dict[str, Sequence[float]]:
    """Сопоставить строки матрицы их node id."""
    return {node_id: vectors[index] for index, node_id in enumerate(ids)}


def cosine(left: Sequence[float], right: Sequence[float]) -> float:
    """Косинус двух векторов; чистый Python — обязательный fallback."""
    if len(left) != len(right) or len(left) == 0:
        return 0.0
    if np is not None:
        a = np.asarray(left, dtype=float)
        b = np.asarray(right, dtype=float)
        denominator = float(np.linalg.norm(a) * np.linalg.norm(b))
        return float(a @ b / denominator) if denominator else 0.0
    dot = sum(float(a) * float(b) for a, b in zip(left, right))
    left_norm = math.sqrt(sum(float(item) ** 2 for item in left))
    right_norm = math.sqrt(sum(float(item) ** 2 for item in right))
    return dot / (left_norm * right_norm) if left_norm and right_norm else 0.0


def nearest(
    source: str,
    candidates: Sequence[str],
    vectors: Mapping[str, Sequence[float]],
    limit: int,
) -> list[tuple[str, float]]:
    """Топ embedding-соседей; при numpy считает весь ряд матрично."""
    source_vector = vectors.get(source)
    available = [node_id for node_id in candidates if node_id in vectors and node_id != source]
    if source_vector is None or not available or limit <= 0:
        return []
    if np is None:
        scored = [(node_id, cosine(source_vector, vectors[node_id])) for node_id in available]
    else:
        base = np.asarray(source_vector, dtype=float)
        matrix = np.vstack([np.asarray(vectors[node_id], dtype=float) for node_id in available])
        denominator = np.linalg.norm(matrix, axis=1) * np.linalg.norm(base)
        scores = np.divide(
            matrix @ base,
            denominator,
            out=np.zeros(len(available), dtype=float),
            where=denominator != 0,
        )
        scored = list(zip(available, (float(score) for score in scores)))
    return sorted(scored, key=lambda item: (-item[1], item[0]))[:limit]


def parse_pairs(path: Path) -> list[tuple[str, str]]:
    """Распарсить ledger/report пары, игнорируя нечитаемый файл."""
    try:
        return PAIR_RE.findall(path.read_text(encoding="utf-8"))
    except OSError:
        return []


def proposal_files(
    proposals_dir: Path,
    today: date,
    days: int | None,
) -> list[Path]:
    """Ledger-файлы с ISO-датой в имени, при необходимости только свежие."""
    paths: list[Path] = []
    cutoff = today - timedelta(days=max(0, days)) if days is not None else None
    for path in sorted(proposals_dir.glob("*.md")):
        match = DATE_RE.match(path.name)
        if not match:
            continue
        try:
            file_date = date.fromisoformat(match.group(1))
        except ValueError:
            continue
        if cutoff is None or file_date >= cutoff:
            paths.append(path)
    return paths


def ledger_pairs(
    proposals_dir: Path,
    today: date,
    days: int | None,
) -> list[tuple[str, str]]:
    """Уникальные пары из выбранной части общего ledger."""
    result: list[tuple[str, str]] = []
    seen: set[frozenset[str]] = set()
    for path in proposal_files(proposals_dir, today, days):
        for a, b in parse_pairs(path):
            key = frozenset((a, b))
            if a == b or key in seen:
                continue
            seen.add(key)
            result.append((a, b))
    return result


def orphan_candidates(
    vault,
    orphans: Sequence[str],
    vectors: Mapping[str, Sequence[float]],
    min_sim: float,
    top_neighbors: int,
) -> list[Pair]:
    """Подобрать соседей каждой сироте среди значимых нод вне dreams."""
    eligible = sorted(
        node_id
        for node_id, node in vault.index.items()
        if node.type in KNOWLEDGE_TYPES and node.root.name != "dreams"
    )
    result: list[Pair] = []
    seen: set[frozenset[str]] = set()
    for orphan in orphans:
        for neighbor, score in nearest(orphan, eligible, vectors, top_neighbors):
            pair = Pair(orphan, neighbor, score, "orphan")
            if score < min_sim or pair.key in seen:
                continue
            seen.add(pair.key)
            result.append(pair)
    return result


def triage_candidates(
    pairs: Iterable[tuple[str, str]],
    vectors: Mapping[str, Sequence[float]],
) -> list[Pair]:
    """Пересчитать similarity накопленных edge-proposals."""
    result: list[Pair] = []
    for a, b in pairs:
        score = cosine(vectors[a], vectors[b]) if a in vectors and b in vectors else 0.0
        result.append(Pair(a, b, score, "proposal-triage"))
    return result


def collect_candidates(
    vault,
    ids: Sequence[str],
    vectors,
    proposals_dir: Path,
    report_path: Path,
    today: date,
    min_sim: float,
    top_neighbors: int,
    proposals_days: int,
) -> tuple[list[str], list[Pair]]:
    """Собрать и дедуплицировать orphan + triage кандидатов."""
    by_id = vector_map(ids, vectors)
    orphans = find_orphans(vault)
    candidates = orphan_candidates(vault, orphans, by_id, min_sim, top_neighbors)
    candidates += triage_candidates(
        ledger_pairs(proposals_dir, today, proposals_days),
        by_id,
    )
    try:
        report_applied = APPLIED_RE.findall(report_path.read_text(encoding="utf-8"))
    except OSError:
        report_applied = []
    skip = linked_pairs(vault) | {frozenset(pair) for pair in report_applied}
    result: list[Pair] = []
    for pair in candidates:
        if pair.key in skip or len(pair.key) != 2:
            continue
        skip.add(pair.key)
        result.append(pair)
    return orphans, result


def is_auto(pair: Pair, vault, auto_sim: float) -> bool:
    """Проверить строгие условия автоматической линковки."""
    left = vault.index.get(pair.a)
    right = vault.index.get(pair.b)
    return (
        math.isfinite(pair.sim)
        and pair.sim >= auto_sim
        and left is not None
        and right is not None
        and left.type in KNOWLEDGE_TYPES
        and right.type in KNOWLEDGE_TYPES
        and left.root.name == right.root.name
    )


def classify(
    candidates: Iterable[Pair],
    vault,
    auto_sim: float,
) -> tuple[list[Pair], list[Pair]]:
    """Разделить пары на auto и propose."""
    auto, proposed = [], []
    for pair in candidates:
        (auto if is_auto(pair, vault, auto_sim) else proposed).append(pair)
    auto.sort(key=lambda pair: (-pair.sim, pair.a, pair.b))
    proposed.sort(key=lambda pair: (-pair.sim, pair.a, pair.b))
    return auto, proposed


def apply_pairs(pairs: Sequence[Pair], today: str) -> None:
    """Создать auto-рёбра через один MCP-сеанс; fastmcp импортируется лениво."""
    from fastmcp import Client

    async def _apply() -> None:
        url = os.environ.get("BRAIN_MCP_URL", "http://localhost:8787/mcp")
        async with Client(url) as client:
            for pair in pairs:
                await client.call_tool(
                    "brain_link",
                    {
                        "src_id": pair.a,
                        "rel": "relates-to",
                        "to_id": pair.b,
                        "evidence": (
                            f"dream-groom {today} auto, sim={pair.sim:.2f}, "
                            f"reason={pair.reason}"
                        ),
                    },
                )

    asyncio.run(_apply())


def append_ledger(
    proposals_dir: Path,
    today: date,
    applied: Sequence[Pair],
    proposed: Sequence[Pair],
) -> None:
    """Записать применённые auto и новые propose в сегодняшний общий ledger."""
    out = proposals_dir / f"{today.isoformat()}.md"
    today_seen = {frozenset(pair) for pair in parse_pairs(out)}
    all_seen = {
        frozenset(pair)
        for pair in ledger_pairs(proposals_dir, today, None)
    }
    additions: list[tuple[str, Pair]] = []
    for pair in applied:
        if pair.key not in today_seen:
            additions.append(("x", pair))
            today_seen.add(pair.key)
    for pair in proposed:
        if pair.key not in all_seen and pair.key not in today_seen:
            additions.append((" ", pair))
            all_seen.add(pair.key)
            today_seen.add(pair.key)
    if not additions:
        return
    proposals_dir.mkdir(parents=True, exist_ok=True)
    lines = []
    if not out.exists():
        lines = [
            f"# Edge proposals — {today.isoformat()}",
            "",
            "Источник: dream-groom (embedding-близость, без LLM).",
            "",
        ]
    for mark, pair in additions:
        lines.append(
            f"- [{mark}] `{pair.a}` <-> `{pair.b}` — sim {pair.sim:.2f}, "
            f"reason={pair.reason}"
        )
    with out.open("a", encoding="utf-8") as stream:
        stream.write("\n".join(lines) + "\n")


def write_report(
    path: Path,
    today: date,
    applied: Sequence[Pair],
    pending: Sequence[Pair],
    proposed: Sequence[Pair],
    dry_run: bool,
) -> None:
    """Дописать секцию прогона в дневной markdown-отчёт."""
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    if not path.exists():
        lines = [f"# Dream graph groom — {today.isoformat()}", ""]
    stamp = datetime.now(timezone.utc).strftime("%H:%M:%SZ")
    lines += [
        f"## Run {stamp} ({'dry-run' if dry_run else 'apply'})",
        "",
        "### Auto",
        "",
    ]
    for state, pairs in (("applied", applied), ("pending", pending)):
        for pair in pairs:
            lines.append(
                f"- [{state}] `{pair.a}` <-> `{pair.b}` — sim {pair.sim:.2f}, "
                f"reason={pair.reason}"
            )
    if not applied and not pending:
        lines.append("_Нет._")
    lines += ["", "### Propose", ""]
    for pair in proposed:
        lines.append(
            f"- [propose] `{pair.a}` <-> `{pair.b}` — sim {pair.sim:.2f}, "
            f"reason={pair.reason}"
        )
    if not proposed:
        lines.append("_Нет._")
    with path.open("a", encoding="utf-8") as stream:
        stream.write("\n".join(lines) + "\n")


def run_groom(
    vault,
    ids: Sequence[str],
    vectors,
    dreams_root: Path,
    *,
    apply: bool = False,
    linker: Callable[[Sequence[Pair]], None] | None = None,
    today: date | None = None,
    min_sim: float = 0.75,
    auto_sim: float = 0.90,
    max_links: int = 10,
    top_neighbors: int = 5,
    proposals_days: int = 30,
) -> dict[str, object]:
    """Выполнить акт с инъекцией vault, векторов и linker для тестов."""
    run_date = today or datetime.now(timezone.utc).date()
    proposals_dir = dreams_root / "edge-proposals"
    report_path = dreams_root / "groom-reports" / f"{run_date.isoformat()}.md"
    orphans, candidates = collect_candidates(
        vault,
        ids,
        vectors,
        proposals_dir,
        report_path,
        run_date,
        min_sim,
        max(0, top_neighbors),
        max(0, proposals_days),
    )
    auto, proposed = classify(candidates, vault, auto_sim)
    selected = auto[:max(0, max_links)] if apply else []
    pending = auto[len(selected):] if apply else auto
    if selected:
        active_linker = linker or (
            lambda pairs: apply_pairs(pairs, run_date.isoformat())
        )
        active_linker(selected)
    if apply:
        append_ledger(proposals_dir, run_date, selected, proposed)
    write_report(report_path, run_date, selected, pending, proposed, not apply)
    return {
        "orphans": len(orphans),
        "auto_applied": len(selected),
        "auto_pending": len(pending),
        "proposed": len(proposed),
        "report": str(report_path),
    }


def kill_switch_path() -> Path:
    """Путь строгого kill-switch этого акта."""
    return Path.home() / ".brain-dream" / "dream-groom-disabled"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--min-sim", type=float, default=0.75)
    parser.add_argument("--auto-sim", type=float, default=0.90)
    parser.add_argument("--max-links", type=int, default=10)
    parser.add_argument("--top-neighbors", type=int, default=5)
    parser.add_argument("--proposals-days", type=int, default=30)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Собрать реальные зависимости и вывести компактный JSON."""
    disabled = kill_switch_path()
    if disabled.exists():
        print(json.dumps({"error": "guard_refused", "guard": str(disabled)}))
        return 2
    args = build_parser().parse_args(argv)
    try:
        vault = load_vault()
        ids, vectors = load_vectors()
        result = run_groom(
            vault,
            ids,
            vectors,
            DREAMS,
            apply=args.apply,
            min_sim=args.min_sim,
            auto_sim=args.auto_sim,
            max_links=args.max_links,
            top_neighbors=args.top_neighbors,
            proposals_days=args.proposals_days,
        )
    except Exception as error:  # noqa: BLE001 — CLI возвращает контрактный exit 1
        print(
            json.dumps(
                {"level": "error", "error": f"{error.__class__.__name__}: {error}"},
                ensure_ascii=False,
            ),
            file=sys.stderr,
        )
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
