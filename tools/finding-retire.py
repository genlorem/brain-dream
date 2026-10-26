#!/usr/bin/env python3
"""Срок жизни находок session-observer в ~/brain/dreams/nodes.

Разбор 26.10.2026 (note:brain-search-fast-latency-fix-2026-10-26 и соседи): 13 224
находки, открывали из них 242 (1,8 %), при этом находки занимают 16 % мест выдачи
brain_search и 27 % подмешивания brain-catchup, а каждый файл vault — цена обхода.

Находка уходит в архив (git mv в <repo>/archive/findings/<ГГГГ-ММ>/ — вне nodes/,
движок Brain её больше не видит, история и файл остаются), если ВСЁ сразу:
  * id `finding:*`, observed_at старше --days (дефолт 60);
  * своих links нет;
  * ни один другой узел vault не упоминает её id (рёбра и текст);
  * её ни разу не открывали (kind=click в ~/.claude/analytics/brain-clicks.ndjson).

По умолчанию dry-run (только отчёт). --apply — git mv + коммит. Возврат находки:
git mv обратно в nodes/ (или git revert коммита).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import yaml

ID_RE = re.compile(r"finding:[0-9a-f]{8,}")
DEFAULT_ROOTS = [str(p) for p in sorted(Path.home().glob("brain/*/nodes"))] + [str(Path.home() / "life/brain/nodes")]
DEFAULT_CLICKS = str(Path.home() / ".claude/analytics/brain-clicks.ndjson")


def frontmatter(text: str) -> dict:
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end < 0:
        return {}
    try:
        data = yaml.safe_load(text[3:end]) or {}
    except yaml.YAMLError:
        return {}
    return data if isinstance(data, dict) else {}


def parse_ts(value) -> dt.datetime | None:
    if isinstance(value, dt.datetime):
        return value if value.tzinfo else value.replace(tzinfo=dt.timezone.utc)
    if isinstance(value, dt.date):
        return dt.datetime(value.year, value.month, value.day, tzinfo=dt.timezone.utc)
    if isinstance(value, str) and value:
        try:
            out = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
        return out if out.tzinfo else out.replace(tzinfo=dt.timezone.utc)
    return None


def clicked_ids(path: str) -> set[str]:
    out: set[str] = set()
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return out
    with fh:
        for line in fh:
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get("kind") == "click" and isinstance(row.get("id"), str):
                out.add(row["id"])
    return out


def referenced_ids(roots: list[str]) -> dict[str, set[str]]:
    """id находки → файлы, где она упомянута (рёбра links и текст)."""
    refs: dict[str, set[str]] = {}
    for root in roots:
        for dirpath, _dirs, files in os.walk(root):
            for name in files:
                if not name.endswith(".md"):
                    continue
                path = os.path.join(dirpath, name)
                try:
                    text = open(path, encoding="utf-8", errors="replace").read()
                except OSError:
                    continue
                for found in set(ID_RE.findall(text)):
                    refs.setdefault(found, set()).add(os.path.realpath(path))
    return refs


def candidates(nodes_dir: str, days: int, roots: list[str], clicks: str, now: dt.datetime) -> tuple[list[dict], dict]:
    cutoff = now - dt.timedelta(days=days)
    opened = clicked_ids(clicks)
    refs = referenced_ids(roots)
    stats = {"findings": 0, "young": 0, "own_links": 0, "referenced": 0, "opened": 0, "no_date": 0}
    out = []
    for name in sorted(os.listdir(nodes_dir)):
        if not (name.startswith("finding") and name.endswith(".md")):
            continue
        path = os.path.join(nodes_dir, name)
        try:
            meta = frontmatter(open(path, encoding="utf-8", errors="replace").read())
        except OSError:
            continue
        node_id = meta.get("id")
        if not isinstance(node_id, str) or not node_id.startswith("finding:"):
            continue
        stats["findings"] += 1
        observed = parse_ts(meta.get("observed_at"))
        if observed is None:
            stats["no_date"] += 1
            continue
        if observed > cutoff:
            stats["young"] += 1
            continue
        if meta.get("links"):
            stats["own_links"] += 1
            continue
        if refs.get(node_id, set()) - {os.path.realpath(path)}:
            stats["referenced"] += 1
            continue
        if node_id in opened:
            stats["opened"] += 1
            continue
        out.append({"id": node_id, "path": path, "observed": observed})
    stats["retire"] = len(out)
    return out, stats


def git_root(path: str) -> str:
    return subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"],
                          capture_output=True, text=True, check=True).stdout.strip()


def apply(items: list[dict], nodes_dir: str, days: int) -> int:
    repo = git_root(nodes_dir)
    moved = 0
    for item in items:
        dest_dir = Path(repo) / "archive" / "findings" / item["observed"].strftime("%Y-%m")
        dest_dir.mkdir(parents=True, exist_ok=True)
        src = os.path.relpath(item["path"], repo)
        dst = os.path.relpath(dest_dir / os.path.basename(item["path"]), repo)
        if subprocess.run(["git", "-C", repo, "mv", "-k", src, dst]).returncode == 0 and os.path.exists(Path(repo) / dst):
            moved += 1
    if moved:
        subprocess.run(["git", "-C", repo, "-c", "user.name=finding-retire", "-c", "user.email=finding-retire@local",
                        "commit", "-q", "-m",
                        f"finding-retire: {moved} находок старше {days} дней без ссылок и открытий → archive/findings"],
                       check=False)
    return moved


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("nodes_dir")
    ap.add_argument("--days", type=int, default=60)
    ap.add_argument("--roots", nargs="*", default=DEFAULT_ROOTS)
    ap.add_argument("--clicks", default=DEFAULT_CLICKS)
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()
    now = dt.datetime.now(dt.timezone.utc)
    items, stats = candidates(args.nodes_dir, args.days, args.roots, args.clicks, now)
    stats["moved"] = apply(items, args.nodes_dir, args.days) if args.apply else 0
    print(json.dumps({"ts": now.isoformat(timespec="seconds"), "days": args.days,
                      "apply": args.apply, **stats}, ensure_ascii=False))


if __name__ == "__main__":
    sys.exit(main())
