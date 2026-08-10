#!/usr/bin/env python3
"""Офлайн-тесты brain-improver без pytest и сети."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
TEST_ROOT = ROOT / "tests" / "improver"
FIXTURES = TEST_ROOT / "fixtures"
STUBS = TEST_ROOT / "stubs"


def run(
    *args: str, env: dict[str, str] | None = None, check: bool = True
) -> subprocess.CompletedProcess[str]:
    merged = os.environ.copy()
    if env:
        merged.update(env)
    result = subprocess.run(
        [str(value) for value in args],
        cwd=ROOT,
        env=merged,
        capture_output=True,
        text=True,
        check=False,
    )
    if check and result.returncode != 0:
        raise AssertionError(
            f"command failed ({result.returncode}): {args}\n"
            f"stdout={result.stdout}\nstderr={result.stderr}"
        )
    return result


def write_config(tmp: Path, **overrides: object) -> Path:
    config = json.loads((ROOT / "config" / "improver.json").read_text(encoding="utf-8"))
    config["paths"] = {
        "effectiveness": str(FIXTURES / "effectiveness.ndjson"),
        "nudgeTuner": str(tmp / "nudge.ndjson"),
        "coverageTuner": str(tmp / "coverage.ndjson"),
        "outcome": str(tmp / "outcome.ndjson"),
        "seen": str(tmp / "_seen.jsonl"),
        "ledger": str(tmp / "improver-ledger.ndjson"),
        "reportsDir": str(tmp / "reports"),
    }
    config.update(overrides)
    path = tmp / "improver.json"
    path.write_text(json.dumps(config, ensure_ascii=False), encoding="utf-8")
    return path


def test_aggregate(tmp: Path) -> None:
    config = write_config(tmp)
    result = run(
        sys.executable,
        ROOT / "tools" / "improver-aggregate.py",
        "--config",
        config,
    )
    rows = json.loads(result.stdout)
    kinds = [row["kind"] for row in rows]
    assert kinds == [
        "nudge-declined",
        "stagnation",
        "coverage-judge-gap",
        "judge-latency",
    ], rows
    ranks = [round(row["severity"] * row["count"], 3) for row in rows]
    assert ranks == sorted(ranks, reverse=True), ranks
    assert rows[0]["evidence"]["keyword"] == "noisy"
    assert rows[2]["evidence"]["node_ids"] == ["node-a", "node-b"]
    assert rows[3]["evidence"]["p90_ms"] == 2000


def test_github_search(tmp: Path) -> None:
    config = write_config(
        tmp, github={"minStars": 5, "maxAgeDays": 365, "perQuery": 2}
    )
    hypotheses = tmp / "hypotheses.json"
    hypotheses.write_text(
        json.dumps(
            [
                {
                    "id": "h1",
                    "kind": "idea",
                    "signal": None,
                    "hypothesis": "test",
                    "keywords": ["memory graph", "second brain"],
                    "domainTerms": ["memory", "knowledge graph", "second brain"],
                    "negativeTerms": ["backup", "restic", "network", "pentest"],
                }
            ]
        ),
        encoding="utf-8",
    )
    env = {
        "GH_BIN": str(STUBS / "gh"),
        "GH_STUB_RESPONSE": str(FIXTURES / "github-results.json"),
    }
    first = run(
        ROOT / "tools" / "improver-github-search.sh",
        hypotheses,
        "2026-07-30",
        config,
        env=env,
    )
    rows = json.loads(first.stdout)
    names = [row["fullName"] for row in rows[0]["candidates"]]
    assert names == ["example/graph-memory-pro", "example/reference"], rows
    assert len(names) == 2
    assert not any(name.startswith("noise/") for name in names)
    seen_lines = (tmp / "_seen.jsonl").read_text(encoding="utf-8").splitlines()
    assert len(seen_lines) == 2

    second = run(
        ROOT / "tools" / "improver-github-search.sh",
        hypotheses,
        "2026-07-31",
        config,
        env=env,
    )
    repeated = json.loads(second.stdout)
    repeated_names = [row["fullName"] for row in repeated[0]["candidates"]]
    assert repeated_names == ["example/good", "example/second-brain"], repeated
    assert set(names).isdisjoint(repeated_names)
    seen = [json.loads(line) for line in (tmp / "_seen.jsonl").read_text().splitlines()]
    assert {row["last_seen"] for row in seen} == {"2026-07-31"}

    # Старый формат без domainTerms/negativeTerms остаётся рабочим и не включает gate.
    legacy_tmp = tmp / "legacy"
    legacy_tmp.mkdir()
    legacy_config = write_config(
        legacy_tmp, github={"minStars": 5, "maxAgeDays": 365, "perQuery": 5}
    )
    legacy_hypotheses = legacy_tmp / "hypotheses.json"
    legacy_hypotheses.write_text(
        '[{"id":"legacy","keywords":["memory graph"]}]', encoding="utf-8"
    )
    legacy = run(
        ROOT / "tools" / "improver-github-search.sh",
        legacy_hypotheses,
        "2026-07-30",
        legacy_config,
        env=env,
    )
    legacy_names = [
        row["fullName"] for row in json.loads(legacy.stdout)[0]["candidates"]
    ]
    assert len(legacy_names) == 5
    assert "noise/restic-memory" in legacy_names
    assert "noise/network-graph" in legacy_names


def test_llm_wrappers(tmp: Path) -> None:
    config = write_config(tmp)
    signals = tmp / "signals.json"
    signals.write_text(
        '[{"id":"coverage-judge-gap-x","kind":"coverage-judge-gap",'
        '"severity":2,"evidence":{"raw":"`$HOME` \\"цитата\\""},"count":3}]',
        encoding="utf-8",
    )
    args_file = tmp / "claude-args.txt"
    prompt_file = tmp / "claude-prompt.txt"
    common_env = {
        "CLAUDE_BIN": str(STUBS / "claude"),
        "CLAUDE_ARGS_FILE": str(args_file),
        "CLAUDE_PROMPT_FILE": str(prompt_file),
        "CLAUDE_STUB_RESPONSE": str(FIXTURES / "hypothesize-response.txt"),
    }
    result = run(
        ROOT / "tools" / "improver-hypothesize.sh",
        signals,
        "1",
        config,
        env=common_env,
    )
    hypotheses = json.loads(result.stdout)
    assert [row["id"] for row in hypotheses] == ["err-gap", "idea-links"]
    assert args_file.read_text().strip() == (
        "-p --model claude-haiku-4-5 --no-session-persistence"
    )
    prompt = prompt_file.read_text(encoding="utf-8")
    assert "`$HOME`" in prompt and "цитата" in prompt
    assert "2–4 КОНКРЕТНЫХ многословных" in prompt
    assert "domainTerms" in prompt and "negativeTerms" in prompt
    assert all(row.get("domainTerms") for row in hypotheses)

    hypotheses_path = tmp / "llm-hypotheses.json"
    candidates_path = tmp / "llm-candidates.json"
    hypotheses_path.write_text(json.dumps(hypotheses, ensure_ascii=False), encoding="utf-8")
    candidates_path.write_text(
        json.dumps(
            [
                {
                    "hypothesisId": row["id"],
                    "candidates": [
                        {
                            "fullName": "example/good",
                            "url": "https://github.com/example/good",
                            "description": "LLM memory knowledge graph",
                        }
                    ],
                }
                for row in hypotheses
            ]
        ),
        encoding="utf-8",
    )
    eval_env = dict(common_env)
    eval_env["CLAUDE_STUB_RESPONSE"] = str(FIXTURES / "evaluate-response.txt")
    evaluated = run(
        ROOT / "tools" / "improver-evaluate.sh",
        hypotheses_path,
        candidates_path,
        env=eval_env,
    )
    verdicts = json.loads(evaluated.stdout)
    assert [row["verdict"] for row in verdicts] == ["config-tune", "reject"]
    assert [row["integrationCost"] for row in verdicts] == ["S", "L"]
    assert verdicts[1]["bestCandidate"] is None
    eval_prompt = prompt_file.read_text(encoding="utf-8")
    assert "integrationCost S или M" in eval_prompt
    assert "нет релевантных готовых решений" in eval_prompt

    # Пустая выдача принудительно даёт reject, даже если стаб предлагает иное.
    candidates_path.write_text("[]", encoding="utf-8")
    no_candidates = run(
        ROOT / "tools" / "improver-evaluate.sh",
        hypotheses_path,
        candidates_path,
        env=eval_env,
    )
    empty_verdicts = json.loads(no_candidates.stdout)
    assert all(row["verdict"] == "reject" for row in empty_verdicts)
    assert all(
        row["rationale"] == "нет релевантных готовых решений"
        for row in empty_verdicts
    )


def test_report_and_ledger(tmp: Path) -> None:
    config = write_config(tmp)
    signals = tmp / "report-signals.json"
    hypotheses = tmp / "report-hypotheses.json"
    candidates = tmp / "report-candidates.json"
    verdicts = tmp / "report-verdicts.json"
    actions = tmp / "report-actions.json"
    signals.write_text(
        '[{"id":"s1","kind":"stagnation","severity":2,"evidence":{},"count":3}]'
    )
    hypotheses.write_text(
        '[{"id":"h1","kind":"idea","signal":null,'
        '"hypothesis":"Новая идея","keywords":["second brain"]}]'
    )
    candidates.write_text(
        '[{"hypothesisId":"h1","candidates":[{"fullName":"example/good",'
        '"url":"https://github.com/example/good","stars":50,'
        '"pushedAt":"2026-06-01T00:00:00Z","license":"mit","description":"x"}]}]'
    )
    verdicts.write_text(
        '[{"hypothesisId":"h1","verdict":"config-tune","target":"threshold",'
        '"rationale":"Обратимо","bestCandidate":null}]'
    )
    actions.write_text(
        '[{"hypothesisId":"h1","action":"recommend","summary":"рекомендовано Tier-1"}]'
    )
    command = [
        sys.executable,
        ROOT / "tools" / "improver-report.py",
        "--date",
        "2026-07-30",
        "--config",
        config,
        "--signals",
        signals,
        "--hypotheses",
        hypotheses,
        "--candidates",
        candidates,
        "--verdicts",
        verdicts,
        "--actions",
        actions,
    ]
    first = run(*command)
    second = run(*command)
    report = Path(first.stdout.strip())
    assert report == Path(second.stdout.strip()) and report.exists()
    body = report.read_text(encoding="utf-8")
    assert "https://github.com/example/good" in body
    ledger_lines = (tmp / "improver-ledger.ndjson").read_text().splitlines()
    assert len(ledger_lines) == 1, ledger_lines
    assert json.loads(ledger_lines[0])["hypothesisId"] == "h1"


def test_fail_open_and_disabled(tmp: Path) -> None:
    broken = tmp / "broken.json"
    broken.write_text("{broken", encoding="utf-8")
    claude_marker = tmp / "claude-was-called"
    env = {
        "CLAUDE_BIN": str(STUBS / "claude"),
        "CLAUDE_ARGS_FILE": str(claude_marker),
        "CLAUDE_STUB_RESPONSE": str(FIXTURES / "hypothesize-response.txt"),
    }
    bad_hyp = run(
        ROOT / "tools" / "improver-hypothesize.sh",
        broken,
        "1",
        broken,
        env=env,
    )
    assert bad_hyp.returncode == 0 and json.loads(bad_hyp.stdout) == []
    assert not claude_marker.exists()

    disabled = write_config(tmp, enabled=False)
    disabled_result = run(
        ROOT / "orchestrator" / "brain-improver.sh",
        "2026-07-30",
        env={
            **env,
            "BRAIN_IMPROVER_CONFIG": str(disabled),
            "BRAIN_IMPROVER_LOCK": str(tmp / "disabled.lock"),
        },
    )
    assert disabled_result.returncode == 0
    assert not claude_marker.exists()
    assert not (tmp / "reports").exists()

    bad_search = run(
        ROOT / "tools" / "improver-github-search.sh",
        broken,
        "not-a-date",
        disabled,
        env={
            "GH_BIN": str(STUBS / "gh"),
            "GH_STUB_RESPONSE": str(FIXTURES / "github-results.json"),
        },
    )
    assert bad_search.returncode == 0 and json.loads(bad_search.stdout) == []


def test_orchestrator_enabled(tmp: Path) -> None:
    config = write_config(tmp, maxHypotheses=2)
    proposals_dir = tmp / "proposals"
    result = run(
        ROOT / "orchestrator" / "brain-improver.sh",
        "2026-07-30",
        env={
            "BRAIN_IMPROVER_CONFIG": str(config),
            "BRAIN_IMPROVER_LOCK": str(tmp / "enabled.lock"),
            "CLAUDE_BIN": str(STUBS / "claude"),
            "CLAUDE_STUB_HYPOTHESIZE_RESPONSE": str(
                FIXTURES / "hypothesize-response.txt"
            ),
            "CLAUDE_STUB_EVALUATE_RESPONSE": str(
                FIXTURES / "orchestrator-evaluate-response.txt"
            ),
            "GH_BIN": str(STUBS / "gh"),
            "GH_STUB_RESPONSE": str(FIXTURES / "github-results.json"),
            "GIT_BIN": "/bin/true",
            "IMPROVER_PROPOSALS_DIR": str(proposals_dir),
        },
    )
    assert result.returncode == 0, result.stderr
    report = tmp / "reports" / "improver-2026-07-30.md"
    proposal = proposals_dir / "err-gap.md"
    draft = proposals_dir / "err-gap-draft-pr.md"
    assert report.exists() and proposal.exists() and draft.exists()
    proposal_body = proposal.read_text(encoding="utf-8")
    assert (
        "https://github.com/example/good" in proposal_body
        and "0123456789abcdef0123456789abcdef01234567" in proposal_body
    )
    assert "Автоматический merge запрещён" in proposal_body
    records = (proposals_dir / "_proposals.ndjson").read_text().splitlines()
    assert len(records) == 1
    record = json.loads(records[0])
    assert record["action"] == "prepare-integration"
    assert record["branchStatus"] == "создана"


def main() -> int:
    tests = [
        test_aggregate,
        test_github_search,
        test_llm_wrappers,
        test_report_and_ledger,
        test_fail_open_and_disabled,
        test_orchestrator_enabled,
    ]
    with tempfile.TemporaryDirectory(prefix="brain-improver-tests.") as raw_tmp:
        base = Path(raw_tmp)
        for test in tests:
            case_tmp = base / test.__name__
            case_tmp.mkdir()
            test(case_tmp)
            print(f"PASS {test.__name__}")
    print(f"PASS all ({len(tests)} tests)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
