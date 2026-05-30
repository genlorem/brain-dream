# brain-dream: архитектура агентов

**Дата:** 2026-05-30
**Контекст:** Топ-10 сценариев (`brain-dream-30-scenarios.md`), фундамент #1 (orchestrator + skill plugins) + #4 (A2A через agent-mailbox). Здесь — детальный контракт.

---

## Цели

1. **Расширяемость**: добавить нового агента — один файл, без правки оркестратора.
2. **Изоляция отказов**: упавший агент не валит ночной сон.
3. **Тестируемость**: каждый агент — pure function на бумаге (`input.json → output.json + side-effect: git commit`).
4. **Безопасность через git**: все side-effects → commit; rollback одной командой; никаких незакоммиченных файлов в `~/brain/dreams/`.
5. **Используем существующее**: `agent-mailbox` уже работает у пользователя — не изобретаем bus.

## Не-цели

- Per-project агенты сейчас. Сначала функциональные — per-project только если докажет реальную нужду через KPI.
- Realtime между агентами. Async signaling достаточно.
- Распределённость. Все агенты живут на VPS (или маке) на одном хосте.

---

## Двухосевая модель координации

```
┌────────────────────────────────────────────────────────────────┐
│                  ОСЬ 1: SYNC ORCHESTRATION                    │
│                  (внутри одного прогона сна)                  │
│                                                               │
│   orchestrator ─stdin JSON──▶ agent-X ─stdout JSON──▶ orch    │
│       │                                                       │
│       └─ side-effect: git commit в репо                       │
└────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────┐
│                  ОСЬ 2: ASYNC SIGNALING                       │
│                  (между прогонами, между днями)               │
│                                                               │
│   agent-A ──mailbox_send──▶ inbox(agent-B)                    │
│   agent-B ──cron-tick──▶ mailbox_inbox(unread) ──▶ react      │
└────────────────────────────────────────────────────────────────┘
```

**Ось 1** — основной workflow. Сон-orchestrator подгружает агентов один за другим, передаёт им вход, ловит выход. Аналог CGI: stateless вызовы.

**Ось 2** — для «откладывания на потом». Introspector посмотрит свой inbox раз в неделю; KPI агрегатор получит ✅/❌ от TG-бота через mailbox.

---

## Plugin-интерфейс (контракт агента)

Каждый агент — исполняемый файл `agents/<name>.{sh|py|js}` со следующим контрактом:

### Вход — stdin (JSON)

```jsonc
{
  "version": "1",
  "agent_name": "dream-validator",
  "invoked_by": "orchestrator",        // или "cron", "mailbox", "manual"
  "dream_run_id": "dream-2026-05-30",   // null если не в контексте сна
  "task": "validate_candidates",        // конкретная задача
  "input": {
    // payload, специфичный для агента (см. ниже)
  },
  "config": {
    "model_budget_usd": 0.10,           // если агент тратит LLM
    "session_share_cap_pct": 5,         // если Sonnet
    "max_duration_s": 300,
    "dry_run": false                    // если true — не делать write-side-effects
  },
  "env": {
    "BRAIN_ROOT": "/home/gen/brain",
    "DREAM_NODE_ROOT": "/home/gen/brain/dreams",
    "BRAIN_DREAM_REPO": "/home/gen/Projects/brain-dream"
  }
}
```

### Выход — stdout (JSON, ровно одна строка JSON-объекта в конце или весь stdout)

```jsonc
{
  "version": "1",
  "agent_name": "dream-validator",
  "status": "ok",                       // "ok" | "skipped" | "failed"
  "duration_s": 12.3,
  "result": {
    // payload, специфичный для агента
  },
  "side_effects": [
    { "type": "git_commit", "sha": "abc123", "repo": "brain-dream", "files": ["..."] },
    { "type": "file_written", "path": "/home/gen/brain/dreams/.insight-hashes.jsonl" },
    { "type": "mailbox_sent", "to": "dream-introspector", "thread_id": "..." }
  ],
  "telemetry": {
    "llm_calls": [
      { "model": "gemini-3.5-flash", "input_tokens": 1500, "output_tokens": 200, "cost_usd": 0.0033, "via": "api" }
    ],
    "session_share_used_pct": 0,        // если Sonnet через подписку
    "guards_triggered": []              // если 5-layer что-то блокнули
  },
  "errors": [],
  "next_action_hint": "promote_to_permanent"  // опционально, для оркестратора
}
```

### stderr — только логи (структурированные, по строкам JSON)

```
{"ts":"2026-05-30T22:14:00Z","level":"INFO","msg":"start","agent":"dream-validator"}
{"ts":"2026-05-30T22:14:12Z","level":"WARN","msg":"low_confidence","insight_hash":"a3f1","value":0.42}
```

### Завершение

- `exit 0` — успех (даже если `status: "skipped"`).
- `exit 1` — внутренняя ошибка (panic/crash).
- `exit 2` — guard сработал (не ошибка агента, осознанный refuse).
- `exit 124` — таймаут (если оркестратор послал `SIGTERM`).

Orchestrator ловит non-zero exit, парсит stderr, продолжает сон без этого агента.

---

## Список первых агентов (функциональные роли)

| # | Имя | Зона ответственности | Вход (task) | Выход |
|---|---|---|---|---|
| 1 | `dream-orchestrator` | Сам сон (текущий `brain-dream.sh`). Координирует всех остальных. | (запуск из cron) | dream-нода + TG |
| 2 | `dream-validator` | Дедупликация инсайтов по content-hash, подсчёт confidence. | `task: dedup`, кандидаты | + обновлённые кандидаты |
| 3 | `dream-edge-builder` | Создаёт рёбра `relates-to` от dream-ноды к source-нодам в домене dreams. | `task: build_edges`, top-10 + source_ids | + патч ноды dream |
| 4 | `dream-promoter` | Раз в неделю двигает инсайты с `confidence ≥ 0.85` и `hit_count ≥ 3` в `dreams/permanent/`. | `task: promote_weekly` | git commit в dreams |
| 5 | `dream-critic` (Santa облегчённый) | Раз в неделю Sonnet валидирует кандидаты в permanent. | `task: critique`, набор кандидатов | actionable=Y/N для каждого |
| 6 | `dream-pruner` | Раз в месяц decay confidence по возрасту, архивирует устаревшее. | `task: prune_monthly` | git commit |
| 7 | `dream-introspector` | Раз в неделю анализирует свои dreams + код, предлагает 1–3 улучшения. | `task: introspect` | предложения в `proposals/` + mailbox для approve-gate |
| 8 | `notes-observer` | (Daemon/cron каждые 15 мин) fswatch `~/life/notes` → light Gemini → observation. | `task: observe`, batch | observation-нода в `dreams/observations/` |
| 9 | `tg-feedback-collector` | (Daemon) слушает callback от TG-бота, агрегирует ✅/❌/💡, пишет в KPI. | mailbox-driven | `dreams/.feedback.jsonl` |

**Не делаем сразу:**
- Per-project агенты (vipzal-agent, marquiz-agent). Если cross-проходы в этих доменах окажутся слабыми по KPI — добавим.
- `auto-patcher`. Сначала `introspector` должен 2–3 месяца показывать ценные предложения, тогда переходим к фактическим patches.

---

## Где живут агенты

- **`brain-dream.sh` orchestrator** — VPS cron 23:00 ALMT (как сейчас).
- **Per-run агенты (validator, edge-builder, critic, promoter, pruner)** — subprocess внутри orchestrator-прогона. `bash agents/dream-validator.sh < input.json > output.json`. Stateless.
- **Daemon-агенты (notes-observer, tg-feedback-collector)** — отдельный systemd-user service или cron каждые 15/60 мин. Стейт в `~/brain/dreams/.<agent>-state.json`.
- **Introspector** — cron раз в неделю, воскресенье 09:00 ALMT (= 04:00 UTC). Headless Claude (`claude -p`) с MCP `agent-mailbox` для отправки предложений в `gen`.

---

## Git-only writeback — закон

Каждый write-side-effect агента:
1. Сначала кладёт файл в working tree.
2. Затем `git add -A`.
3. `git commit -m "<agent>: <task> @ <dream-run-id>"`.
4. `git push origin main` (если репо имеет remote).

**Никаких side-files** в `~/brain/dreams/` помимо тех, что в git (или в `.gitignore` как явно непостоянные).

**Rollback** — `git -C <repo> revert <sha>`. Этого должно быть достаточно для отмены любой работы агента.

**Atomic guarantee**: либо весь side-effect закоммичен (видим в логе), либо ничего (агент крашнулся до commit — состояние не меняется).

---

## 5-layer guards — общая библиотека

Один файл `lib/guards.sh` (или `lib/guards.py`), подключаемый каждым агентом. Каждая функция возвращает `0 OK / 1 BLOCKED`:

```bash
# 1. source-filter: вход от того же агента игнорируется
guard_source_filter() { [ "$INVOKED_BY" != "$AGENT_NAME" ]; }

# 2. rate-limit: sliding window
guard_rate_limit() {
  # читает $AGENT_NAME.rate.jsonl за последние 60 мин
  # сравнивает с лимитом из config
}

# 3. cost-circuit-breaker: дневной бюджет
guard_cost_cb() {
  # читает $AGENT_NAME.cost.jsonl за UTC-день
  # если spent >= max_cost_usd → BLOCKED
}

# 4. depth-counter
guard_depth() { [ "${DEPTH:-0}" -lt 2 ]; }

# 5. kill-switch
guard_kill_switch() { [ ! -f "$HOME/.brain-dream/${AGENT_NAME}-disabled" ]; }

# AND-цепочка
guards_pass_all() {
  guard_source_filter && \
  guard_rate_limit && \
  guard_cost_cb && \
  guard_depth && \
  guard_kill_switch
}
```

В начале каждого агента:
```bash
source "$BRAIN_DREAM_REPO/lib/guards.sh"
if ! guards_pass_all; then
  log_block "$REASON"
  exit 2
fi
```

---

## A2A через agent-mailbox

Использование готовой инфры `~/Projects/agent-mailbox` (SQLite БД `~/.agent-mailbox/mailbox.db`):

### Регистрация brain-dream агентов

Каждый headless-агент (cron) при старте делает (через node CLI или direct SQLite):

```bash
mailbox_register({
  name: "dream-introspector",
  identity: "анализирует brain-dream и предлагает улучшения",
  role: "self-improvement",
  aliases: ["introspector"]
})
```

### Типичные сценарии async

- **introspector → gen**: `mailbox_send({from: "dream-introspector", to: "gen", text: "Предложение #42: ...", thread_id: "weekly-2026-W22"})`.
- **tg-feedback-collector → dream-orchestrator**: накопленный KPI за неделю.
- **dream-orchestrator → dream-critic**: «вот топ-10 за неделю, валидируй» (если не sync subprocess).

### Headless-агент проверяет inbox раз в час

Cron каждый час: `claude -p --output-format json '...prompt...' < /dev/null` с MCP `agent-mailbox` — спрашивает `mailbox_inbox(unread)` и реагирует.

**Альтернатива** для bash-агентов без Claude-сессии: CLI-обёртка `mailbox-cli.sh` напрямую читает SQLite. Это проще, дешевле, но без LLM-«мышления» агента. Для simple notifications хватает.

---

## MCP exposure (отложено)

Каждый агент мог бы быть и MCP-сервером (для вызова из любой Claude-сессии). Например: `dream_recall(topic: "VIP-7437")` → агент `dream-recall` достаёт из графа что сон знает о тикете.

**Когда добавлять:** после того, как агенты стабилизируются как plugin-интерфейс (≥ 2 месяца работы). До этого — преждевременная оптимизация.

---

## Структура репо `brain-dream`

```
brain-dream/
├── README.md
├── ARCHITECTURE.md
├── LICENSE
├── .gitignore
├── orchestrator/
│   ├── brain-dream.sh              # главный (текущий, поэтапно рефакторится)
│   ├── gemini.sh                   # перенесённый из ~/life/scripts
│   ├── dream-images.sh             # перенесённый
│   └── dream-should-run.sh         # adaptive trigger (фаза 1)
├── agents/
│   ├── dream-validator.sh
│   ├── dream-edge-builder.sh
│   ├── dream-promoter.sh
│   ├── dream-critic.sh
│   ├── dream-pruner.sh
│   ├── dream-introspector.sh
│   ├── notes-observer.sh
│   └── tg-feedback-collector.sh
├── lib/
│   ├── guards.sh                   # 5-layer
│   ├── scrub.sh                    # multi-secret-scrub
│   ├── json.sh                     # helpers для input/output JSON
│   ├── mailbox-cli.sh              # обёртка над SQLite mailbox
│   ├── content-hash.sh             # sha256 для дедапа
│   └── git-commit.sh               # atomic commit helper
├── docs/
│   ├── AGENT-CONTRACT.md           # подробный plugin-интерфейс
│   ├── BIOLOGICAL-MAPPING.md       # параллели с био-сном
│   ├── PHASES.md                   # roadmap-from-fabric фазы 1-8
│   └── SAFETY.md                   # 5-layer guards, секреты, rollback
├── proposals/                       # introspector кладёт сюда улучшения
│   └── .gitkeep
├── tests/
│   ├── test-orchestrator.sh
│   ├── test-validator.sh
│   └── test-guards.sh
├── config/
│   ├── defaults.env                 # дефолты всех DREAM_* env
│   └── cron.example                 # пример crontab строки
└── tools/
    └── install-vps.sh               # idempotent установка на VPS
```

---

## Установочный поток (на VPS)

1. `git clone git@github.com:genlorem/brain-dream.git ~/Projects/brain-dream`
2. `bash ~/Projects/brain-dream/tools/install-vps.sh`:
   - chmod +x всем `*.sh`
   - symlinks из `~/life/scripts/brain-dream.sh` → `~/Projects/brain-dream/orchestrator/brain-dream.sh` (на переходный период)
   - Обновляет crontab (бэкап старого) на путь к новому orchestrator
   - Регистрирует daemon-агентов в systemd-user (если уместно)

---

## Что **не** делаем

- **Не реализуем сразу всех 9 агентов**. План: orchestrator (рефактор существующего) + 2-3 функциональных + 1 introspector (минимум для self-improvement) — этого достаточно для первого месяца.
- **Не вынимаем `~/brain/` ноды в новый репо**. Данные — отдельно (в их доменных репо). Этот репо — только **код системы**.
- **Не делаем `auto-patcher`** в первой итерации. Сначала introspector + manual review.
- **Не делаем per-project агентов** до первых KPI.
