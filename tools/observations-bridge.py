#!/usr/bin/env python3
"""observations-bridge — мост «наблюдения → сон».

Тянет агрегат pattern-mining из session-manager
(`GET /api/observations/digest`), сверяет его с корпусом Brain и рендерит
компактный контекст-блок для ОДНОГО прохода генерации brain-dream.

Зачем отдельный источник (а не расширение `session-observer`):
`session-observer` — слой ЗАХВАТА: читает сырые транскрипты и заводит новые
узлы. Этот мост — слой СИНТЕЗА: он не читает транскрипты вообще и не пишет
узлов, он приносит уже переваренный поведенческий агрегат, чтобы сон смог
сделать вывод класса «граф против практики» (что записано ≠ что делают
руками). См. docs/05-observations-bridge.md.

Контракт:
- stdout — готовый контекст-блок (пусто, если кормить нечем);
- exit 0 — контекст отдан; exit 3 — кормить нечем (fail-open, НЕ ошибка);
- exit 1 — внутренняя ошибка (вызывающий тоже обязан продолжить работу).

Никаких LLM-вызовов: вся выборка и сопоставление детерминированы.
Только stdlib — скрипт гоняется из cron-окружения без venv.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

DEFAULT_URL = "http://gena-vps:3007/api/observations/digest"

# Шум нормализатора pattern-mining: «Automate/Capture recurring workflow: <сырая
# команда>». По аудиту 2026-08-09 (brain: lesson:pattern-mining-dismissal-by-
# proposal-not-artifact-2026-08-09) таких 76% и осмысленного сигнала в них ноль.
GENERIC_TITLE_RE = re.compile(
    r"^\s*(automate|capture)\s+recurring\s+workflow\s*:", re.IGNORECASE
)

# Те же паттерны, что redact_secrets в orchestrator/brain-dream.sh: digest несёт
# сырые команды, в них может оказаться токен.
SECRET_PATTERNS = [
    (re.compile(r"ntn_[A-Za-z0-9]{40,}"), "[REDACTED-notion]"),
    (re.compile(r"secret_[A-Za-z0-9]{40,}"), "[REDACTED-notion]"),
    (re.compile(r"xox[abcdprs]-[0-9A-Za-z-]{10,}"), "[REDACTED-slack]"),
    (re.compile(r"xapp-[0-9A-Za-z-]{10,}"), "[REDACTED-slack]"),
    (re.compile(r"sk-[A-Za-z0-9_-]{20,}"), "[REDACTED-key]"),
    (re.compile(r"AKIA[0-9A-Z]{16}"), "[REDACTED-aws]"),
    (re.compile(r"gh[pousr]_[A-Za-z0-9]{36,}"), "[REDACTED-github]"),
    (re.compile(r"glpat-[A-Za-z0-9_-]{20,}"), "[REDACTED-gitlab]"),
    (re.compile(r"AIza[0-9A-Za-z_-]{35}"), "[REDACTED-google]"),
    (
        re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"),
        "[REDACTED-jwt]",
    ),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "[REDACTED-pem]"),
]

# Слова, по которым матчить корпус бессмысленно: они есть в половине нод.
STOPWORDS = {
    "automate",
    "capture",
    "recurring",
    "workflow",
    "script",
    "scripts",
    "command",
    "commands",
    "session",
    "sessions",
    "project",
    "projects",
    "brain",
    "claude",
    "agent",
    "agents",
    "python",
    "python3",
    "bash",
    "shell",
    "install",
    "output",
    "check",
    "status",
    "recent",
    "current",
    "libexec",
    "home",
    "users",
    "genlorem",
    "master",
    "origin",
    "branch",
    "commit",
    "проверка",
    "скрипт",
    "команда",
    "обёртка",
    "добавить",
    "построить",
}

# Компоненты пути, которые сами по себе ничего не идентифицируют.
PATH_NOISE = {"bin", "src", "lib", "libexec", "scripts", "home", "users", "opt", "usr"}

TOKEN_RE = re.compile(r"[A-Za-z][A-Za-z0-9_.-]{3,39}")
BACKTICK_RE = re.compile(r"`([^`]{2,40})`")
PATH_RE = re.compile(r"(?:~|\.{0,2})?/?[\w.-]+(?:/[\w.-]+)+")
FM_ID_RE = re.compile(r"^id:\s*(.+?)\s*$", re.MULTILINE)
FM_TITLE_RE = re.compile(r"^title:\s*(.+?)\s*$", re.MULTILINE)
STALE_RE = re.compile(r"superseded[-_]by|valid_until", re.IGNORECASE)


def scrub(text: str) -> str:
    for pattern, repl in SECRET_PATTERNS:
        text = pattern.sub(repl, text)
    return text


def log(msg: str) -> None:
    sys.stderr.write(
        json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "tool": "observations-bridge", "msg": msg},
                   ensure_ascii=False) + "\n"
    )


# ── digest: сеть + кэш ───────────────────────────────────────────────────────


def fetch_digest(url: str, limit: int, timeout: float) -> dict[str, Any]:
    full = f"{url}?limit={limit}" if "?" not in url else f"{url}&limit={limit}"
    req = urllib.request.Request(full, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
        payload = json.loads(resp.read().decode("utf-8"))
    if not isinstance(payload, dict) or not payload.get("ok"):
        raise ValueError("digest payload not ok")
    if not isinstance(payload.get("items"), list):
        raise ValueError("digest has no items[]")
    return payload


def load_digest(
    url: str, limit: int, timeout: float, cache: Path | None, cache_max_age_h: float
) -> tuple[dict[str, Any] | None, str]:
    """Живой digest, иначе последний успешный из кэша. Никогда не бросает."""
    try:
        payload = fetch_digest(url, limit, timeout)
    except (urllib.error.URLError, OSError, ValueError, json.JSONDecodeError) as exc:
        log(f"fetch failed: {type(exc).__name__}: {exc}")
    else:
        if cache is not None:
            try:
                cache.parent.mkdir(parents=True, exist_ok=True)
                tmp = cache.with_suffix(cache.suffix + ".tmp")
                tmp.write_text(
                    json.dumps(
                        {"fetchedAt": time.time(), "url": url, "payload": payload},
                        ensure_ascii=False,
                    ),
                    encoding="utf-8",
                )
                tmp.replace(cache)
            except OSError as exc:
                log(f"cache write failed: {exc}")
        return payload, "live"

    if cache is None or not cache.exists():
        return None, "unavailable"
    try:
        blob = json.loads(cache.read_text(encoding="utf-8"))
        age_h = (time.time() - float(blob.get("fetchedAt", 0))) / 3600.0
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        log(f"cache read failed: {exc}")
        return None, "unavailable"
    if cache_max_age_h > 0 and age_h > cache_max_age_h:
        log(f"cache too old: {age_h:.1f}h > {cache_max_age_h}h")
        return None, "stale-cache"
    return blob.get("payload"), f"cache({age_h:.1f}h)"


# ── корпус Brain ─────────────────────────────────────────────────────────────


@dataclass
class Node:
    node_id: str
    title: str
    path: str
    stale: bool


def corpus_paths(
    nodes_tsv: Path | None, brain_root: Path, domains: Iterable[str], cap: int
) -> list[Path]:
    paths: list[Path] = []
    if nodes_tsv is not None and nodes_tsv.exists():
        # Манифест orchestrator-а: domain \t cluster \t path.
        for line in nodes_tsv.read_text(encoding="utf-8", errors="replace").splitlines():
            parts = line.split("\t")
            if len(parts) >= 3 and parts[2]:
                paths.append(Path(parts[2]))
    else:
        for domain in domains:
            root = brain_root / domain / "nodes"
            if root.is_dir():
                paths.extend(sorted(root.rglob("*.md")))
    if cap > 0 and len(paths) > cap:
        log(f"corpus capped: {len(paths)} -> {cap}")
        paths = paths[:cap]
    return paths


def node_meta(path: Path, text: str) -> Node:
    head = text[:2000]
    node_id = ""
    title = ""
    m = FM_ID_RE.search(head)
    if m:
        node_id = m.group(1).strip().strip("\"'")
    m = FM_TITLE_RE.search(head)
    if m:
        title = m.group(1).strip().strip("\"'")
    if not node_id:
        node_id = path.stem
    if not title:
        title = path.stem
    return Node(node_id=node_id, title=title, path=str(path), stale=bool(STALE_RE.search(head)))


# ── выборка наблюдений ───────────────────────────────────────────────────────


@dataclass
class Observation:
    raw: dict[str, Any]
    obs_id: str
    title: str
    kind: str
    status: str
    summary: str
    proposal: str
    artifact: str
    coverage: str
    occurrences: int
    sessions: int
    projects: int
    score: int
    summary_as_of: int = 0
    text_predates_build: bool = False
    tokens: list[str] = field(default_factory=list)
    nodes: list[Node] = field(default_factory=list)
    klass: str = ""

    @property
    def is_reality(self) -> bool:
        return bool(self.artifact) and (
            self.status == "materialized" or self.coverage == "verified"
        )


def as_obs(raw: dict[str, Any]) -> Observation:
    def s(key: str) -> str:
        val = raw.get(key)
        return val.strip() if isinstance(val, str) else ""

    def i(key: str) -> int:
        val = raw.get(key)
        return int(val) if isinstance(val, (int, float)) else 0

    return Observation(
        raw=raw,
        obs_id=s("id"),
        title=s("title"),
        kind=s("kind"),
        status=s("status"),
        summary=s("summary"),
        proposal=s("proposal"),
        artifact=s("artifact"),
        coverage=s("coverage"),
        occurrences=i("occurrences"),
        sessions=i("sessions"),
        projects=i("projects"),
        score=i("score"),
        summary_as_of=i("summaryAsOf"),
        # Явный флаг стороны session-manager: текст написан до постройки артефакта.
        # Старые срезы (в т.ч. лежащие в кэше) поля не имеют — тогда работает
        # собственная эвристика по is_reality.
        text_predates_build=raw.get("textPredatesBuild") is True,
    )


def strong_tokens(obs: Observation) -> list[str]:
    """Идентифицирующие ключи наблюдения для поиска по корпусу.

    Только то, что реально что-то называет: пути, имена файлов, бэктик-спаны,
    дефисные/точечные идентификаторы. Общие слова выбрасываем — их совпадение
    в корпусе ничего не доказывает.
    """
    haystack = " ".join([obs.title, obs.summary, obs.proposal, obs.artifact])
    found: list[str] = []

    for span in BACKTICK_RE.findall(haystack):
        span = span.strip().lstrip("|").strip()
        # Бэктик-спан идентифицирует что-то, только если он либо составной
        # (`svc logs`), либо содержит спецсимвол пути (`~/bin/svc-proc`).
        # Одиночные слова вида `view`, `logs`, `port` и голые флаги (`--brief`)
        # — это не ключи.
        if not (4 <= len(span) <= 30):
            continue
        if span.lower() in STOPWORDS or span.startswith("-"):
            continue
        if any(ch in span for ch in "-_./") or " " in span:
            found.append(span)

    for path in PATH_RE.findall(haystack):
        for part in re.split(r"[/\\]", path):
            part = part.strip("~.")
            if len(part) < 4 or part.lower() in PATH_NOISE or part.lower() in STOPWORDS:
                continue
            if "." in part or "-" in part or "_" in part:
                found.append(part)

    for word in TOKEN_RE.findall(haystack):
        # Обрезаем хвостовые дефисы/точки: TOKEN_RE ловит «generic-» из
        # «generic-примитивные», и такой огрызок матчит пол-корпуса.
        word = word.strip("-._")
        low = word.lower()
        if low in STOPWORDS or low in PATH_NOISE:
            continue
        # Голое латинское слово берём, только если оно похоже на идентификатор
        # (дефис/подчёркивание/точка) — иначе ложных совпадений больше, чем
        # настоящих.
        if any(ch in word for ch in "-_.") and len(word) >= 5:
            found.append(word)

    seen: set[str] = set()
    uniq: list[str] = []
    for tok in found:
        low = tok.lower()
        if low in seen:
            continue
        seen.add(low)
        uniq.append(tok)

    # Сначала то, что больше похоже на имя вещи (путь → файл → идентификатор →
    # фраза): бюджет ключей маленький, и `yandex-tracker.sh` полезнее, чем
    # `view KEY`.
    def specificity(tok: str) -> tuple[int, int]:
        if "/" in tok:
            rank = 3
        elif "." in tok:
            rank = 2
        elif "-" in tok or "_" in tok:
            rank = 1
        else:
            rank = 0
        return (-rank, -len(tok))

    uniq.sort(key=specificity)
    return uniq[:8]


def match_corpus(
    observations: list[Observation], paths: list[Path], per_item: int, df_max_pct: float
) -> int:
    """Один проход по корпусу: какие ноды упоминают ключи наблюдений.

    Токены, встречающиеся слишком в многих нодах (`session-manager`,
    `pattern-mining`), выбрасываются: они ничего не различают, и топ-3 «ноды про
    это» по ним получаются случайными. Порог считается от размера корпуса, так
    что калибровать руками ничего не надо. Токен с df=0 — максимально
    специфичный, он и есть сигнал «в графе про это ничего нет».
    """
    token_owners: dict[str, list[Observation]] = {}
    for obs in observations:
        for tok in obs.tokens:
            token_owners.setdefault(tok.lower(), []).append(obs)
    if not token_owners:
        return 0

    alternation = "|".join(
        re.escape(tok) for tok in sorted(token_owners, key=len, reverse=True)
    )
    scanner = re.compile(alternation, re.IGNORECASE)

    per_path_tokens: list[tuple[str, set[str], Node]] = []
    doc_freq: dict[str, int] = dict.fromkeys(token_owners, 0)

    for path in paths:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        found = {m.group(0).lower() for m in scanner.finditer(text)}
        found = {tok for tok in found if tok in doc_freq}
        if not found:
            continue
        for tok in found:
            doc_freq[tok] += 1
        per_path_tokens.append((str(path), found, node_meta(path, text)))

    df_cap = max(20, int(len(paths) * df_max_pct / 100.0))
    dropped = {tok for tok, freq in doc_freq.items() if freq > df_cap}
    if dropped:
        log(f"df-filter dropped {len(dropped)} non-specific tokens (cap={df_cap}): "
            + ", ".join(sorted(dropped)[:12]))

    for obs in observations:
        obs.tokens = [tok for tok in obs.tokens if tok.lower() not in dropped]

    # Совпадение по имени файла/пути весит больше, чем совпадение по фразе:
    # иначе топ-3 «нод про это» занимают ноды, поймавшие `head -N`.
    def token_weight(tok: str) -> int:
        if "/" in tok and all(
            re.search(r"[A-Za-zА-Яа-я]{2,}", seg) for seg in tok.split("/") if seg
        ):
            return 4  # настоящий путь, а не `head -8/-12/-15`
        if "." in tok:
            return 3
        if "-" in tok or "_" in tok:
            return 2
        return 1

    weight = {tok: token_weight(tok) for tok in token_owners}

    hits: dict[str, dict[str, int]] = {obs.obs_id: {} for obs in observations}
    nodes_by_path: dict[str, Node] = {}
    for path_str, found, node in per_path_tokens:
        nodes_by_path[path_str] = node
        for tok in found - dropped:
            for obs in token_owners.get(tok, ()):
                hits[obs.obs_id][path_str] = hits[obs.obs_id].get(path_str, 0) + weight[tok]

    for obs in observations:
        ranked = sorted(hits[obs.obs_id].items(), key=lambda kv: -kv[1])[:per_item]
        obs.nodes = [nodes_by_path[p] for p, _ in ranked]
    return df_cap


# ── леджер: не кормить сон одним и тем же каждую ночь ────────────────────────


def load_ledger(path: Path | None, window_days: float) -> dict[str, dict[str, Any]]:
    if path is None or not path.exists():
        return {}
    cutoff = time.time() - window_days * 86400 if window_days > 0 else 0
    out: dict[str, dict[str, Any]] = {}
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return {}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(rec, dict) or "id" not in rec:
            continue
        if float(rec.get("fed_at", 0)) < cutoff:
            continue
        out[str(rec["id"])] = rec
    return out


def ledger_suppresses(obs: Observation, prev: dict[str, Any] | None, regrow_pct: float) -> bool:
    """Уже скармливали — молчим, пока наблюдение не изменилось по сути."""
    if prev is None:
        return False
    if prev.get("status") != obs.status:
        return False
    if (prev.get("artifact") or "") != obs.artifact:
        return False
    if (prev.get("coverage") or "") != obs.coverage:
        return False
    before = float(prev.get("occurrences") or 0)
    if before <= 0:
        return False
    growth = (obs.occurrences - before) / before * 100.0
    return growth < regrow_pct


def append_ledger(path: Path, observations: list[Observation], dream_date: str) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as fh:
            for obs in observations:
                fh.write(
                    json.dumps(
                        {
                            "id": obs.obs_id,
                            "status": obs.status,
                            "coverage": obs.coverage,
                            "artifact": obs.artifact,
                            "occurrences": obs.occurrences,
                            "class": obs.klass,
                            "fed_at": time.time(),
                            "dream_date": dream_date,
                        },
                        ensure_ascii=False,
                    )
                    + "\n"
                )
    except OSError as exc:
        log(f"ledger append failed: {exc}")


# ── классификация и рендер ───────────────────────────────────────────────────

CLASS_ORDER = {"conformance": 0, "unwritten-practice": 1, "undocumented-reality": 2}

CLASS_HINT = {
    "conformance": "артефакт ПОДТВЕРЖДЁН на диске; в графе есть ноды про это — проверь, не устарели ли они",
    "unwritten-practice": "повторяется много раз, в графе НЕТ ни одной ноды с этими ключами",
    "undocumented-reality": "артефакт ПОДТВЕРЖДЁН на диске, но в графе про него ничего нет",
}


def classify(
    observations: list[Observation], min_occ: int, min_sessions: int
) -> tuple[list[Observation], dict[str, int]]:
    stats = {
        "generic_noise": 0,
        "below_threshold": 0,
        "no_strong_key": 0,
        "already_in_graph": 0,
        "selected": 0,
    }
    picked: list[Observation] = []

    for obs in observations:
        if GENERIC_TITLE_RE.match(obs.title):
            stats["generic_noise"] += 1
            continue
        if not obs.tokens:
            stats["no_strong_key"] += 1
            continue

        if obs.is_reality:
            obs.klass = "conformance" if obs.nodes else "undocumented-reality"
            picked.append(obs)
            continue

        if obs.occurrences < min_occ or obs.sessions < min_sessions:
            stats["below_threshold"] += 1
            continue
        if obs.nodes:
            # Практика уже описана в графе — это НЕ расхождение, кормить нечем.
            # Ровно та болячка, из-за которой кандидаты сна дублируют корпус.
            stats["already_in_graph"] += 1
            continue
        obs.klass = "unwritten-practice"
        picked.append(obs)

    picked.sort(key=lambda o: (CLASS_ORDER.get(o.klass, 9), -o.score, -o.occurrences))
    stats["selected"] = len(picked)
    return picked, stats


def render(
    observations: list[Observation],
    payload: dict[str, Any],
    source: str,
    max_chars: int,
) -> str:
    generated = payload.get("generatedTs")
    when = (
        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(generated / 1000))
        if isinstance(generated, (int, float))
        else "unknown"
    )
    head = [
        "--- PRACTICE DIGEST ---",
        "Это НЕ узлы графа. Это агрегат того, что человек и агенты РЕАЛЬНО делают",
        "руками в сессиях Claude Code (pattern-mining session-manager). Поле",
        "artifact — путь, существование которого проверено на диске.",
        "ВАЖНО: title/summary наблюдения писались в момент, когда паттерн только",
        "заметили. Если они противоречат строке artifact_on_disk — верна строка",
        "artifact_on_disk, она проверена на диске позже.",
        f"source: {payload.get('host', 'session-manager')} ({source})",
        f"digest_generated: {when}",
        f"observations: {len(observations)}",
        "",
    ]
    chunks: list[str] = []
    for obs in observations:
        lines = [
            "--- OBSERVATION ---",
            f"id: {obs.obs_id}",
            f"class: {obs.klass} — {CLASS_HINT.get(obs.klass, '')}",
            f"kind: {obs.kind}",
            f"status: {obs.status}",
            f"repeats: {obs.occurrences}x в {obs.sessions} сессиях / {obs.projects} проектах",
        ]
        if obs.artifact:
            lines.append(f"artifact_on_disk: {obs.artifact} (coverage={obs.coverage or 'unknown'})")
        else:
            lines.append(f"artifact_on_disk: НЕТ (coverage={obs.coverage or 'unknown'})")
        lines.append(f"title: {obs.title}")
        # У построенного артефакта summary/proposal — это план постройки,
        # написанный ДО неё («подкоманды нет, отложена на этап 2»). Модель
        # принимает такой текст за факт и выдаёт вывод, противоречащий диску.
        # С 2026-08-10 сторона session-manager сама помечает такой текст
        # (`textPredatesBuild`) и не отдаёт `proposal`; эвристика по is_reality
        # остаётся для старых срезов из кэша.
        stale_text = obs.text_predates_build or obs.is_reality
        summary_cap = 300 if stale_text else 600
        if obs.summary and obs.summary != obs.title:
            label = "summary (написан ДО постройки артефакта)" if stale_text else "summary"
            lines.append(f"{label}: {obs.summary[:summary_cap]}")
        if obs.proposal and not stale_text:
            lines.append(f"proposal: {obs.proposal[:400]}")
        if obs.nodes:
            lines.append("graph_nodes_about_it:")
            for node in obs.nodes:
                flag = " [помечена устаревшей]" if node.stale else ""
                lines.append(f"  - {node.node_id} — {node.title}{flag}")
        else:
            lines.append("graph_nodes_about_it: НЕТ СОВПАДЕНИЙ по ключам "
                         + ", ".join(obs.tokens[:5]))
        chunks.append("\n".join(lines))

    out = "\n".join(head)
    kept: list[Observation] = []
    for obs, chunk in zip(observations, chunks):
        if max_chars > 0 and len(out) + len(chunk) + 1 > max_chars:
            break
        out += chunk + "\n"
        kept.append(obs)
    observations[:] = kept
    return scrub(out)


def allowed_ids(observations: list[Observation]) -> list[str]:
    ids: list[str] = []
    for obs in observations:
        ids.append(obs.obs_id)
        ids.extend(node.node_id for node in obs.nodes)
    seen: set[str] = set()
    out: list[str] = []
    for i in ids:
        if i and i not in seen:
            seen.add(i)
            out.append(i)
    return out


def main(argv: list[str] | None = None) -> int:
    home = Path(os.environ.get("HOME", "~")).expanduser()
    out_dir = Path(os.environ.get("DREAM_OUT_DIR", home / "brain" / "dreams"))

    ap = argparse.ArgumentParser(description="Мост наблюдений pattern-mining в brain-dream")
    ap.add_argument("--url", default=os.environ.get("DREAM_OBSERVATIONS_URL", DEFAULT_URL))
    ap.add_argument("--limit", type=int, default=int(os.environ.get("DREAM_OBSERVATIONS_LIMIT", "50")))
    ap.add_argument("--timeout", type=float, default=float(os.environ.get("DREAM_OBSERVATIONS_TIMEOUT", "10")))
    ap.add_argument("--cache", default=str(out_dir / ".observations-cache.json"))
    ap.add_argument("--cache-max-age-h", type=float, default=72.0)
    ap.add_argument("--ledger", default=str(out_dir / ".observations-seen.jsonl"))
    ap.add_argument("--ledger-window-days", type=float, default=14.0)
    ap.add_argument("--regrow-pct", type=float, default=50.0,
                    help="на сколько %% должны вырасти повторы, чтобы скормить наблюдение повторно")
    ap.add_argument("--brain-root", default=str(home / "brain"))
    ap.add_argument("--domains", default=os.environ.get("DREAM_DOMAINS", "travelmart personal"))
    ap.add_argument("--nodes-tsv", default="")
    ap.add_argument("--corpus-max-files", type=int, default=20000)
    ap.add_argument("--nodes-per-item", type=int, default=3)
    ap.add_argument("--token-df-max-pct", type=float, default=1.0,
                    help="токен, встречающийся более чем в этом %% нод корпуса, не различает ничего")
    ap.add_argument("--max-items", type=int, default=int(os.environ.get("DREAM_OBSERVATIONS_MAX_ITEMS", "12")))
    ap.add_argument("--min-occurrences", type=int, default=int(os.environ.get("DREAM_OBSERVATIONS_MIN_OCC", "40")))
    ap.add_argument("--min-sessions", type=int, default=5)
    ap.add_argument("--max-chars", type=int, default=int(os.environ.get("DREAM_OBSERVATIONS_MAX_CHARS", "12000")))
    ap.add_argument("--json-out", default="", help="куда положить машинный срез выборки")
    ap.add_argument("--no-ledger-write", action="store_true")
    ap.add_argument("--dream-date", default=time.strftime("%Y-%m-%d", time.gmtime()))
    args = ap.parse_args(argv)

    def write_selection(source: str, stats: dict[str, Any], items: list[Observation]) -> None:
        """Машинный срез прогона. Пишем ВСЕГДА, в том числе на пустом прогоне:
        иначе отчёт ночи покажет вчерашнюю выборку как сегодняшнюю."""
        if not args.json_out:
            return
        try:
            Path(args.json_out).write_text(
                json.dumps(
                    {
                        "source": source,
                        "stats": stats,
                        "allowed_ids": allowed_ids(items),
                        "items": [
                            {
                                "id": o.obs_id,
                                "class": o.klass,
                                "kind": o.kind,
                                "status": o.status,
                                "occurrences": o.occurrences,
                                "artifact": o.artifact,
                                "tokens": o.tokens,
                                "nodes": [n.node_id for n in o.nodes],
                            }
                            for o in items
                        ],
                    },
                    ensure_ascii=False,
                    indent=2,
                ),
                encoding="utf-8",
            )
        except OSError as exc:
            log(f"selection write failed: {exc}")

    cache = Path(args.cache) if args.cache else None
    payload, source = load_digest(args.url, args.limit, args.timeout, cache, args.cache_max_age_h)
    if payload is None:
        log("no digest (live and cache both unusable) — сон идёт как раньше")
        write_selection(source, {"fed": 0, "reason": "no-digest"}, [])
        return 3

    observations = [as_obs(raw) for raw in payload.get("items", []) if isinstance(raw, dict)]
    observations = [o for o in observations if o.obs_id]
    for obs in observations:
        obs.tokens = strong_tokens(obs)

    interesting = [o for o in observations if not GENERIC_TITLE_RE.match(o.title) and o.tokens]
    paths = corpus_paths(
        Path(args.nodes_tsv) if args.nodes_tsv else None,
        Path(args.brain_root),
        args.domains.split(),
        args.corpus_max_files,
    )
    df_cap = match_corpus(interesting, paths, args.nodes_per_item, args.token_df_max_pct)

    picked, stats = classify(observations, args.min_occurrences, args.min_sessions)
    stats["token_df_cap"] = df_cap

    ledger_path = Path(args.ledger) if args.ledger else None
    ledger = load_ledger(ledger_path, args.ledger_window_days)
    fresh: list[Observation] = []
    suppressed = 0
    for obs in picked:
        if ledger_suppresses(obs, ledger.get(obs.obs_id), args.regrow_pct):
            suppressed += 1
            continue
        fresh.append(obs)
    stats["ledger_suppressed"] = suppressed
    stats["corpus_files"] = len(paths)

    if args.max_items > 0:
        fresh = fresh[: args.max_items]

    if not fresh:
        stats["fed"] = 0
        log(f"nothing to feed: {json.dumps(stats, ensure_ascii=False)}")
        write_selection(source, stats, [])
        return 3

    # render усекает список по бюджету символов — селекция пишется ПОСЛЕ него,
    # чтобы леджер и отчёт отражали то, что модель реально увидела.
    context = render(fresh, payload, source, args.max_chars)
    stats["fed"] = len(fresh)
    write_selection(source, stats, fresh)

    if ledger_path is not None and not args.no_ledger_write:
        append_ledger(ledger_path, fresh, args.dream_date)

    sys.stdout.write(context)
    log(f"fed {len(fresh)} observations: {json.dumps(stats, ensure_ascii=False)}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
