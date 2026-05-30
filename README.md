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

- ✅ Working orchestrator with money cap (`~/life/scripts/brain-dream.sh`, will migrate here)
- ✅ Single TG output, Dream node in isolated `dreams` domain
- ✅ Gemini vs Sonnet experiment infrastructure (correct subscription-vs-API accounting)
- 🚧 Repo scaffolding (this phase)
- 📝 Roadmap: 8 phases in [`docs/01-from-fabric.md`](docs/01-from-fabric.md)
- 📝 30 expansion scenarios + top-10 in [`docs/02-top-scenarios.md`](docs/02-top-scenarios.md)
- 📝 Agent plugin contract in [`docs/03-agents-architecture.md`](docs/03-agents-architecture.md)

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
