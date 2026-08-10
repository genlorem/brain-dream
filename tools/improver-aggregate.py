#!/usr/bin/env python3
"""Детерминированно сворачивает аналитику Brain в ранжированные болевые сигналы."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "config" / "improver.json"


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def read_ndjson(path: str) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    try:
        with Path(path).expanduser().open(encoding="utf-8") as stream:
            for line in stream:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict):
                    result.append(row)
    except OSError:
        pass
    return result


def text_field(row: dict[str, Any], *names: str) -> str:
    return " ".join(str(row.get(name, "")) for name in names).strip().lower()


def signal_id(kind: str, key: str) -> str:
    digest = hashlib.sha1(f"{kind}\0{key}".encode()).hexdigest()[:10]
    return f"{kind}-{digest}"


def make_signal(
    kind: str, key: str, severity: float, evidence: dict[str, Any], count: int
) -> dict[str, Any]:
    return {
        "id": signal_id(kind, key),
        "kind": kind,
        "severity": round(float(severity), 4),
        "evidence": evidence,
        "count": int(count),
    }


def node_key(row: dict[str, Any]) -> tuple[str, ...]:
    raw = row.get("node_ids", [])
    if isinstance(raw, str):
        raw = [raw]
    if not isinstance(raw, list):
        return ()
    return tuple(sorted({str(item) for item in raw if str(item).strip()}))


def coverage_gaps(rows: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    clusters: Counter[tuple[str, ...]] = Counter()
    examples: dict[tuple[str, ...], list[str]] = defaultdict(list)
    for row in rows:
        marker = text_field(row, "surface", "stage", "outcome", "event", "kind")
        is_gap = (
            "judge-gap" in marker
            or "judge_gap" in marker
            or ("coverage" in marker and ("gap" in marker or "miss" in marker))
        )
        nodes = node_key(row)
        if not is_gap or not nodes:
            continue
        clusters[nodes] += 1
        if len(examples[nodes]) < 3:
            examples[nodes].append(str(row.get("sid", "")))

    result = []
    for nodes, count in clusters.items():
        if count < 2:
            continue
        severity = min(5.0, 1.0 + math.log2(count))
        result.append(
            make_signal(
                "coverage-judge-gap",
                "\0".join(nodes),
                severity,
                {"node_ids": list(nodes), "sample_sids": examples[nodes]},
                count,
            )
        )
    return result


def row_keywords(row: dict[str, Any]) -> list[str]:
    values: list[Any] = []
    for name in ("keyword", "matched_keyword", "query"):
        if row.get(name):
            values.append(row[name])
    raw = row.get("keywords", [])
    if isinstance(raw, list):
        values.extend(raw)
    elif raw:
        values.append(raw)
    return sorted({str(value).strip().lower() for value in values if str(value).strip()})


def nudge_noise(rows: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    totals: Counter[str] = Counter()
    declined: Counter[str] = Counter()
    for row in rows:
        marker = text_field(row, "surface", "stage", "event", "kind")
        if "nudge" not in marker:
            continue
        keys = row_keywords(row)
        outcome = text_field(row, "outcome", "decision", "action")
        for keyword in keys:
            totals[keyword] += 1
            if any(word in outcome for word in ("declin", "reject", "dismiss", "ignore")):
                declined[keyword] += 1

    result = []
    for keyword, count in totals.items():
        declined_count = declined[keyword]
        rate = declined_count / count
        if count < 2 or rate < 0.5:
            continue
        result.append(
            make_signal(
                "nudge-declined",
                keyword,
                rate * 5.0,
                {
                    "keyword": keyword,
                    "declined": declined_count,
                    "total": count,
                    "decline_rate": round(rate, 4),
                },
                declined_count,
            )
        )
    return result


def percentile_nearest_rank(values: list[float], percentile: float) -> float:
    ordered = sorted(values)
    index = max(0, math.ceil(percentile * len(ordered)) - 1)
    return ordered[index]


def latency_hotspots(rows: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[str, list[float]] = defaultdict(list)
    for row in rows:
        marker = text_field(row, "surface", "stage", "event", "kind")
        if "judge" not in marker:
            continue
        try:
            elapsed = float(row.get("ms", 0))
        except (TypeError, ValueError):
            continue
        if elapsed < 0:
            continue
        key = f"{row.get('surface', 'unknown')}:{row.get('stage', 'judge')}"
        groups[key].append(elapsed)

    result = []
    for key, values in groups.items():
        if len(values) < 2:
            continue
        p90 = percentile_nearest_rank(values, 0.9)
        if p90 < 500:
            continue
        result.append(
            make_signal(
                "judge-latency",
                key,
                min(5.0, p90 / 1000.0),
                {
                    "surface_stage": key,
                    "p90_ms": round(p90, 2),
                    "max_ms": round(max(values), 2),
                },
                len(values),
            )
        )
    return result


def is_stagnant(row: dict[str, Any]) -> bool:
    marker = text_field(row, "stage", "outcome")
    return "no_match" in marker or "no-match" in marker or any(
        part.startswith("skip-") or part.startswith("skip_") for part in marker.split()
    )


def stagnation(rows: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        groups[str(row.get("surface", "unknown"))].append(row)

    result = []
    for surface, events in groups.items():
        ordered = sorted(
            enumerate(events), key=lambda item: (str(item[1].get("ts", "")), item[0])
        )
        if len(ordered) < 4:
            continue
        split = len(ordered) // 2
        older = [row for _, row in ordered[:split]]
        newer = [row for _, row in ordered[split:]]
        old_rate = sum(is_stagnant(row) for row in older) / len(older)
        new_count = sum(is_stagnant(row) for row in newer)
        new_rate = new_count / len(newer)
        if new_count < 2 or new_rate < 0.5 or new_rate <= old_rate:
            continue
        stages = Counter(
            str(row.get("stage", row.get("outcome", "unknown")))
            for row in newer
            if is_stagnant(row)
        )
        severity = min(5.0, new_rate * (1.0 + 2.0 * (new_rate - old_rate)))
        result.append(
            make_signal(
                "stagnation",
                surface,
                severity,
                {
                    "surface": surface,
                    "older_rate": round(old_rate, 4),
                    "newer_rate": round(new_rate, 4),
                    "newer_stages": dict(sorted(stages.items())),
                },
                new_count,
            )
        )
    return result


def tuner_regressions(
    histories: dict[str, list[dict[str, Any]]]
) -> list[dict[str, Any]]:
    """Поднимает повторные rollback/guard-срабатывания тюнеров отдельным сигналом."""
    result = []
    for source, rows in histories.items():
        rollbacks = []
        for row in rows:
            guard = row.get("guardActions", [])
            guard_text = json.dumps(guard, ensure_ascii=False, sort_keys=True)
            marker = (
                text_field(row, "outcome", "action", "status", "rationale")
                + " "
                + guard_text.lower()
            )
            if any(word in marker for word in ("rollback", "rolled_back", "revert", "regression")):
                rollbacks.append(row)
        if not rollbacks:
            continue
        result.append(
            make_signal(
                "tuner-rollback",
                source,
                min(5.0, 2.0 + math.log2(len(rollbacks))),
                {
                    "source": source,
                    "history_events": len(rows),
                    "rollback_events": len(rollbacks),
                    "sample_rationales": [
                        str(row.get("rationale", "")) for row in rollbacks[:3]
                    ],
                },
                len(rollbacks),
            )
        )
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default=str(DEFAULT_CONFIG))
    parser.add_argument("--effectiveness")
    parser.add_argument("--nudge-tuner")
    parser.add_argument("--coverage-tuner")
    parser.add_argument("--outcome")
    args = parser.parse_args()

    config = read_json(Path(args.config))
    paths = config.get("paths", {}) if isinstance(config.get("paths"), dict) else {}
    effectiveness = args.effectiveness or paths.get("effectiveness", "")
    rows = read_ndjson(str(effectiveness)) if effectiveness else []
    histories = {
        "nudge-tuner": read_ndjson(
            str(args.nudge_tuner or paths.get("nudgeTuner", ""))
        ),
        "coverage-tuner": read_ndjson(
            str(args.coverage_tuner or paths.get("coverageTuner", ""))
        ),
        "outcome-watch": read_ndjson(str(args.outcome or paths.get("outcome", ""))),
    }

    signals = (
        coverage_gaps(rows)
        + nudge_noise(rows)
        + latency_hotspots(rows)
        + stagnation(rows)
        + tuner_regressions(histories)
    )
    signals.sort(
        key=lambda item: (
            -(float(item["severity"]) * int(item["count"])),
            item["kind"],
            item["id"],
        )
    )
    print(json.dumps(signals, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # fail-open для недельного cron
        print(f"improver-aggregate: {exc}", file=sys.stderr)
        print("[]")
        raise SystemExit(0)
