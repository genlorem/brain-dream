# mined-promote

Ночной акт переносит устойчивые `mined-candidate` из dreams в боевые домены.
Сканируются `nodes/*.md` с confidence не ниже `--min-conf 0.85`.
`promote` и `drop` из `promote-log/decisions.jsonl` обеспечивают идемпотентность.
Для каждого кандидата `brain_search` даёт судье до пяти дедуп-контекстов.
Судья выбирает promote/drop/defer, домен, тип, заголовок и связи.
Связи фильтруются: допустимы только id из результатов этого поиска.
Промоушен требует judge confidence ≥0.7 и ограничен `--max-promote 5`.
Новая нода получает `source_system: msg-archive-miner` и блок провенанса.
Кандидат остаётся в dreams со связью `superseded-by` на новую ноду.
По умолчанию dry-run: MCP и `decisions.jsonl` не меняются.
Отчёт пишется в `promote-log/<YYYY-MM-DD>.md` с меткой `would-promote`.
Боевой запуск требует явного `--apply`; ошибки и таймауты дают defer.

Cron на `vps` (UTC), ежедневно в 04:40:
```cron
40 4 * * * flock -n /tmp/mined-promote.lock ~/brain/engine/.venv/bin/python ~/Projects/brain-dream/tools/mined-promote.py --apply >> ~/life/state/logs/mined-promote.log 2>&1
```

Kill-switch: `touch ~/.brain-dream/mined-promote-disabled`.
Возврат: удалить kill-switch и запустить акт снова.
Для отката найдите ноду по `source_system` и рёбра по evidence `mined-promote`.
Удаление или revert делайте git-коммитом в выбранном боевом домене.
