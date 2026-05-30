# agents/

Plugin-style агенты brain-dream. Все следуют [plugin contract v1](../ARCHITECTURE.md#agent-plugin-contract).

## Текущие агенты

| Файл | Роль | Триггер | Cost guard | Rate-limit |
|---|---|---|---|---|
| [`dream-introspector.sh`](dream-introspector.sh) | Анализирует свои сны и код, предлагает 1-3 улучшения | Sunday 04:00 UTC | $0.30/day | 1/12h |
| [`dream-critic.sh`](dream-critic.sh) | Sonnet-валидатор инсайтов из registry; промотирует прошедших в `dreams/permanent/` | Sunday 12:00 UTC | $0.50/day | 1/12h |

## Общий контракт (cheat sheet)

**Вход** — stdin JSON:
```json
{
  "invoked_by": "cron|manual|orchestrator",
  "config": {"dry_run": false, "model_budget_usd": 0.30},
  "input": {"depth": 0}
}
```

**Выход** — stdout JSON с `status`, `side_effects`, `telemetry`.

**Логи** — stderr, structured JSON-per-line.

**Exit codes:** 0 ok/skipped, 1 internal error, 2 guard refused.

## Guards (общая защита)

Каждый агент source'ит `lib/guards.sh` и вызывает `guards_pass_all` перед началом работы. См. [`../lib/guards.sh`](../lib/guards.sh) — 5-layer AND-chain (source-filter, rate-limit, cost-cb, depth, kill-switch).

## Disabling an agent

```bash
touch ~/.brain-dream/<agent-name>-disabled
```

Этот файл проверяется при каждом тике guard_kill_switch — если есть, агент моментально exit 2.

## Adding a new agent

1. Создать `agents/<name>.sh` следуя контракту.
2. `chmod +x` и `git update-index --chmod=+x`.
3. Установить env-параметры (GUARD_COST_DAILY_USD, GUARD_RATE_LIMIT_*).
4. Source `lib/guards.sh` и вызвать `guards_pass_all`.
5. После LLM-вызовов — `guard_record_cost $cost_usd` для cost-circuit-breaker.
6. Cron-строка (если нужен периодический запуск).
7. Добавить запись в эту таблицу.
