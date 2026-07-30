#!/usr/bin/env python3
"""mined-promote — ночной авто-промоушен mined-кандидатов из dreams."""
from __future__ import annotations

import argparse
import asyncio
import json
import math
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Callable, Mapping, Sequence


DREAMS = Path(os.environ.get("DREAM_NODE_ROOT", str(Path.home() / "brain" / "dreams")))
DOMAINS = ("personal", "infra", "marquiz", "travelmart", "skvo", "indie", "govori")
NODE_TYPES = ("note", "decision", "lesson")
DEFAULT_JUDGE_CMD = ["gemini", "-m", "gemini-2.5-flash", "-p", "{PROMPT}"]


@dataclass(frozen=True)
class Candidate:
    """Одна mined-candidate нода из dreams."""

    id: str
    title: str
    body: str
    confidence: float
    tags: tuple[str, ...]
    frontmatter: Mapping[str, object]
    path: Path


@dataclass(frozen=True)
class PromotionDecision:
    """Проверенный ответ LLM-судьи."""

    action: str
    domain: str | None
    node_type: str | None
    title: str
    links: tuple[str, ...]
    confidence: float
    reason: str


def _scalar(value: str) -> object:
    """Разобрать скаляр минимального YAML-подмножества."""
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    lowered = value.lower()
    if lowered in {"true", "false"}:
        return lowered == "true"
    if lowered in {"null", "none", "~"}:
        return None
    try:
        return int(value)
    except ValueError:
        try:
            return float(value)
        except ValueError:
            return value


def fallback_split_frontmatter(text: str) -> tuple[dict[str, object], str]:
    """Парсер `---` frontmatter: скаляры, flow- и block-списки."""
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].strip() != "---":
        return {}, text
    closing = next(
        (index for index, line in enumerate(lines[1:], start=1) if line.strip() == "---"),
        None,
    )
    if closing is None:
        return {}, text
    raw_lines = [line.rstrip("\r\n") for line in lines[1:closing]]
    data: dict[str, object] = {}
    index = 0
    while index < len(raw_lines):
        line = raw_lines[index]
        if not line.strip() or line.lstrip().startswith("#") or ":" not in line:
            index += 1
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip()
        if value.startswith("[") and value.endswith("]"):
            inner = value[1:-1].strip()
            data[key] = (
                [_scalar(item) for item in inner.split(",") if item.strip()]
                if inner
                else []
            )
        elif not value:
            items: list[object] = []
            cursor = index + 1
            while cursor < len(raw_lines):
                item = raw_lines[cursor]
                if not item.startswith((" ", "\t")):
                    break
                stripped = item.strip()
                if not stripped.startswith("-"):
                    break
                items.append(_scalar(stripped[1:]))
                cursor += 1
            data[key] = items if items else ""
            index = cursor - 1
        else:
            data[key] = _scalar(value)
        index += 1
    return data, "".join(lines[closing + 1:])


def frontmatter_parser() -> Callable[[str], tuple[dict[str, object], str]]:
    """Взять parser движка, если server уже импортируем; иначе fallback."""
    try:
        from server import _split_frontmatter

        return _split_frontmatter
    except Exception:  # noqa: BLE001 — движок необязателен для этого сканера
        return fallback_split_frontmatter


def terminal_decisions(path: Path) -> set[str]:
    """promote/drop блокируют повторный разбор; defer намеренно не блокирует."""
    result: set[str] = set()
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return result
    for line in lines:
        try:
            item = json.loads(line)
        except (TypeError, json.JSONDecodeError):
            continue
        if (
            isinstance(item, dict)
            and item.get("action") in {"promote", "drop"}
            and isinstance(item.get("id"), str)
        ):
            result.add(item["id"])
    return result


def scan_candidates(
    dreams_root: Path,
    min_conf: float = 0.85,
    *,
    decisions_path: Path | None = None,
    parser: Callable[[str], tuple[dict[str, object], str]] | None = None,
) -> list[Candidate]:
    """Отфильтровать mined-кандидатов по тегу, confidence и state-логу."""
    state_path = decisions_path or dreams_root / "promote-log" / "decisions.jsonl"
    blocked = terminal_decisions(state_path)
    split = parser or frontmatter_parser()
    candidates: list[Candidate] = []
    # рекурсивно: движок раскладывает ноды по типовым подпапкам (nodes/notes/...)
    for path in sorted((dreams_root / "nodes").glob("**/*.md")):
        try:
            frontmatter, body = split(path.read_text(encoding="utf-8"))
        except Exception:  # noqa: BLE001 — одна битая нода не останавливает акт
            continue
        node_id = frontmatter.get("id")
        tags = frontmatter.get("tags")
        confidence = frontmatter.get("confidence")
        if (
            not isinstance(node_id, str)
            or node_id in blocked
            or not isinstance(tags, list)
            or "mined-candidate" not in tags
            or isinstance(confidence, bool)
            or not isinstance(confidence, (int, float))
        ):
            continue
        score = float(confidence)
        if not math.isfinite(score) or score < min_conf:
            continue
        candidates.append(
            Candidate(
                id=node_id,
                title=str(frontmatter.get("title", "")).strip(),
                body=body.strip(),
                confidence=score,
                tags=tuple(str(tag) for tag in tags),
                frontmatter=frontmatter,
                path=path,
            ),
        )
    return sorted(candidates, key=lambda item: (-item.confidence, item.id))


def subprocess_judge(
    prompt: str,
    judge_cmd: Sequence[str] = DEFAULT_JUDGE_CMD,
    timeout: int = 45,
) -> str:
    """Вызвать LLM через конфигурируемый argv."""
    command = [prompt if item == "{PROMPT}" else item for item in judge_cmd]
    completed = subprocess.run(
        command,
        capture_output=True,
        timeout=timeout,
        text=True,
    )
    if completed.returncode:
        raise RuntimeError(f"judge exited with status {completed.returncode}")
    return completed.stdout


def _unwrap_mcp_result(result: object) -> object:
    """Извлечь data/JSON из распространённых FastMCP result-объектов."""
    data = getattr(result, "data", None)
    if data is not None:
        return data
    structured = getattr(result, "structured_content", None)
    if structured is not None:
        return structured
    content = getattr(result, "content", None)
    if isinstance(content, list) and content:
        text = getattr(content[0], "text", None)
        if isinstance(text, str):
            try:
                return json.loads(text)
            except json.JSONDecodeError:
                return text
    return result


class FastMCPGateway:
    """Единственная production-точка доступа к brain_search/add/link."""

    def __init__(self, url: str | None = None):
        self.url = url or os.environ.get(
            "BRAIN_MCP_URL",
            "http://localhost:8787/mcp",
        )

    def _call(self, tool: str, arguments: dict[str, object]) -> object:
        from fastmcp import Client

        async def invoke() -> object:
            async with Client(self.url) as client:
                return _unwrap_mcp_result(await client.call_tool(tool, arguments))

        return asyncio.run(invoke())

    def search(self, query: str, limit: int = 5) -> object:
        return self._call("brain_search", {"query": query, "limit": limit})

    def add(self, node: dict[str, object], root: str) -> object:
        return self._call("brain_add", {"node": node, "root": root})

    def link(
        self,
        src_id: str,
        rel: str,
        to_id: str,
        *,
        evidence: str | None = None,
        at: str | None = None,
    ) -> object:
        arguments = {"src_id": src_id, "rel": rel, "to_id": to_id}
        if evidence is not None:
            arguments["evidence"] = evidence
        if at is not None:
            arguments["at"] = at
        return self._call("brain_link", arguments)


def normalize_search_results(raw: object) -> list[dict[str, object]]:
    """Привести ответ search к списку словарей с id."""
    raw = _unwrap_mcp_result(raw)
    if isinstance(raw, dict) and isinstance(raw.get("results"), list):
        raw = raw["results"]
    if not isinstance(raw, list):
        return []
    return [dict(item) for item in raw if isinstance(item, Mapping)]


def promotion_prompt(
    candidate: Candidate,
    search_results: Sequence[Mapping[str, object]],
) -> str:
    """Собрать prompt, явно ограничивающий links показанными search id."""
    shown = json.dumps(
        list(search_results),
        ensure_ascii=False,
        default=str,
    )
    return (
        "Реши судьбу mined-кандидата для долговременного графа знаний.\n\n"
        f"ID: {candidate.id}\nЗаголовок: {candidate.title}\n"
        f"Факт:\n{candidate.body}\n\n"
        f"Результаты brain_search:\n{shown}\n\n"
        f"Допустимые домены: {', '.join(DOMAINS)}.\n"
        "drop — если факт дублирует существующую ноду из результатов, "
        "мимолётный/бытовой или не имеет долговременной ценности.\n"
        "links — ТОЛЬКО id из показанных результатов поиска; другие id запрещены.\n"
        "Ответ строго JSON: "
        '{"action": "promote"|"drop"|"defer", "domain": "<из списка>", '
        '"node_type": "note"|"decision"|"lesson", "title": "<до 80>", '
        '"links": ["<id из показанных результатов поиска>"], '
        '"confidence": 0..1, "reason": "<до 15 слов>"}'
    )


def extract_json_object(text: str) -> str:
    """Вырезать первый JSON-объект из вывода LLM.

    CLI-судьи (claude -p, gemini) оборачивают JSON в ```-фенсы и/или
    сопровождают текстом — голый json.loads на весь stdout не работает.
    """
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end <= start:
        raise ValueError("no JSON object in judge output")
    return text[start:end + 1]


def parse_promotion_decision(raw: object) -> PromotionDecision:
    """Проверить полный JSON-контракт судьи."""
    data = raw if isinstance(raw, dict) else json.loads(extract_json_object(str(raw)))
    if not isinstance(data, dict):
        raise ValueError("judge output is not an object")
    action = data.get("action")
    domain = data.get("domain")
    node_type = data.get("node_type")
    title = data.get("title")
    links = data.get("links")
    confidence = data.get("confidence")
    reason = data.get("reason")
    if action not in {"promote", "drop", "defer"}:
        raise ValueError("invalid action")
    if domain not in DOMAINS:
        raise ValueError("invalid domain")
    if node_type not in NODE_TYPES:
        raise ValueError("invalid node_type")
    if not isinstance(title, str) or len(title) > 80:
        raise ValueError("invalid title")
    if not isinstance(links, list) or not all(isinstance(item, str) for item in links):
        raise ValueError("invalid links")
    if isinstance(confidence, bool) or not isinstance(confidence, (int, float)):
        raise ValueError("invalid confidence")
    score = float(confidence)
    if not math.isfinite(score) or not 0.0 <= score <= 1.0:
        raise ValueError("invalid confidence")
    if not isinstance(reason, str):
        raise ValueError("invalid reason")
    return PromotionDecision(
        action=action,
        domain=domain,
        node_type=node_type,
        title=title.strip(),
        links=tuple(links),
        confidence=score,
        reason=" ".join(reason.split()),
    )


def judge_candidate(
    candidate: Candidate,
    search_results: Sequence[Mapping[str, object]],
    judge: Callable[[str], object],
) -> PromotionDecision:
    """Вызвать судью и отфильтровать links реальным множеством search id."""
    decision = parse_promotion_decision(
        judge(promotion_prompt(candidate, search_results)),
    )
    allowed = {
        item["id"]
        for item in search_results
        if isinstance(item.get("id"), str)
    }
    filtered: list[str] = []
    for node_id in decision.links:
        if node_id in allowed and node_id not in filtered:
            filtered.append(node_id)
    return PromotionDecision(
        action=decision.action,
        domain=decision.domain,
        node_type=decision.node_type,
        title=decision.title,
        links=tuple(filtered),
        confidence=decision.confidence,
        reason=decision.reason,
    )


def promoted_node_id(candidate_id: str, node_type: str) -> str:
    """Сохранить хвост mined-хэша, сменив тип ноды."""
    tail = candidate_id.rsplit(":", 1)[-1]
    if tail.startswith("mined-"):
        tail = tail[len("mined-"):]
    tail = re.sub(r"[^a-zA-Z0-9_-]", "-", tail).strip("-")
    if not tail:
        raise ValueError("candidate id has no hash tail")
    return f"{node_type}:mined-{tail}"


def promoted_body(
    candidate: Candidate,
    promoted_at: str,
    judge_confidence: float,
) -> str:
    """Добавить к statement явный блок провенанса."""
    frontmatter = candidate.frontmatter
    provenance = [
        "",
        "Провенанс:",
        f"- chat: {frontmatter.get('chat', '')}",
        "- message_ids: "
        + json.dumps(frontmatter.get("message_ids", []), ensure_ascii=False),
        f"- mined_at: {frontmatter.get('mined_at', '')}",
        f"- promoted_at: {promoted_at}",
        f"- judge_conf: {judge_confidence:.2f}",
    ]
    return candidate.body.rstrip() + "\n" + "\n".join(provenance).lstrip("\n") + "\n"


def append_state(
    path: Path,
    candidate_id: str,
    action: str,
    timestamp: str,
    to_id: str | None,
) -> None:
    """Append-only state для идемпотентности."""
    path.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "id": candidate_id,
        "action": action,
        "ts": timestamp,
        "to": to_id,
    }
    with path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(record, ensure_ascii=False) + "\n")


def write_report(
    path: Path,
    run_date: date,
    promoted: Sequence[tuple[str, str, PromotionDecision, str]],
    dropped: Sequence[tuple[str, PromotionDecision, str]],
    deferred: Sequence[tuple[str, PromotionDecision]],
    dry_run: bool,
) -> None:
    """Записать дневной promoted/dropped/deferred отчёт."""
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        f"# Mined promote — {run_date.isoformat()}",
        "",
        f"Режим: {'dry-run' if dry_run else 'apply'}.",
        "",
        "## Promoted",
        "",
    ]
    for candidate_id, new_id, decision, state in promoted:
        links = ", ".join(decision.links) or "none"
        lines.append(
            f"- [{state}] `{candidate_id}` → `{new_id}` ({decision.domain}), "
            f"judge={decision.confidence:.2f}, links={links}"
        )
    if not promoted:
        lines.append("_Нет._")
    lines += ["", "## Dropped", ""]
    for candidate_id, decision, state in dropped:
        lines.append(
            f"- [{state}] `{candidate_id}` — judge={decision.confidence:.2f}, "
            f"reason={decision.reason}"
        )
    if not dropped:
        lines.append("_Нет._")
    lines += ["", "## Deferred", ""]
    for candidate_id, decision in deferred:
        lines.append(
            f"- [deferred] `{candidate_id}` — judge={decision.confidence:.2f}, "
            f"reason={decision.reason}"
        )
    if not deferred:
        lines.append("_Нет._")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def run_promote(
    dreams_root: Path,
    *,
    apply: bool = False,
    min_conf: float = 0.85,
    max_promote: int = 5,
    judge_timeout: int = 45,
    judge_cmd: Sequence[str] = DEFAULT_JUDGE_CMD,
    judge: Callable[[str], object] | None = None,
    gateway: object | None = None,
    today: date | None = None,
) -> dict[str, object]:
    """Выполнить акт с инъекцией judge и MCP gateway для тестов."""
    run_date = today or datetime.now(timezone.utc).date()
    timestamp = datetime.now(timezone.utc).isoformat()
    state_path = dreams_root / "promote-log" / "decisions.jsonl"
    candidates = scan_candidates(
        dreams_root,
        min_conf,
        decisions_path=state_path,
    )
    selected = candidates[:max(0, max_promote)]
    active_gateway = gateway or FastMCPGateway()
    active_judge = judge or (
        lambda prompt: subprocess_judge(
            prompt,
            judge_cmd=judge_cmd,
            timeout=judge_timeout,
        )
    )
    promoted: list[tuple[str, str, PromotionDecision, str]] = []
    dropped: list[tuple[str, PromotionDecision, str]] = []
    deferred: list[tuple[str, PromotionDecision]] = []

    for candidate in selected:
        try:
            results = normalize_search_results(
                active_gateway.search(query=candidate.title, limit=5),
            )
            decision = judge_candidate(candidate, results, active_judge)
        except Exception as error:  # noqa: BLE001 — fail-open является контрактом
            print(
                f"mined-promote defer {candidate.id}: "
                f"{error.__class__.__name__}: {error}",
                file=sys.stderr,
            )
            decision = PromotionDecision(
                "defer",
                None,
                None,
                candidate.title,
                (),
                0.0,
                "judge error or invalid output",
            )

        if decision.action == "promote" and decision.confidence >= 0.7:
            assert decision.node_type is not None
            assert decision.domain is not None
            new_id = promoted_node_id(candidate.id, decision.node_type)
            if not apply:
                promoted.append((candidate.id, new_id, decision, "would-promote"))
                continue
            evidence = (
                f"mined-promote {run_date.isoformat()}, "
                f"judge={decision.confidence:.2f}"
            )
            try:
                active_gateway.add(
                    node={
                        "id": new_id,
                        "type": decision.node_type,
                        "title": decision.title,
                        "source": "miner",
                        "source_system": "msg-archive-miner",
                        "observed_at": timestamp,
                        "links": [],
                        "confidence": candidate.confidence,
                        "body": promoted_body(
                            candidate,
                            timestamp,
                            decision.confidence,
                        ),
                    },
                    root=decision.domain,
                )
                for target in decision.links:
                    active_gateway.link(
                        src_id=new_id,
                        rel="relates-to",
                        to_id=target,
                        evidence=evidence,
                    )
                active_gateway.link(
                    src_id=candidate.id,
                    rel="superseded-by",
                    to_id=new_id,
                    evidence=evidence,
                    at=run_date.isoformat(),
                )
            except Exception as error:  # noqa: BLE001 — запись не считается успешной
                print(
                    f"mined-promote write defer {candidate.id}: "
                    f"{error.__class__.__name__}: {error}",
                    file=sys.stderr,
                )
                failed = PromotionDecision(
                    "defer",
                    decision.domain,
                    decision.node_type,
                    decision.title,
                    decision.links,
                    decision.confidence,
                    "MCP write failed",
                )
                append_state(state_path, candidate.id, "defer", timestamp, None)
                deferred.append((candidate.id, failed))
                continue
            append_state(state_path, candidate.id, "promote", timestamp, new_id)
            promoted.append((candidate.id, new_id, decision, "promoted"))
        elif decision.action == "drop":
            if apply:
                append_state(state_path, candidate.id, "drop", timestamp, None)
            dropped.append(
                (candidate.id, decision, "dropped" if apply else "would-drop"),
            )
        else:
            if apply:
                append_state(state_path, candidate.id, "defer", timestamp, None)
            deferred.append((candidate.id, decision))

    report_path = dreams_root / "promote-log" / f"{run_date.isoformat()}.md"
    write_report(
        report_path,
        run_date,
        promoted,
        dropped,
        deferred,
        dry_run=not apply,
    )
    return {
        "scanned": len(candidates),
        "considered": len(selected),
        "promoted": sum(state == "promoted" for *_, state in promoted),
        "would_promote": sum(state == "would-promote" for *_, state in promoted),
        "dropped": len(dropped),
        "deferred": len(deferred),
        "dry_run": not apply,
        "report": str(report_path),
    }


def kill_switch_path() -> Path:
    return Path.home() / ".brain-dream" / "mined-promote-disabled"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", dest="apply", action="store_true")
    mode.add_argument("--dry-run", dest="apply", action="store_false")
    parser.set_defaults(apply=False)
    parser.add_argument("--min-conf", type=float, default=0.85)
    parser.add_argument("--max-promote", type=int, default=5)
    parser.add_argument("--judge-timeout", type=int, default=45)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Собрать production-зависимости и вывести компактный JSON."""
    disabled = kill_switch_path()
    if disabled.exists():
        print(json.dumps({"error": "guard_refused", "guard": str(disabled)}))
        return 2
    args = build_parser().parse_args(argv)
    try:
        result = run_promote(
            DREAMS,
            apply=args.apply,
            min_conf=args.min_conf,
            max_promote=args.max_promote,
            judge_timeout=args.judge_timeout,
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
