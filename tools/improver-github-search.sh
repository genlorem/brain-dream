#!/usr/bin/env bash
set -uo pipefail

# Поиск выполняется через gh в рантайме. Вся фильтрация и индекс seen сделаны
# в Python, чтобы запросы с кавычками и кириллицей не проходили через eval.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HYPOTHESES_FILE="${1:-}"
RUN_DATE="${2:-}"
CONFIG_FILE="${3:-$ROOT/config/improver.json}"

if [[ -z "$HYPOTHESES_FILE" || -z "$RUN_DATE" ]]; then
  printf '[]\n'
  exit 0
fi

python3 - "$HYPOTHESES_FILE" "$RUN_DATE" "$CONFIG_FILE" <<'PY' || printf '[]\n'
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from datetime import date, timedelta
from pathlib import Path
from typing import Any


def load_json(path: str, expected: type) -> Any:
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, expected):
        raise ValueError(f"{path}: unexpected JSON type")
    return value


def load_seen(path: Path) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return result
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and row.get("url"):
            result[str(row["url"])] = row
    return result


def license_name(raw: Any) -> str | None:
    if isinstance(raw, str):
        return raw or None
    if isinstance(raw, dict):
        return raw.get("key") or raw.get("name") or raw.get("spdxId")
    return None


def save_seen(path: Path, seen: dict[str, dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, tmp_name = tempfile.mkstemp(prefix=".seen.", dir=str(path.parent), text=True)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            for url in sorted(seen):
                stream.write(json.dumps(seen[url], ensure_ascii=False, sort_keys=True) + "\n")
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


try:
    hypotheses = load_json(sys.argv[1], list)
    run_date = date.fromisoformat(sys.argv[2])
    if run_date.isoformat() != sys.argv[2]:
        raise ValueError("run date must use YYYY-MM-DD")
    config = load_json(sys.argv[3], dict)
    github = config.get("github", {})
    paths = config.get("paths", {})
    min_stars = int(github.get("minStars", 5))
    max_age = int(github.get("maxAgeDays", 365))
    per_query = int(github.get("perQuery", 10))
    seen_path = Path(
        os.path.expanduser(os.environ.get("IMPROVER_SEEN_PATH", paths.get("seen", "")))
    )
    if not str(seen_path):
        raise ValueError("seen path is empty")
    gh_bin = os.environ.get("GH_BIN", "gh")
    cutoff = run_date - timedelta(days=max_age)
    seen = load_seen(seen_path)
    known_before = set(seen)
    emitted_this_run: set[str] = set()
    output: list[dict[str, Any]] = []

    for hypothesis in hypotheses:
        if not isinstance(hypothesis, dict) or not hypothesis.get("id"):
            continue
        candidates: dict[str, dict[str, Any]] = {}
        keywords = hypothesis.get("keywords", [])
        if isinstance(keywords, str):
            keywords = [keywords]
        for keyword in keywords:
            query = str(keyword).strip()
            if not query:
                continue
            command = [
                gh_bin,
                "search",
                "repos",
                query,
                "--sort=stars",
                f"--limit={per_query}",
                "--json",
                "fullName,stargazersCount,pushedAt,url,description,isArchived,license",
            ]
            try:
                process = subprocess.run(
                    command, check=False, capture_output=True, text=True, timeout=60
                )
                rows = json.loads(process.stdout) if process.returncode == 0 else []
            except (OSError, subprocess.TimeoutExpired, ValueError):
                rows = []
            if not isinstance(rows, list):
                continue
            for row in rows:
                if not isinstance(row, dict) or row.get("isArchived"):
                    continue
                try:
                    stars = int(row.get("stargazersCount", 0))
                    pushed = date.fromisoformat(str(row.get("pushedAt", ""))[:10])
                except (TypeError, ValueError):
                    continue
                # Популярный, но старый проект оставляем как reference.
                if stars < min_stars or (pushed < cutoff and stars <= 100):
                    continue
                url = str(row.get("url", "")).strip()
                if not url:
                    continue
                if url in seen:
                    seen[url]["last_seen"] = run_date.isoformat()
                else:
                    seen[url] = {
                        "url": url,
                        "first_seen": run_date.isoformat(),
                        "last_seen": run_date.isoformat(),
                    }
                if url in known_before or url in emitted_this_run:
                    continue
                emitted_this_run.add(url)
                candidates[url] = {
                    "fullName": str(row.get("fullName", "")),
                    "url": url,
                    "stars": stars,
                    "pushedAt": str(row.get("pushedAt", "")),
                    "license": license_name(row.get("license")),
                    "description": str(row.get("description") or ""),
                }
        ordered = sorted(candidates.values(), key=lambda row: (-row["stars"], row["url"]))
        output.append({"hypothesisId": str(hypothesis["id"]), "candidates": ordered})

    save_seen(seen_path, seen)
    print(json.dumps(output, ensure_ascii=False, sort_keys=True))
except Exception as exc:
    print(f"improver-github-search: {exc}", file=sys.stderr)
    print("[]")
PY
exit 0
