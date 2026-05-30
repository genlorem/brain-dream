# Architecture

Compact spec. Full design history in [`docs/`](docs/).

## Two coordination axes

```
┌────────────────────────────────────────────────────────────────┐
│  AXIS 1: SYNC ORCHESTRATION  (inside a single nightly run)    │
│                                                               │
│  orchestrator ──stdin JSON──▶ agent ──stdout JSON──▶ orch     │
│       │                                                       │
│       └─ side-effect: git commit                              │
└────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│  AXIS 2: ASYNC SIGNALING  (across days, between agents)       │
│                                                               │
│  agent-A ──mailbox_send──▶ inbox(agent-B)                     │
│  agent-B ──cron tick──▶ mailbox_inbox(unread) ──▶ react       │
└────────────────────────────────────────────────────────────────┘
```

## Agent plugin contract

Each agent is an executable file in `agents/<name>.{sh|py|js}`.

**Input** (stdin, single-line JSON object or full JSON document):

```json
{
  "version": "1",
  "agent_name": "dream-validator",
  "invoked_by": "orchestrator",
  "dream_run_id": "dream-2026-05-30",
  "task": "dedup",
  "input": { ... },
  "config": {
    "model_budget_usd": 0.10,
    "session_share_cap_pct": 5,
    "max_duration_s": 300,
    "dry_run": false
  },
  "env": {
    "BRAIN_ROOT": "/home/gen/brain",
    "DREAM_NODE_ROOT": "/home/gen/brain/dreams",
    "BRAIN_DREAM_REPO": "/home/gen/Projects/brain-dream"
  }
}
```

**Output** (stdout, one JSON object):

```json
{
  "version": "1",
  "agent_name": "dream-validator",
  "status": "ok",
  "duration_s": 12.3,
  "result": { ... },
  "side_effects": [
    { "type": "git_commit", "sha": "abc123", "repo": "brain-dream", "files": ["..."] }
  ],
  "telemetry": {
    "llm_calls": [{ "model": "...", "input_tokens": N, "output_tokens": N, "cost_usd": N, "via": "api|subscription" }],
    "session_share_used_pct": 0,
    "guards_triggered": []
  },
  "errors": [],
  "next_action_hint": null
}
```

**stderr** — structured JSON-per-line logs.

**Exit codes**:
- `0` — success (even if `status: "skipped"`)
- `1` — internal error
- `2` — guard refused
- `124` — timeout (SIGTERM from orchestrator)

## First agents (functional roles)

| Name | Role | Trigger |
|---|---|---|
| `dream-orchestrator` | The nightly run (current `brain-dream.sh` → migrated) | cron 23:00 ALMT |
| `dream-validator` | Content-hash dedup + confidence aggregation | sync, inside run |
| `dream-edge-builder` | Builds `relates-to` edges in `dreams` domain | sync, inside run |
| `dream-promoter` | Moves confidence ≥ 0.85 & hits ≥ 3 to `dreams/permanent/` | weekly cron |
| `dream-critic` | Lightweight Santa: Sonnet validates top-10 weekly | weekly cron |
| `dream-pruner` | Decays old/low-confidence insights, archives | monthly cron |
| `dream-introspector` | Reads dreams + own code, proposes 1-3 improvements | weekly cron |
| `notes-observer` | fswatch `~/life/notes` → observations | daemon (15 min cron) |
| `tg-feedback-collector` | Listens to ✅/❌/💡 callbacks from TG bot | daemon |

Per-project agents (vipzal-, marquiz-, etc.) — **not yet**, only if KPI shows weakness in those domains.

## Safety layers

### 1. Read-only on source domains
Source-of-truth knowledge nodes (`~/brain/travelmart/`, etc.) are never modified. All writes land in the isolated `~/brain/dreams/` repo.

### 2. Git-only writeback
Every write side-effect of every agent is a git commit. `git revert <sha>` rolls back. No untracked working-tree garbage.

### 3. 5-layer guards (lib/guards.sh)
AND-chain. Failure of any one blocks the agent.

| Guard | Mechanism | Default |
|---|---|---|
| source-filter | reject input from own agent type | always on |
| rate-limit | sliding window | ≤ 3 calls / hour |
| cost-circuit-breaker | daily USD cap per agent | $0.10/day |
| depth-counter | reject depth ≥ 2 | always on |
| kill-switch | check `~/.brain-dream/<agent>-disabled` | check every tick |

### 4. Secret scrub (lib/scrub.sh)
On every write-path to `~/brain/`. Extended Fabric MEM-07 patterns: Anthropic, AWS, GitHub, Slack, JWT, Bearer, high-entropy base64.

### 5. Budget caps
- Gemini: real-money cap from `DREAM_COST_LIMIT_USD` (default $0.50/night).
- Sonnet: session-share cap from `DREAM_SONNET_SESSION_CAP_PCT` (default 30% of Max 5h window).

## Phased rollout

See [`docs/01-from-fabric.md`](docs/01-from-fabric.md) §Roadmap-фазы.

Top-10 expansion scenarios in [`docs/02-top-scenarios.md`](docs/02-top-scenarios.md).

Plugin contract detail in [`docs/03-agents-architecture.md`](docs/03-agents-architecture.md).
