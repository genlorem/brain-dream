#!/usr/bin/env python3
"""dream-promote — продвигает инсайт из dream-ноды в полноценную ноду Brain.

Сон сам по себе read-only: он наблюдает и репортит, но его выводы не попадают
в рабочий граф проектов. Этот инструмент закрывает разрыв «сон заметил» →
«мозг этим пользуется»: берёт один инсайт из синтезированного топ-10 дайджеста
и заводит из него decision/lesson/note/procedure-ноду в нужном домене Brain,
автоматически линкуя её на источники инсайта и на сам сон (derived-from).

Адресация — по человеко-читаемому «дата#номер» (как в дайджесте), а НЕ по
content-hash: hash считается на стадии кандидатов, а синтез их переупорядочивает,
надёжного соответствия hash↔блок нет.

Usage:
  dream-promote.py [DATE] N [опции]   промоутнуть инсайт #N (последнего сна, если DATE опущен)
  dream-promote.py [DATE]             показать пронумерованный топ-10 (picker)
  dream-promote.py list              показать журнал уже промоутнутых
  dream-promote.py help

Опции:
  --type {lesson,decision,note,procedure}  тип ноды (по умолчанию lesson)
  --domain DOM                             домен Brain (по умолчанию выводится из источников инсайта)
  --dry-run                                показать, что было бы записано, ничего не писать
  --yes                                    не спрашивать подтверждения

Линза инсайта — это находка/грабли, поэтому дефолтный тип — lesson
(см. глобальное правило: неочевидные находки/грабли → lesson). Если инсайт
по сути — принятое архитектурное/процессное решение, ставь --type decision.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

BRAIN_ROOT = Path(os.environ.get("BRAIN_ROOT", str(Path.home() / "brain")))
DREAMS_DIR = BRAIN_ROOT / "dreams"
PROMOTED_LOG = Path(os.environ.get("DREAM_PROMOTED", str(DREAMS_DIR / ".promoted.jsonl")))

TYPE_DIR = {
    "lesson": "lessons",
    "decision": "decisions",
    "note": "notes",
    "procedure": "procedures",
}

# Префиксы id, которые считаем валидными ссылками-источниками внутри блока.
NODE_ID_RE = re.compile(
    r"`((?:decision|lesson|note|procedure|repo|task|thread|project|person|comment|event|sprint|pr|deploy|message|agent):[^`\s]+)`"
)
# Заголовок блока инсайта: и `## 1. Title`, и `## #1 · Title`.
BLOCK_HEAD_RE = re.compile(r"^##\s+#?(\d+)\s*[.·]\s*(.+?)\s*$")
META_LINE_RE = re.compile(r"^\*\*(Источники|Метка)\.?\*\*")
MARKER_ONLY_RE = re.compile(r"^\*\*(non-obvious|obvious|wow)\*\*(\s*\|.*)?$")

_TRANSLIT = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e",
    "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
    "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
    "ф": "f", "х": "h", "ц": "c", "ч": "ch", "ш": "sh", "щ": "sch", "ъ": "",
    "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
}


def die(msg, code=1):
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(code)


def slugify(title):
    out = []
    for ch in title.lower():
        if ch in _TRANSLIT:
            out.append(_TRANSLIT[ch])
        elif ch.isalnum() and ch.isascii():
            out.append(ch)
        else:
            out.append("-")
    slug = re.sub(r"-+", "-", "".join(out)).strip("-")
    return slug[:50].strip("-")


def latest_dream_date():
    dates = sorted(
        m.group(1)
        for p in DREAMS_DIR.glob("dream-*.md")
        if (m := re.match(r"dream-(\d{4}-\d{2}-\d{2})\.md$", p.name))
    )
    if not dates:
        die(f"в {DREAMS_DIR} нет dream-нод")
    return dates[-1]


def parse_blocks(text):
    """Разбивает синтез-секцию dream-ноды на блоки инсайтов.

    Возвращает список dict: {n, title, body, sources}. Блок заканчивается
    на следующем `## ...` (включая нецифровые — «Связи», «Статистика»).
    """
    lines = text.splitlines()
    blocks = []
    cur = None
    for line in lines:
        head = BLOCK_HEAD_RE.match(line)
        if head:
            if cur:
                blocks.append(cur)
            cur = {"n": int(head.group(1)), "title": head.group(2), "lines": []}
            continue
        if line.startswith("## "):  # нецифровой заголовок — конец топ-10
            if cur:
                blocks.append(cur)
                cur = None
            continue
        if cur is not None:
            cur["lines"].append(line)
    if cur:
        blocks.append(cur)

    for b in blocks:
        raw = b.pop("lines")
        sources = []
        for ln in raw:
            for m in NODE_ID_RE.finditer(ln):
                if m.group(1) not in sources:
                    sources.append(m.group(1))
        # Тело: убираем метаданные-строки (Источники/Метка/маркер), пустые края.
        body_lines = [
            ln for ln in raw
            if ln.strip() != "---"
            and not META_LINE_RE.match(ln.strip())
            and not MARKER_ONLY_RE.match(ln.strip())
        ]
        b["body"] = "\n".join(body_lines).strip()
        b["sources"] = sources
    return blocks


def load_dream(date):
    f = DREAMS_DIR / f"dream-{date}.md"
    if not f.exists():
        die(f"dream-нода не найдена: {f}")
    return f.read_text(encoding="utf-8")


def already_promoted(node_id):
    if not PROMOTED_LOG.exists():
        return False
    for ln in PROMOTED_LOG.read_text(encoding="utf-8").splitlines():
        try:
            if json.loads(ln).get("node_id") == node_id:
                return True
        except json.JSONDecodeError:
            continue
    return False


def infer_domain(sources):
    """Домен = домен первого источника, чей файл найден в Brain."""
    domains = [d.name for d in BRAIN_ROOT.iterdir() if d.is_dir() and (d / "nodes").is_dir()]
    for sid in sources:
        for dom in domains:
            ndir = BRAIN_ROOT / dom / "nodes"
            try:
                hit = subprocess.run(
                    ["grep", "-rlF", f"id: {sid}", str(ndir)],
                    capture_output=True, text=True, timeout=20,
                )
            except (subprocess.SubprocessError, OSError):
                continue
            if hit.returncode == 0 and hit.stdout.strip():
                return dom
    return None


def git_commit(domain_root, file_path, msg):
    if subprocess.run(
        ["git", "-C", str(domain_root), "rev-parse", "--is-inside-work-tree"],
        capture_output=True,
    ).returncode != 0:
        return None, "домен не git-репо — файл записан, но не закоммичен"
    subprocess.run(["git", "-C", str(domain_root), "add", str(file_path)], capture_output=True)
    staged = subprocess.run(
        ["git", "-C", str(domain_root), "diff", "--cached", "--quiet"], capture_output=True
    )
    if staged.returncode == 0:
        return None, "git: нечего коммитить (файл уже в индексе/без изменений)"
    res = subprocess.run(
        ["git", "-C", str(domain_root),
         "-c", "user.name=dream-promote", "-c", "user.email=dream-promote@local",
         "commit", "-m", msg],
        capture_output=True, text=True,
    )
    if res.returncode != 0:
        return None, f"git commit упал: {res.stderr.strip()[:200]}"
    sha = subprocess.run(
        ["git", "-C", str(domain_root), "rev-parse", "--short", "HEAD"],
        capture_output=True, text=True,
    ).stdout.strip()
    return sha, None


def build_node(ntype, domain, slug, title, body, sources, dream_id, n):
    node_id = f"{ntype}:{domain}/{slug}"
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    today = now[:10]
    fm = [
        "---",
        f"id: {node_id}",
        f"type: {ntype}",
        f"title: {json.dumps(title, ensure_ascii=False)}",
        "source: dream-promote",
        "source_system: brain-dream",
        f"observed_at: '{now}'",
        f"date: '{today}'",
    ]
    if ntype == "decision":
        fm += ["status: accepted", "decided_by: gennady"]
    fm.append(f"dream_id: {dream_id}")
    fm.append(f"dream_insight: {n}")
    fm.append("links:")
    for sid in sources:
        fm.append(f"  - {{rel: relates-to, to: '{sid}'}}")
    fm.append(f"  - {{rel: derived-from, to: '{dream_id}'}}")
    fm.append("tags: [from-dream]")
    fm.append("---")
    footer = f"\n\n---\n*Промоутнуто из {dream_id} (инсайт #{n}) через dream-promote.*"
    return node_id, "\n".join(fm) + "\n\n" + body + footer + "\n"


def cmd_list():
    if not PROMOTED_LOG.exists():
        print("(пока ничего не промоутнуто)", file=sys.stderr)
        return
    for ln in PROMOTED_LOG.read_text(encoding="utf-8").splitlines()[-20:]:
        try:
            d = json.loads(ln)
        except json.JSONDecodeError:
            continue
        print(f"{d.get('ts','')}  {d.get('dream','')}#{d.get('n','')}  →  {d.get('node_id','')}")


def cmd_picker(date):
    blocks = parse_blocks(load_dream(date))
    if not blocks:
        die(f"в dream-{date} не нашёл блоков инсайтов")
    print(f"Топ-{len(blocks)} инсайтов сна {date}:\n", file=sys.stderr)
    for b in blocks:
        src = f"  [{', '.join(b['sources'])}]" if b["sources"] else "  [нет источников]"
        print(f"  #{b['n']}. {b['title']}{src}", file=sys.stderr)
    print(f"\nПромоутнуть: dream-promote.py {date} <N> [--type ...] [--domain ...]", file=sys.stderr)


def cmd_promote(date, n, ntype, domain, dry_run, assume_yes):
    blocks = {b["n"]: b for b in parse_blocks(load_dream(date))}
    if n not in blocks:
        die(f"инсайт #{n} не найден в dream-{date} (есть: {sorted(blocks)})")
    b = blocks[n]
    dream_id = f"dream:{date}"

    if not domain:
        domain = infer_domain(b["sources"])
        if not domain:
            die("не удалось определить домен по источникам инсайта — задай явно: --domain <dom>")
    if not (BRAIN_ROOT / domain / "nodes").is_dir():
        die(f"домен '{domain}' не существует в {BRAIN_ROOT}")

    slug = slugify(b["title"]) or f"dream-{date}-i{n}"
    node_id, content = build_node(
        ntype, domain, slug, b["title"], b["body"], b["sources"], dream_id, n
    )
    out_file = BRAIN_ROOT / domain / "nodes" / TYPE_DIR[ntype] / f"{domain}_{slug}.md"

    if already_promoted(node_id) or out_file.exists():
        die(f"уже существует: {node_id} ({out_file}) — пропускаю (правь руками или смени slug)")

    print(f"\n  Домен:   {domain}", file=sys.stderr)
    print(f"  Тип:     {ntype}", file=sys.stderr)
    print(f"  Id:      {node_id}", file=sys.stderr)
    print(f"  Файл:    {out_file}", file=sys.stderr)
    print(f"  Линки:   {', '.join(b['sources'] + [dream_id])}", file=sys.stderr)

    if dry_run:
        print("\n----- DRY-RUN, содержимое ноды: -----\n", file=sys.stderr)
        print(content)
        return

    if not assume_yes and sys.stdin.isatty():
        ans = input("\nЗавести ноду? [y/N] ").strip().lower()
        if ans not in ("y", "yes", "д", "да"):
            print("Отменено.", file=sys.stderr)
            return

    out_file.parent.mkdir(parents=True, exist_ok=True)
    out_file.write_text(content, encoding="utf-8")

    sha, warn = git_commit(
        BRAIN_ROOT / domain, out_file, f"dream-promote: {node_id} (из {dream_id} #{n})"
    )
    if warn:
        print(f"⚠ {warn}", file=sys.stderr)

    PROMOTED_LOG.parent.mkdir(parents=True, exist_ok=True)
    with PROMOTED_LOG.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps({
            "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "dream": date, "n": n, "node_id": node_id,
            "file": str(out_file), "domain": domain, "type": ntype,
            "git_sha": sha,
        }, ensure_ascii=False) + "\n")

    print(f"\nOK: создана {node_id}" + (f" (commit {sha})" if sha else ""), file=sys.stderr)
    print("Реиндекс: нода появится в brain_search после ближайшего brain_reindex "
          "(вызови mcp__brain__brain_reindex из CC-сессии).", file=sys.stderr)


def main():
    argv = sys.argv[1:]
    if argv and argv[0] in ("help", "-h", "--help"):
        print(__doc__)
        return
    if argv and argv[0] == "list":
        cmd_list()
        return

    p = argparse.ArgumentParser(add_help=False)
    p.add_argument("pos", nargs="*")
    p.add_argument("--type", default="lesson", choices=list(TYPE_DIR))
    p.add_argument("--domain", default=None)
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--yes", action="store_true")
    a = p.parse_args(argv)

    date, n = None, None
    for tok in a.pos:
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", tok):
            date = tok
        elif tok.isdigit():
            n = int(tok)
        else:
            die(f"непонятный аргумент: {tok}")
    if date is None:
        date = latest_dream_date()

    if n is None:
        cmd_picker(date)
        return
    cmd_promote(date, n, a.type, a.domain, a.dry_run, a.yes)


if __name__ == "__main__":
    main()
