#!/usr/bin/env python3
"""Семантический дедуп finding-узлов session-observer (брат по дешёвому захвату).

Exact content-hash не ловит переформулировки Gemini (одна мысль → разные слова →
разные хэши → дубли). Здесь — косинус по эмбеддингам (brain semantic.embed,
мультиязычный MiniLM) поверх него.

Режимы:
  clean <nodes_dir> [--threshold T] [--apply]
      Кластеризует существующие finding-*.md, в каждом кластере оставляет узел с
      макс. confidence (тай-брейк — больше hits/новее), остальные помечает дублями.
      По умолчанию dry-run (только отчёт). --apply → git rm дублей в репо узла.

  check <nodes_dir> [--threshold T]
      stdin: по строке `<hash>\\t<text>`. Для каждого кандидата печатает
      `<hash>\\t(NEW|DUP)\\t<matched_id|->\\t<score>`. Агент пропускает DUP.

Порог по умолчанию 0.86 (paraphrase-MiniLM: near-dup переформулировки ~0.85-0.95).
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import subprocess
import sys

import numpy as np

sys.path.insert(0, "/home/gen/brain/engine")
import semantic  # noqa: E402 — fastembed MiniLM, normalized vectors

DEFAULT_THRESHOLD = 0.86


def parse_node(path: str) -> dict:
    text = open(path, encoding="utf-8").read()
    title = re.search(r"^title:\s*['\"]?(.+?)['\"]?\s*$", text, re.M)
    conf = re.search(r"^confidence:\s*([\d.]+)", text, re.M)
    chash = re.search(r"^content_hash:\s*(\w+)", text, re.M)
    nid = re.search(r"^id:\s*(\S+)", text, re.M)
    parts = text.split("---", 2)
    body = parts[2].strip() if len(parts) > 2 else text
    body = re.sub(r"^##\s+.*$", "", body, count=1, flags=re.M).strip()
    return {
        "path": path,
        "id": nid.group(1) if nid else os.path.basename(path),
        "title": title.group(1).strip() if title else "",
        "conf": float(conf.group(1)) if conf else 0.6,
        "hash": chash.group(1) if chash else "",
        "text": ((title.group(1) if title else "") + ". " + body)[:1500],
    }


def cluster(nodes: list[dict], vecs: np.ndarray, threshold: float):
    """Жадная кластеризация: проходим по confidence desc, каждый узел либо
    становится представителем нового кластера, либо дублём ближайшего представителя."""
    order = sorted(range(len(nodes)), key=lambda i: (-nodes[i]["conf"], nodes[i]["path"]))
    reps: list[int] = []
    dup_of: dict[int, tuple[int, float]] = {}
    for i in order:
        best_s, best_j = -1.0, None
        for j in reps:
            s = float(vecs[i] @ vecs[j])
            if s > best_s:
                best_s, best_j = s, j
        if best_j is not None and best_s >= threshold:
            dup_of[i] = (best_j, best_s)
        else:
            reps.append(i)
    return reps, dup_of


def cmd_clean(args) -> None:
    files = sorted(glob.glob(os.path.join(args.nodes_dir, "finding-*.md")))
    if not files:
        print("нет finding-*.md", file=sys.stderr)
        return
    nodes = [parse_node(f) for f in files]
    vecs = semantic.embed([n["text"] for n in nodes])
    reps, dup_of = cluster(nodes, vecs, args.threshold)

    dups = sorted(dup_of.items(), key=lambda kv: -kv[1][1])
    print(f"всего: {len(nodes)} | кластеров (оставляем): {len(reps)} | дублей (удаляем): {len(dups)}")
    print(f"порог cosine: {args.threshold}\n")
    for i, (rep_j, score) in dups:
        print(f"  DUP {score:.3f}  «{nodes[i]['title'][:55]}»")
        print(f"        → {nodes[rep_j]['title'][:55]}")
    if not args.apply:
        print("\n(dry-run; --apply чтобы git rm дубли)")
        return
    repo = _git_root(args.nodes_dir)
    removed = [nodes[i]["path"] for i in dup_of]
    for p in removed:
        subprocess.run(["git", "-C", repo, "rm", "-q", os.path.relpath(p, repo)], check=False)
    if removed:
        subprocess.run(
            ["git", "-C", repo, "-c", "user.name=session-observer",
             "-c", "user.email=session-observer@local", "commit", "-q",
             "-m", f"session-observer: semantic-dedup — удалено {len(removed)} дублей finding-узлов"],
            check=False,
        )
    print(f"\n✓ удалено {len(removed)} дублей, закоммичено")


def cmd_check(args) -> None:
    cands = []
    for line in sys.stdin:
        line = line.rstrip("\n")
        if not line:
            continue
        h, _, txt = line.partition("\t")
        cands.append((h, txt[:1500]))
    if not cands:
        return
    files = sorted(glob.glob(os.path.join(args.nodes_dir, "finding-*.md")))
    existing = [parse_node(f) for f in files]
    if existing:
        ex_vecs = semantic.embed([n["text"] for n in existing])
    cand_vecs = semantic.embed([t for _, t in cands])
    for k, (h, _) in enumerate(cands):
        if not existing:
            print(f"{h}\tNEW\t-\t0.0")
            continue
        sims = ex_vecs @ cand_vecs[k]
        j = int(np.argmax(sims))
        s = float(sims[j])
        if s >= args.threshold:
            print(f"{h}\tDUP\t{existing[j]['id']}\t{s:.3f}")
        else:
            print(f"{h}\tNEW\t-\t{s:.3f}")


def _git_root(path: str) -> str:
    out = subprocess.run(
        ["git", "-C", path, "rev-parse", "--show-toplevel"],
        capture_output=True, text=True,
    )
    return out.stdout.strip() or path


def main() -> None:
    ap = argparse.ArgumentParser(description="Семантический дедуп finding-узлов")
    sub = ap.add_subparsers(dest="mode", required=True)
    c = sub.add_parser("clean")
    c.add_argument("nodes_dir")
    c.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    c.add_argument("--apply", action="store_true")
    c.set_defaults(func=cmd_clean)
    k = sub.add_parser("check")
    k.add_argument("nodes_dir")
    k.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    k.set_defaults(func=cmd_check)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
