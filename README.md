# brain-dream

> Synthetic «sleep» over a personal knowledge graph: every night an orchestrator dreams over your Markdown nodes, finds patterns through 8 conceptual lenses, synthesizes a top-10, and delivers a single Telegram photo-message — while staying within a hard cost cap and producing a permanent, git-tracked record.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Status](https://img.shields.io/badge/status-phase--0--scaffolding-orange)

---

## What it does

- **Reads** Markdown nodes from `~/brain/<domain>/nodes/` (multiple isolated domain repos).
- **Runs** N Gemini passes through 8 lenses (problem, gap, contradiction, stalled, cross-analogy, risk, opportunity, wow) with cross-domain bridging every 5th pass.
- **Synthesizes** the top-10 with Claude.
- **Optionally validates** with Sonnet (lightweight Santa-pattern, weekly).
- **Writes** results as `dream:<date>` node in an isolated `dreams` domain (never touches source domains).
- **Sends** one Telegram message: cover image (Higgsfield) + top-10 caption.
- **Caps spend** to a real-money limit on Gemini (default $0.50/night) and a session-share limit on Sonnet (default 30% of Max plan 5h window).

## Architecture in two sentences

1. **Sync axis** — orchestrator dispatches subprocess agents with JSON in/out; every side-effect lands as a git commit.
2. **Async axis** — agents talk across days via `agent-mailbox` (SQLite-backed).

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the contract and [`docs/`](docs/) for the design history.

## Why

The biological analogue of sleep is **active**: hippocampal replay, synaptic homeostasis, schema integration. Our first iteration was read-only. This repo is the migration path toward an active, multi-phase, multi-agent system that can safely modify a knowledge graph through git-mediated, fully-revertable writebacks.

## Current status (2026-05-30)

### Orchestrator (`orchestrator/`)
- ✅ Adaptive trigger (`dream-should-run.sh`) — runs only on threshold time or new-nodes accumulation.
- ✅ Recency-weighted sampling (90% NREM / 70% REM bias toward freshly modified nodes).
- ✅ Money cap (Gemini real API) + session-share cap (Sonnet via subscription).
- ✅ NREM + REM phases — narrow consolidation (lens problem/gap/stalled) + wide creative (cross-analogy/wow/opportunity/risk).
- ✅ Content-hash dedup across nights + insight registry (`.insight-hashes.jsonl`).
- ✅ Confidence scoring (0.3–1.0) on every insight + bump on repeat.
- ✅ Provenance per insight (dream_id, iteration, lens, mode, source nodes, model, prompt version).
- ✅ Active consolidation: `relates-to` + `continues-in` (Jaccard ≥ 0.3) edges in dream nodes (isolated `dreams` domain — never mutates source nodes).
- ✅ Single TG photo-message output (cover + top-10 caption).
- ✅ Synthesis input pruning (top-N candidates by confidence — from introspector proposal #2).

### Agents (`agents/`)
- ✅ `dream-introspector` — weekly self-improvement loop (analyzes own dreams + code → proposes improvements). Plugin contract. Guards.
- ✅ `dream-critic` — weekly Sonnet validator → promotion to `dreams/permanent/`. Plugin contract. Guards.

### Library (`lib/`)
- ✅ `content-hash.sh` — normalize + sha256-16 for insight dedup.
- ✅ `insight-hashes.sh` — registry manager (has/bump/append/compact).
- ✅ `guards.sh` — 5-layer protection for all agents (source-filter / rate-limit / cost-cb / depth / kill-switch).

### Tools (`tools/`)
- ✅ `dream-feedback` — CLI for marking insights useful/noise/known. KPI loop closure. On a `useful` verdict (interactive) it offers to promote the insight.
- ✅ `dream-promote` — turns one synthesized top-10 insight into a real Brain node (decision/lesson/note/procedure) in the right domain, auto-linked to the insight's sources and to the dream (`derived-from`). The bridge "dream noticed → graph uses it"; addressed by `date#N`, not content-hash. Git-committed in the target domain repo; needs a `brain_reindex` to surface.

### Cron schedule (UTC)
| When | What |
|---|---|
| Daily 18:00 | Adaptive sleep (only runs if threshold met) |
| Sunday 04:00 | dream-introspector |
| Sunday 12:00 | dream-critic |

### Design history (`docs/`)
- 📝 [01-from-fabric.md](docs/01-from-fabric.md) — extracted ideas from Fabric autoDream phase 5
- 📝 [02-top-scenarios.md](docs/02-top-scenarios.md) — 30 scenarios scored, top-10 with dependency graph
- 📝 [03-agents-architecture.md](docs/03-agents-architecture.md) — detailed plugin contract

### Not yet
- 📋 Continuous-learning daytime observer (fswatch → light Gemini → observations)
- 📋 Pruning agent (decay by confidence × age)
- 📋 Auto-patcher (introspector → real PRs)
- 📋 MCP exposure for agents (callable from any Claude session)
- 📋 TG inline-button KPI (currently via `dream-feedback` CLI)
- 📋 Dreams domain registration in MCP brain (`TM_BRAIN_ROOTS` + reindex) — one-time operator step

## Repo layout

```
brain-dream/
├── orchestrator/    # main dream-runner + helpers
├── agents/          # plugin-style agents (one file each)
├── lib/             # shared bash libs (guards, scrub, json, mailbox-cli, git-commit)
├── docs/            # design history (numbered)
├── proposals/       # introspector dropzone for self-improvement PRs
├── tests/           # bats / shell tests
├── config/          # defaults.env, cron.example
└── tools/           # install-vps.sh, migration helpers
```

## Quick start (operator)

Not yet — phase 0 is repo scaffolding. Migration of working code from `~/life/scripts/` happens in the next phase.

## Safety principles

- **Read-only on source domains** (`travelmart`, `personal`, `marquiz`, etc.). All writes go to the isolated `dreams` domain.
- **Git-only writeback** — every agent side-effect is a commit; rollback via `git revert`.
- **5-layer guards** before any autonomous loop (source-filter / rate-limit / cost-CB / depth ≥ 2 / kill-switch file).
- **Secret-scrubbing** on every write-path to brain (extended Fabric MEM-07 patterns).
- **Money cap** (Gemini API $) + **session-share cap** (Sonnet via Claude Code subscription).

## License

MIT. See [`LICENSE`](LICENSE).
