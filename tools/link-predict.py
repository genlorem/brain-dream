#!/usr/bin/env python3
"""link-predict — еженедельные предложения недостающих рёбер графа Brain.

Кандидаты — чистая embedding-близость: косинус по уже посчитанным векторам
из engine index.db (модель не грузится, LLM не вызывается — ноль стоимости).
Пара «близкие по смыслу, но не связанные ребром» → предложение связи.

Инварианты (см. proposals/seed-2026-05-30-edge-proposer.md, вариант A):
- source-домены read-only: пишем ТОЛЬКО в dreams (edge-proposals/<date>.md);
- git-tracked writeback: proposal уходит коммитом в репо dreams;
- human-in-the-loop: связи применяет человек/сессия через brain_link,
  инструмент сам ничего не линкует.

Usage:
  link-predict.py [--threshold 0.60] [--top 30] [--apply-dir DIR] [--dry-run]

Env:
  BRAIN_ENGINE     путь к engine (дефолт ~/brain/engine) — index.db + server.py
  TM_BRAIN_ROOTS   корни vault (дефолт — как у brain-mcp демона)
  DREAM_NODE_ROOT  домен dreams (дефолт ~/brain/dreams) — сюда пишем proposal

Дедуп между запусками: пары из прежних edge-proposals/*.md не предлагаются
повторно (маркер `<id> <-> <id>` парсится из старых файлов).
"""
from __future__ import annotations

import argparse
import os
import re
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

ENGINE = Path(os.environ.get("BRAIN_ENGINE", str(Path.home() / "brain" / "engine")))
DREAMS = Path(os.environ.get("DREAM_NODE_ROOT", str(Path.home() / "brain" / "dreams")))

# Осмысленные знания — где недостающая связь ценна. Структурные авто-ноды
# (message/commit/deploy/event/comment) дают шумные пары и исключены.
KNOWLEDGE_TYPES = {"decision", "lesson", "note", "procedure", "project", "agent", "person", "repo"}

DEFAULT_ROOTS = ":".join(
    str(Path.home() / "brain" / d)
    for d in ("personal", "infra", "marquiz", "travelmart", "skvo", "indie", "govori")
) + ":" + str(Path.home() / "life" / "brain")


def load_vault():
    os.environ.setdefault("TM_BRAIN_ROOTS", DEFAULT_ROOTS)
    sys.path.insert(0, str(ENGINE))
    import server  # noqa: E402

    return server.BrainVault(server.vault_roots())


def load_vectors() -> tuple[list[str], np.ndarray]:
    con = sqlite3.connect(str(ENGINE / "index.db"))
    rows = con.execute("SELECT id, vec FROM embeddings").fetchall()
    con.close()
    ids = [r[0] for r in rows]
    mat = np.vstack([np.frombuffer(r[1], dtype=np.float32) for r in rows])
    return ids, mat


def already_proposed(proposals_dir: Path) -> set[frozenset]:
    seen: set[frozenset] = set()
    for path in proposals_dir.glob("*.md"):
        for a, b in re.findall(r"`(\S+)` <-> `(\S+)`", path.read_text(encoding="utf-8")):
            seen.add(frozenset((a, b)))
    return seen


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--threshold", type=float, default=0.60)
    ap.add_argument("--top", type=int, default=30)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    vault = load_vault()
    ids, mat = load_vectors()

    keep = [i for i, nid in enumerate(ids) if (n := vault.index.get(nid)) and n.type in KNOWLEDGE_TYPES and n.root.name != "dreams"]
    ids = [ids[i] for i in keep]
    mat = mat[keep]
    if len(ids) < 2:
        print("too few knowledge nodes with embeddings; nothing to do")
        return 0

    linked: set[frozenset] = set()
    neighbor_ids: dict[str, set] = {}
    for edge in vault._iter_edges():
        linked.add(frozenset((edge.from_id, edge.to_id)))
        neighbor_ids.setdefault(edge.from_id, set()).add(edge.to_id)
        neighbor_ids.setdefault(edge.to_id, set()).add(edge.from_id)

    proposals_dir = DREAMS / "edge-proposals"
    proposals_dir.mkdir(parents=True, exist_ok=True)
    skip = already_proposed(proposals_dir) | linked

    sims = mat @ mat.T
    n = len(ids)
    iu = np.triu_indices(n, k=1)
    flat = sims[iu]
    order = np.argsort(-flat)

    pairs = []
    for idx in order:
        score = float(flat[idx])
        if score < args.threshold or len(pairs) >= args.top:
            break
        a, b = ids[iu[0][idx]], ids[iu[1][idx]]
        if frozenset((a, b)) in skip:
            continue
        common = len(neighbor_ids.get(a, set()) & neighbor_ids.get(b, set()))
        pairs.append((score, a, b, common))

    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    if not pairs:
        print(f"no new pairs above {args.threshold}")
        return 0

    lines = [
        f"# Edge proposals — {today}",
        "",
        "Источник: link-predict (embedding-близость, без LLM). Применять руками:",
        "`mcp__brain__brain_link(src_id, rel, to_id)` — rel выбрать по смыслу",
        "(relates-to по умолчанию; uses/justified-by/extends/same-as если точнее).",
        "Пара не нужна — просто оставить (повторно не предложится).",
        "",
    ]
    for score, a, b, common in pairs:
        ta = vault.index[a].title
        tb = vault.index[b].title
        lines.append(f"- [ ] `{a}` <-> `{b}` — sim {score:.2f}, общих соседей: {common}")
        lines.append(f"      «{ta}» / «{tb}»")
    body = "\n".join(lines) + "\n"

    out = proposals_dir / f"{today}.md"
    if args.dry_run:
        print(body)
        return 0
    out.write_text(body, encoding="utf-8")
    print(f"wrote {out} ({len(pairs)} pairs)")

    subprocess.run(["git", "-C", str(DREAMS), "add", str(out)], check=False)
    subprocess.run(
        ["git", "-C", str(DREAMS), "-c", "user.name=link-predict",
         "-c", "user.email=link-predict@brain", "commit", "-q",
         "-m", f"link-predict: {len(pairs)} edge-предложений за {today}"],
        check=False,
    )

    # Telegram best-effort (как у introspector: digest-bot)
    env_file = Path.home() / ".config" / "digest-bot" / "env"
    if env_file.exists():
        cfg = dict(
            line.strip().split("=", 1)
            for line in env_file.read_text().splitlines()
            if "=" in line and not line.strip().startswith("#")
        )
        token = cfg.get("DIGEST_BOT_TOKEN", "").strip('"')
        chat = cfg.get("DIGEST_ADMIN_CHAT_ID", "").strip('"')
        if token and chat:
            text = f"🕸 link-predict: {len(pairs)} предложений связей в графе.\n📄 {out}"
            subprocess.run(
                ["curl", "-fs", "-X", "POST",
                 f"https://api.telegram.org/bot{token}/sendMessage",
                 "--data-urlencode", f"chat_id={chat}",
                 "--data-urlencode", f"text={text}", "-o", "/dev/null"],
                check=False,
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
