#!/usr/bin/env python3
"""Собирает детерминированный markdown-дайджест и идемпотентный ledger."""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from datetime import date
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "config" / "improver.json"


def load_json(path: str, expected: type) -> Any:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return expected()
    return value if isinstance(value, expected) else expected()


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def load_ledger(path: Path) -> tuple[list[dict[str, Any]], set[str]]:
    rows: list[dict[str, Any]] = []
    seen: set[str] = set()
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return rows, seen
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if not isinstance(row, dict):
            continue
        key = str(row.get("hypothesisId", ""))
        if not key or key in seen:
            continue
        seen.add(key)
        rows.append(row)
    return rows, seen


def candidate_index(rows: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    result: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        if isinstance(row, dict) and row.get("hypothesisId"):
            values = row.get("candidates", [])
            result[str(row["hypothesisId"])] = values if isinstance(values, list) else []
    return result


def object_index(rows: list[dict[str, Any]], key: str) -> dict[str, dict[str, Any]]:
    return {
        str(row[key]): row
        for row in rows
        if isinstance(row, dict) and row.get(key)
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--date", required=True)
    parser.add_argument("--config", default=str(DEFAULT_CONFIG))
    parser.add_argument("--signals", required=True)
    parser.add_argument("--hypotheses", required=True)
    parser.add_argument("--candidates", required=True)
    parser.add_argument("--verdicts", required=True)
    parser.add_argument("--actions")
    args = parser.parse_args()
    if date.fromisoformat(args.date).isoformat() != args.date:
        raise ValueError("date must use YYYY-MM-DD")

    config = load_json(args.config, dict)
    paths = config.get("paths", {}) if isinstance(config.get("paths"), dict) else {}
    reports_dir = Path(str(paths.get("reportsDir", "~/brain/improver/reports"))).expanduser()
    ledger_path = Path(
        str(paths.get("ledger", "~/brain/improver/improver-ledger.ndjson"))
    ).expanduser()

    signals = load_json(args.signals, list)
    hypotheses = load_json(args.hypotheses, list)
    candidates = candidate_index(load_json(args.candidates, list))
    verdicts = object_index(load_json(args.verdicts, list), "hypothesisId")
    actions = object_index(load_json(args.actions, list), "hypothesisId") if args.actions else {}

    lines = [f"# Brain Improver — {args.date}", ""]
    lines.extend(["## Болевые сигналы", ""])
    if signals:
        for signal in signals:
            rank = float(signal.get("severity", 0)) * int(signal.get("count", 0))
            evidence = json.dumps(signal.get("evidence", {}), ensure_ascii=False, sort_keys=True)
            lines.append(
                f"- `{signal.get('id', '?')}` — {signal.get('kind', '?')}; "
                f"severity={signal.get('severity', 0)}, count={signal.get('count', 0)}, "
                f"rank={rank:.4f}. `{evidence}`"
            )
    else:
        lines.append("- Сигналов нет.")

    lines.extend(["", "## Гипотезы и кандидаты", ""])
    if not hypotheses:
        lines.append("- Гипотез нет.")
    for hypothesis in hypotheses:
        hid = str(hypothesis.get("id", "?"))
        lines.append(
            f"### `{hid}` — {hypothesis.get('kind', '?')}\n\n"
            f"{hypothesis.get('hypothesis', '')}"
        )
        signal = hypothesis.get("signal")
        if signal:
            lines.append(f"\nСигнал: `{signal}`.")
        rows = candidates.get(hid, [])
        if rows:
            lines.extend(["", "Кандидаты:", ""])
            for candidate in rows:
                license_name = candidate.get("license") or "license unknown"
                lines.append(
                    f"- [{candidate.get('fullName') or candidate.get('url')}]"
                    f"({candidate.get('url')}) — ★{candidate.get('stars', 0)}, "
                    f"{license_name}, pushed `{candidate.get('pushedAt', '')}`"
                )
        else:
            lines.extend(["", "Кандидаты: нет новых."])

        verdict = verdicts.get(hid, {})
        verdict_name = verdict.get("verdict", "reject")
        lines.extend(
            [
                "",
                f"Вердикт: **{verdict_name}** → `{verdict.get('target', 'evaluation unavailable')}`.",
                "",
                str(verdict.get("rationale", "Оценка недоступна; fail-open отказ.")),
            ]
        )
        action = actions.get(hid)
        if action:
            lines.extend(["", f"Действие: {action.get('summary', action.get('action', ''))}."])
            if action.get("proposal"):
                lines.append(f"Proposal: `{action['proposal']}`.")
            if action.get("draftPr"):
                lines.append(f"Draft PR description: `{action['draftPr']}`.")

    report_path = reports_dir / f"improver-{args.date}.md"
    atomic_write(report_path, "\n".join(lines).rstrip() + "\n")

    ledger_rows, seen_ids = load_ledger(ledger_path)
    for hypothesis in hypotheses:
        hid = str(hypothesis.get("id", "")).strip()
        if not hid or hid in seen_ids:
            continue
        verdict = verdicts.get(
            hid,
            {
                "hypothesisId": hid,
                "verdict": "reject",
                "target": "evaluation unavailable",
                "rationale": "fail-open",
                "bestCandidate": None,
            },
        )
        ledger_rows.append(
            {
                "date": args.date,
                "hypothesisId": hid,
                "hypothesis": hypothesis,
                "verdict": verdict,
            }
        )
        seen_ids.add(hid)
    ledger_body = "".join(
        json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in ledger_rows
    )
    atomic_write(ledger_path, ledger_body)
    print(report_path)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # отчёт не должен ронять недельный cron
        print(f"improver-report: {exc}", file=sys.stderr)
        raise SystemExit(0)
