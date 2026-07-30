# dream-groom

Еженедельный акт находит значимые ноды без рёбер и разбирает свежие `edge-proposals`.
По умолчанию это dry-run: создаётся отчёт, но рёбра и ledger не меняются.
`--apply` разрешает auto-пары через MCP `brain_link`; лимит — 10 рёбер за прогон.

Флаги инструмента: `--min-sim 0.75`, `--auto-sim 0.90`, `--max-links 10`.
Также доступны `--top-neighbors 5` и `--proposals-days 30`.
Запускать нужно через `agents/dream-groom.sh`, передавая plugin-contract JSON в stdin.
Первые прогоны оставьте dry-run и проверьте кандидатов вручную.

Отчёт лежит в `$DREAM_NODE_ROOT/groom-reports/<YYYY-MM-DD>.md`.
В секции Auto видны применённые и ожидающие пары, в Propose — остальные.
У каждой строки указаны similarity и причина `orphan` либо `proposal-triage`.

Cron на `vps` (UTC), воскресенье 06:00, после `link-predict` в 05:30:
```cron
0 6 * * 0 flock -n /tmp/dream-groom.lock sh -c 'printf '"'"'{"config":{"dry_run":true}}'"'"' | ~/Projects/brain-dream/agents/dream-groom.sh >> ~/life/state/logs/dream-groom.log 2>&1'
```
После проверки замените `dry_run:true` на явное `dry_run:false`.
Для отката найдите ребро по evidence `dream-groom <date> auto` и снимите его вручную.
Kill-switch: `touch ~/.brain-dream/dream-groom-disabled`; возврат: удалить этот файл.
