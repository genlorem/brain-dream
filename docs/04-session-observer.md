# SPEC — `session-observer` agent

> Observer-агент brain-dream: периодически дистиллирует находки из **файлов сессий Claude Code** (`~/.claude/projects/**/*.jsonl`) в Brain. Детерминированная (cron) замена ручной природы `/learn`. Аналог `notes-observer`, но источник — транскрипты сессий.

## 1. Назначение

Автоматический **слой захвата** опыта из сессий, не зависящий от того, вызовет ли модель `/learn`. `/learn` остаётся опциональным ручным/глубоким проходом «здесь и сейчас»; `session-observer` — базовый стабильный слой по расписанию.

Граница слоёв (не нарушать):
- **захват** (этот агент + /learn) → новые узлы;
- **синтез** (`brain-dream.sh`, 8 линз) → `dream:` инсайты над уже захваченными узлами.

## 2. Триггер

- Cron, по умолчанию **каждые 6 ч** (настраиваемо `SESSION_OBSERVER_INTERVAL`). Не nightly — чтобы находки попадали в Brain в тот же день и были доступны ближайшему `brain-dream.sh`.
- Обрабатываются только **финализированные** сессии: `.jsonl` с `mtime` старше `SESSION_IDLE_MIN` (default 30 мин) — чтобы не трогать активную/текущую сессию.
- Адаптивный skip (по образцу `dream-should-run.sh`): если нет новых необработанных байт ни в одной сессии — выходим со `status: skipped`, без LLM-вызовов.

## 3. Контракт (по `ARCHITECTURE.md`)

stdin JSON (`task: "observe-sessions"`), stdout один JSON-объект со `status/result/side_effects/telemetry`. Все write-side-effects — git-commit в `dreams`-репо. stderr — JSON-per-line.

## 4. Источник и курсор (инкрементальность)

Стейт: `~/brain/dreams/.session-observer-cursor.jsonl` — по строке на сессию:
```json
{"session_id":"<uuid>","path":"...","processed_through_msg":<int>,"bytes":<int>,"last_seen_mtime":"<ISO>","status":"partial|done"}
```
- Для каждой подходящей `.jsonl`: читаем сообщения **с индекса `processed_through_msg`** до конца. Полностью обработанные (`status:done`, mtime не изменился) — пропускаем без чтения тела.
- Парсинг: брать user/assistant `text`-блоки и tool-выводы с ошибками/поворотами (как делает текущий `/learn` при анализе сессии). Большие tool-дампы усекать.

## 5. Дедуп с `/learn` — ДВА уровня (ключевое требование)

### Уровень 1 — learn-ledger (быстрый skip уже зафиксированного)

`/learn` при каждом запуске **дописывает** в `~/brain/dreams/.learn-ledger.jsonl`:
```json
{"session_id":"<uuid>","path":"...","processed_through_msg":<int>,
 "node_ids":["decision:...","lesson:..."],
 "content_hashes":["<h1>","<h2>"],"captured_at":"<ISO>"}
```
`session-observer` для каждой сессии:
- сдвигает нижнюю границу чтения до **max(`cursor.processed_through_msg`, `ledger.processed_through_msg`)** → куски, которые `/learn` уже разобрал, **не перечитываются и не отправляются в LLM** (экономия + нет дублей на уровне диапазона).

### Уровень 2 — content-hash + семантика (сетка от перефразировок)

Диапазонного skip мало: `/learn` мог зафиксировать находку из раннего куска, а observer наткнётся на ту же мысль в позднем. Поэтому **перед записью каждого кандидата**:
1. Нормализовать (`title`+`insight`, lower, collapse spaces) → **content-hash**. Сверить с: (a) `ledger.content_hashes`, (b) реестром `~/brain/dreams/.insight-hashes.jsonl`, (c) хэшами существующих source-of-truth узлов. Хит → **skip** (или bump `hits`/`confidence`, как `dream-validator`).
2. Опционально (сильнее точного хэша): `mcp__brain__brain_semantic_search` по `insight`; если косинус ≥ `DEDUP_SIM_THRESHOLD` (default 0.88) к существующему узлу — skip/merge, а не новый узел.

Итог: уровень 1 экономит LLM на уже разобранных диапазонах; уровень 2 ловит смысловые дубли независимо от того, где они всплыли.

## 6. Дистилляция

- Критерии «что считать находкой» — **те же, что в `/learn`** (surprises / workarounds / non-obvious commands / traps / decisions / связи). Вынести в общий rubric `rubrics/session-finding-v1.yaml`, чтобы `/learn` и observer судили одинаково.
- Модель: Gemini (как основной дешёвый проход brain-dream) под существующими cost-guard'ами; Claude/Sonnet — только для синтеза/критика на промоушене, не на каждый кусок.
- Выход дистилляции — массив кандидатов в формате узла Brain.

## 7. Формат кандидата

```json
{"type":"lesson|decision|procedure|note","title":"...","body":"...",
 "tags":[...],"confidence":0.3-1.0,
 "provenance":{"session_id":"<uuid>","msg_range":[a,b],"observed_at":"<ISO>",
   "model":"...","agent":"session-observer","rubric":"session-finding-v1"}}
```

## 8. Куда пишет + промоушен-гейт

- **Кандидаты → `dreams/` (staging)**, НЕ в source-of-truth. Инвариант Safety-Layer-1 brain-dream цел.
- Промоушен в source-of-truth (`decision/lesson/procedure` в каноническом домене) — отдельный контролируемый путь:
  - авто: `confidence ≥ 0.85 & hits ≥ 2` (как `dream-promoter`), **или**
  - ручной: TG ✅/❌/💡 через существующий `tg-feedback-collector` (одно сообщение со списком кандидатов за прогон).
- При промоушене — линковка к смежным узлам (`brain_link`), как требует правило write-back.

## 9. Guard'ы / безопасность

- `lib/guards.sh` (AND-chain): rate-limit, cost-circuit-breaker, depth-counter, kill-switch (`~/.brain-dream/session-observer-disabled`).
- `lib/scrub.sh` на write-path — секреты не попадают в узлы (только указатель «где лежит», без значения).
- Git-only writeback → любой прогон revertable.
- Idempotent: повторный прогон на тех же данных (тот же курсор) ничего не добавляет.

## 10. Изменение в `/learn` (зависимость)

`/learn` ДОЛЖЕН при записи дописывать строку в `.learn-ledger.jsonl` (см. §5.1): `session_id`, `processed_through_msg`, `node_ids`, `content_hashes`. Без этого уровень-1 дедупа не работает. → правка `~/.claude/skills/learn/SKILL.md` (шаг «после записи в Brain — обновить learn-ledger»).

## 11. Файлы стейта (итог)

| Файл | Назначение |
|---|---|
| `~/brain/dreams/.session-observer-cursor.jsonl` | прогресс по сессиям |
| `~/brain/dreams/.learn-ledger.jsonl` | что зафиксировал `/learn` (для дедупа) |
| `~/brain/dreams/.insight-hashes.jsonl` | общий реестр content-hash (уже есть) |
| `rubrics/session-finding-v1.yaml` | общие критерии находки (learn + observer) |
| `~/.brain-dream/session-observer-disabled` | kill-switch |

## 12. Открытые решения (нужен выбор перед сборкой)

1. **Курсор по индексу сообщения или по байтам?** Индекс надёжнее при дозаписи; байты дешевле. → предлагаю индекс сообщения.
2. **Промоушен по умолчанию — авто (confidence) или ручной (TG ✅/❌)?** → предлагаю старт с **ручного TG-гейта** (доверие сначала), авто-промоушен включить позже по KPI.
3. **Семантический дедуп (§5.2.2) в MVP или фазой 2?** → предлагаю в MVP только content-hash, semantic — фаза 2 (нужен доступ к `brain_semantic_search` из агента).
4. **Cron-хост** — vps (там сессии и так лежат, по host-routing). Подтвердить.
