# Seed: edge-proposer для свежих source-нод

**Дата:** 2026-05-30
**Источник:** human (Claude Code session в `~/Projects/blizko/`)
**Тип:** идея для introspector — рассмотреть на следующем проходе
**НЕ** auto-generated dream output. Это запрос на расширение, не патч.

---

## Контекст возникновения

В сессии создавали индекс-ноду `personal/projects/blizko.md` (источник —
`~/Projects/blizko/.planning/PROJECT.md`). Нота получилась самодостаточной по
контенту, но **изолированной** в графе: ноль входящих/исходящих edges. То же
самое произошло бы с любой новой project/decision/person нодой, которую
создаёт человек руками через `brain_add` — typed edges никто не строит.

Если такие осиротевшие ноды накапливаются, `brain_trace` теряет ценность —
семантический поиск работает, но граф деградирует в плоский набор documents.

## Что хочется

Агент или lens, который для свежей source-ноды:
1. Через LLM (Gemini, дешёвый) делает NER на body — извлекает упомянутые
   персоны, места, проекты, решения
2. Сверяет с уже существующими нодами через `brain_search` / прямой grep
   по `nodes/*/`
3. Сверяет предлагаемый `rel` с dictionary (используемые сейчас:
   `owned-by`, `uses`, `relates-to`, `justified-by`, `serves`, `located-in`,
   `continues-in` — посмотреть `brain_validate` для полного списка)
4. Выдаёт **предложения** edges, не применяя их

## Hard constraints (которые ломать нельзя)

- **Read-only source domains** — `personal/`, `travelmart/`, `marquiz/` и
  прочие не мутируются. Это базовый safety-инвариант brain-dream.
- **Git-tracked writeback** — edge proposals идут commit'ом, не silent insert
- **Human-in-the-loop** — proposals применяются руками через `brain_link`,
  не auto

## Три варианта реализации (для рассмотрения)

### A. Новый агент `dream-edge-proposer`

- Plugin contract как у других агентов (stdin JSON / stdout JSON)
- Cron weekly, после `dream-introspector`
- Записывает proposals в `dreams/edge-proposals/<date>.md` (внутри dreams
  домена — не нарушает read-only source)
- Cost cap: $0.05/неделю (NER через Haiku или Gemini Flash)
- KPI: % предложенных edges, которые human принял

### B. Новая lens в существующий orchestrator

- Добавить к 8 существующим (problem/gap/contradiction/...) лензу
  `missing-edge`
- В каждом NREM/REM проходе выдавать инсайты вида «нота X упоминает Y,
  но edge отсутствует»
- Минимальная диффа, использует существующий cost/dedup/confidence pipeline
- Минус: edge proposals смешиваются с обычными insights, теряется
  типизация

### C. CLI tool `tools/propose-edges <node-id>`

- Не sleep, а on-demand для свежей ноды
- Вызывается человеком сразу после `brain_add`
- Минимальный risk, нулевой recurring cost
- Минус: не покрывает уже-созданные осиротевшие ноты ретроспективно

## Конкретный пример (для калибровки)

Для `project:blizko` создан 2026-05-30, ожидаемые edges:

- `serves` → `person:mom-balachkova` (главный пользователь, из body)
- `serves` → `person:son-balachkov` (supporter, из body)
- `located-in` → `place:strelectsky-orel` (где мама)
- `located-in` → `place:astana` (где сын)
- `justified-by` → `decision:2026-05-16-v1-mvp-pivot`
- `justified-by` → `decision:2026-05-16-claude-vps-deploy`
- `relates-to` → `project:control-panel` (соседний инфра-проект на claude-vps)

Большинство этих target-нод **ещё не существуют** в графе. Это вторая
проблема: NER находит сущности, для которых нет нод. Нужна политика:
(а) тихо игнорировать, (б) предложить создать stub, (в) пометить в
proposal как «target missing — нужно создать сначала».

## Open questions для introspector

1. Куда логичнее — A, B, C или гибрид (например, lens в orchestrator +
   CLI tool для immediate flush)?
2. Что делать с missing targets — stub-ноды или just-flag?
3. Конфликт с существующим Jaccard ≥ 0.3 dream-edges (внутри dreams
   домена) — это про разное (insight-to-insight vs entity-to-entity),
   но naming может путать
4. Threshold для auto-acceptance: имеет ли смысл низкорисковые edges
   (типа `located-in` к существующей place ноде с confidence ≥ 0.95)
   применять auto, или строго human-in-the-loop?

## Не блокирующее

Если introspector посчитает идею преждевременной (мало source-нод,
непонятен KPI, риск шума) — закрыть seed комментарием в его weekly
proposal. Не делать просто чтобы делать.
