# brain-dream evolution: что переносим из Fabric autoDream

**Дата:** 2026-05-30
**Контекст:** Концептуальное планирование эволюции `~/life/scripts/brain-dream.sh` в сторону био-аналога. Источник идей — фаза `~/Projects/fabric/.planning/phases/05-autodream-memory-v3` (SPEC + RESEARCH + PATTERNS + DISCUSSION-LOG). Выжимка fabric извлечена через gemini-2.5-flash (~$0.03), синтез — Opus.
**Статус:** Roadmap, не план реализации. Дизайн-документ перед `/gsd-discuss-phase`.

---

## TL;DR

Наш `brain-dream` — это первая итерация: read-only, один проход ночью, бинарная novelty, нет дедапа, нет KPI. Fabric `autoDream-memory-v3` — продуманный фундамент: adaptive trigger, multi-layer guards, provenance, dedup, Santa-pattern критика, KPI замыкание. Биологический сон даёт ещё одно измерение: NREM/REM фазы, active consolidation, recency-weighted replay, selective pruning.

**Перенести стоит:** adaptive trigger, provenance на инсайт-уровне, content-hash dedup, continuous confidence + threshold, 5-layer observer guards (если делаем continuous-learning), Santa-pattern облегчённый, 4-фазовая структура сна.

**Не переносить:** Santa-pattern в полную силу (двойной Sonnet каждую ночь — дорого по сессии); полную KV-инфраструктуру (у нас файлы, не NATS); MEM-06/08/09 (out of scope даже у Fabric).

**Добавить от себя (био):** recency-weighted sample, NREM/REM как два узких/широких режима, активные рёбра между dream-нодами в изолированном слое (домен `dreams`), selective decay по confidence × age.

---

## Концептуальная карта: три уровня

| Идея | Fabric autoDream | brain-dream сейчас | Биологический сон |
|---|---|---|---|
| **Триггер запуска** | Adaptive: ≥50 новых memories, не чаще 1×/ночь | Жёсткий cron 18:00 UTC | Сонливость растёт с нагрузкой |
| **Что читает** | `factory-memory-*`, `memory-topics-*` (whitelist) | Файлы `~/brain/<domain>/nodes/*.md` (whitelist через `DREAM_DOMAINS`) | Гиппокамп + кора |
| **Что пишет** | Только memory-layer (`factory-knowledge`, `memory-topics-global`); red-line #3 | Только `~/brain/dreams/nodes/dream-<date>.md` (read-only по исходным доменам) | Активно перестраивает: consolidation, pruning, replay |
| **Дедуп** | content-hash sha256 (norm) slice 16, scope+24h | Нет | Synaptic homeostasis: повтор без новизны затухает |
| **Confidence** | 0.3–1.0, default 0.7, threshold 0.5 для глобального | Бинарное `obvious/non-obvious` | Сила консолидации (continuous) |
| **Provenance** | Полная Zod-схема (model, prompt, source_ids, cluster_size) | Только на уровне всей ноды Dream | Эпизодический контекст |
| **Защита от петель** | 5 независимых guards (source/rate/cost/depth/kill) | Один: домен `dreams` не в `DREAM_DOMAINS` | Сон не питается снами |
| **Критика** | Santa-pattern: 2 независимых LLM, actionable=Y от обоих | Нет — что Gemini выдал, то и в топ-10 | Префронт. кора отбирает значимое |
| **Структура прогона** | 4 фазы: Read → Filter → Summarize → Critic | 1 однородная фаза (96 итераций одной логики) | NREM + REM циклы, ~90 мин каждый |
| **KPI замыкание** | `task_rejected rate` за 2 недели | Нет | Память закрепляется по поведенческой полезности |
| **Дневной приток** | Continuous-learning: hook → JetStream → observer 1×/час | Только ночной | Hippocampal replay в бодрствовании |
| **Бюджет** | $3/прогон autoDream, $1/день observer | $0.50 cost_limit Gemini | Не применимо |

---

## Что переносим — конкретные артефакты

### 1. Adaptive trigger

**Из Fabric:** запуск по `count(new_memories_since_last_run) ≥ N`, не чаще 1×/сутки.

**Под brain-dream:**
- «Новые memories» = новые/изменённые `.md` в `~/brain/<domain>/nodes/` за период от прошлого сна.
- Триггер: `новых_нод ≥ N` **OR** `прошло > T часов`. Дефолты: `N=20`, `T=20h`.
- Реализация: timestamp прошлого сна в `~/brain/dreams/.last-run.json`; перед стартом `find -newer` по доменам.
- Cron всё ещё каждый день в 23:00 ALMT, но первая команда — `dream-should-run.sh` → exit 0/1.

**Биологическая параллель:** сонливость пропорциональна когнитивной нагрузке за день. Мало новых нот = нет смысла спать.

### 2. Provenance на инсайт-уровне (адаптированная Zod-схема)

**Из Fabric (Zod):**
```typescript
ProvenanceInfo = {
  task_id, agent_id, agent_type, extracted_at, model, prompt_version,
  source_type: "extract_memories" | "autodream_synthesis" | "observation_pattern" | "session_note" | "manual",
  source_entry_ids: string[],
  cluster_size: number,
}
```

**Под brain-dream** — добавить в `CandidateEntry` (поля для каждого инсайта в `.candidates.jsonl`):
```jsonc
{
  "title": "...", "insight": "...", "why": "...",
  "novelty": "non-obvious",
  "confidence": 0.82,                  // НОВОЕ
  "content_hash": "a3f1...",           // НОВОЕ
  "model": "gemini-3.5-flash",
  "domain": "...", "lens": "...",
  "source_ids": [...],
  "provenance": {                      // НОВОЕ
    "dream_id": "dream:2026-05-30",
    "iteration": 42,
    "mode": "single",
    "target": "travelmart/task",
    "sample_node_ids": ["task:VIP-7437", ...],
    "prompt_version": "v1",
    "generated_at": "2026-05-30T22:14:00Z"
  }
}
```

Поля **обратно совместимы** (optional с дефолтами) — старые dream-ноды читаются как раньше.

### 3. Content-hash dedup инсайтов

**Из Fabric:** `sha256(normalize(content)).slice(0,16)`; norm = trim + lowercase + `\s+` → ` `; dedup в scope за 24h.

**Под brain-dream:**
- `content_hash = sha256_short(normalize(title + " | " + insight))`.
- Scope dedup: **между ночами** (не только внутри одной). При синтезе: если хеш уже встречался в любой dream-ноде за последние 14 дней → инкремент `confidence += 0.1` существующей записи в `dream:<old>.md`, новый кандидат в топ-10 не идёт.
- Хранилище хешей: `~/brain/dreams/.insight-hashes.jsonl` (append-only с `{hash, dream_id, first_seen, last_seen, hit_count, confidence}`).

**Биологическая параллель:** повторное прохождение усиливает связь (LTP), не плодит дубль-нейронов. Тематика, которая всплывает 3 ночи подряд — это уже **constants of attention**, в био это бы консолидировалось в кору.

### 4. Continuous confidence (0–1)

**Из Fabric:** Gemini/Haiku инструктируется выдавать `{"lesson":..., "confidence": 0.3-1.0}`; default 0.7 если не вернул; threshold 0.5 для попадания в `factory-knowledge`.

**Под brain-dream:**
- Изменить prompt каждой линзы: «к каждому инсайту добавь `"confidence": 0.3-1.0` (уверенность, что инсайт точен и применим)».
- Default 0.7. Дедуп-bump +0.1.
- Threshold для попадания в **топ-10** на синтез: `confidence ≥ 0.5`.
- Threshold для **«permanent» bucket** (продвижение в `~/brain/dreams/permanent/insight:<hash>.md` как отдельная нода): `confidence ≥ 0.85` **И** hit_count ≥ 3 (т.е. всплыл в ≥3 ночах).
- Бинарное `novelty` остаётся (категория), confidence — отдельное измерение.

**Биологическая параллель:** strength of synaptic consolidation. Слабые следы исчезают, повторяющиеся усиливаются и переходят в semantic memory.

### 5. 5-layer observer guards (если делаем continuous-learning, см. §8)

**Из Fabric:** AND-цепочка source-filter / rate-limit / cost-CB / depth-counter / kill-switch.

**Под brain-dream** (для дневного nota→observation pipeline):
| Guard | Механизм | Порог |
|---|---|---|
| **source-filter** | observation с `agent_type=brain-dream` или из домена `dreams` игнорируется на входе | логический |
| **rate-limit** | sliding window 60 мин в файле `.observer-rate.jsonl` | ≤ 3 вызовов / час |
| **cost-circuit-breaker** | суммарный расход observer-Gemini за UTC-сутки в `.observer-budget.jsonl` | ≤ $0.10/день, сброс 00:00 UTC |
| **depth-counter** | поле `depth` в ObservationEntry; observer-сгенерированные `depth=1`, observation от ноды `depth=0` | depth ≥ 2 → drop |
| **kill-switch** | проверка `~/.brain-dream/observer-disabled` каждый tick | файл есть → exit 0 |

**Биологическая параллель:** мозг тоже многослойно защищён от runaway replay (тормозящие интернейроны, GABAergic suppression).

### 6. Santa-pattern (облегчённый)

**Из Fabric:** два независимых LLM-вызова валидируют каждый урок до записи в `factory-knowledge`; нужны `confidence ≥ 0.5` И `actionable=Y` от обоих критиков.

**Под brain-dream** — облегчённая версия (полный двойной Sonnet каждую ночь = 10–30% сессии Max 5x, дорого):
- Критика **не каждую ночь**, а раз в 7 дней или при ручной команде `dream-promote-week`.
- Один проход Sonnet (не два) — проверяет топ-10 инсайтов за неделю на `actionable=Y/N` и `still_relevant=Y/N`.
- Прошедшие критику → промоушн в `~/brain/dreams/permanent/` (как pruned + confirmed `factory-knowledge`).
- Не прошедшие — остаются в недельных dream-нодах как «historical».

**Биологическая параллель:** недельная консолидация — переход episodic → semantic memory (cortex), который происходит на масштабе дней-недель, не одной ночи.

### 7. 4-фазовая структура сна (~ NREM/REM)

**Из Fabric:** autoDream проходит Read → Filter → Summarize → Critic.

**Под brain-dream + био-аналог:**
1. **Collect** (как сейчас): сборка всех нод выбранных доменов.
2. **NREM-фаза «Consolidate»** (~20 узких проходов):
   - Recency-weighted sample: 70% веса нодам моложе 7 дней.
   - Lens: только `problem`, `gap`, `stalled` (узкая интроспекция).
   - Малые сэмплы (3–5 нод/проход).
   - Цель: найти повторы, инкрементить confidence существующих хешей. **Новых инсайтов не плодить, если хеш совпадает.**
3. **REM-фаза «Creative»** (~30 широких проходов):
   - Uniform sample, cross-domain (каждый 2-й проход = cross).
   - Lens: `cross-analogy`, `wow`, `opportunity`, `risk`.
   - Большие сэмплы (6–9 нод).
   - Новые инсайты с высоким приоритетом novelty=non-obvious.
4. **Synthesis** (Claude Opus как сейчас) → топ-10 из обеих фаз с балансом NREM-consolidated и REM-novel.
5. **Critic** (Sonnet, опц., раз в неделю) — см. §6.

**Биологическая параллель:** прямая. NREM = slow-wave consolidation, REM = creative association.

### 8. Continuous-learning daytime pipeline (опц., высокая ценность)

**Из Fabric:** hook → NATS JetStream `fabric-observations` (TTL 7d) → Haiku observer 1×/час → паттерны в `factory-knowledge`.

**Под brain-dream:**
- **Hook**: `fswatch` или systemd-path-unit на `~/life/notes/**` → новая/изменённая нота → запись `ObservationEntry` в `~/brain/dreams/.observations.jsonl` (TTL = 7d через nightly rotate).
- **Observer**: VPS cron каждые 60 минут → читает последние 100 строк observations, делает 1 лёгкий вызов Gemini flash-lite («есть ли тут эмерджентный паттерн?») → если да, пишет в `~/brain/dreams/observations/obs:<date-hour>.md` как нода `type:observation`.
- Ночной сон **читает** observations как один из доменов («что было замечено за день»).
- Все 5 guards активны.

**Биологическая параллель:** waking hippocampal replay. Память не консолидируется только во сне — есть micro-replay даже в покое во время бодрствования.

**Цена:** Gemini flash-lite ~$0.001/вызов × 24/день × 30 дней = ~$0.7/мес. Терпимо.

### 9. Active consolidation в изолированном слое (рёбра)

**Из Fabric red-line #3:** autoDream пишет в memory-layer, не трогает operational.

**Под brain-dream** — снимает наш слишком строгий read-only без риска для SoT:
- Сон создаёт **рёбра** в домене `dreams` (нашем write-слое):
  - `dream:<N> → relates-to → <source-node-id>` для каждого ID в `source_ids` топ-10 (видно «какая нода сколько раз всплывала во снах за месяц»).
  - `dream:<N> → continues-in → dream:<N-1>` если тематика близка (cosine ≥ 0.7 по эмбеддингам топ-3 инсайтов).
  - `insight:<hash> → recurring-in → [dream:N, dream:N-1, ...]` для повторяющихся.
- **Не трогать исходные ноды** в travelmart/personal/marquiz/... — они остаются read-only для сна.
- Рёбра в frontmatter dream-ноды: `links: {relates-to: [...], continues-in: [...]}`.

**Биологическая параллель:** consolidation создаёт **новые связи** между концептами, но не переписывает оригинальные эпизоды. Гиппокамп индексирует, кора накапливает связи. Наш слой `dreams` — это «кора» поверх «гиппокампа» исходных доменов.

### 10. KPI замыкание

**Из Fabric:** `task_rejected rate` падает за 2 недели.

**Под brain-dream:**
- **Telegram-кнопки под топ-10** в single-TG сообщении: ✅ полезно / ❌ мимо / 💡 уже знал. Бот пишет в `~/brain/dreams/.feedback.jsonl`.
- **CLI `dream-confirm <insight-hash>`** для пометки «я что-то сделал по этому инсайту» (например, открыл Notion-задачу).
- **Метрика недели**: `useful_rate = (✅ + 💡) / total_top10` по lens и domain_pair.
- Через 2–3 недели — отчёт «самые полезные линзы / самые полезные домены». Подстройка sample-weights под результат.

**Биологическая параллель:** Hebbian learning — связи, ведущие к полезному поведению, усиливаются.

---

## Roadmap-фазы (приоритет / риск / отдача)

| # | Фаза | Объём | Риск | Отдача | Зависимости |
|---|---|---|---|---|---|
| **1** | Adaptive trigger + recency-weighted sample | ~50 строк bash | Низкий | Высокая (биологичнее, экономит Gemini в «тихие» дни) | — |
| **2** | Continuous confidence + content-hash dedup + provenance на инсайт-уровне | ~80 строк bash (модификация prompt + норм/хеш + jq-схема CandidateEntry) | Низкий-средний (новые поля optional) | Очень высокая (фундамент для всего остального) | — |
| **3** | NREM/REM фазы (consolidate + creative режимы) | ~60 строк (параметризация lens-выбора + sample-стратегии по фазе) | Средний (меняет распределение sample) | Средняя-высокая, качественно лучше топ-10 | 2 |
| **4** | Active consolidation: рёбра в домене dreams | ~70 строк + правка write_dream_node + jq | Средний (новые рёбра в frontmatter) | Высокая (граф становится связным, brain_search покажет связи снов) | 2, **MCP-регистрация домена dreams** (отложено с прошлой ночи) |
| **5** | Telegram-feedback кнопки + KPI агрегация | ~150 строк (TG inline keyboard + callback handler в digest-bot + weekly report) | Средний (новый TG-flow) | Высокая долгосрочно — единственный сигнал «что реально работает» | 2 |
| **6** | Continuous-learning daytime pipeline (hook + observer + 5 guards) | ~200 строк (fswatch unit + observer-bash + 5 guards-функции) | Высокий (новая инфра, потенциальный loop без guards) | Очень высокая (превращает сон из «1× в сутки» в постоянный фон) | 2, 4 |
| **7** | Santa-pattern еженедельно: Sonnet валидация → permanent bucket | ~80 строк bash + новый cron | Низкий (раз в неделю, Sonnet ≤ 10% сессии за прогон) | Средняя (отсев шума) | 2 |
| **8** | Selective pruning: decay confidence по возрасту, архив | ~40 строк (раз в месяц проход по `.insight-hashes.jsonl`) | Низкий | Низкая-средняя | 2, 5 |

**Естественный порядок реализации:** 1 → 2 → 3 → 4 → 5 → 7 → 6 → 8. Фазы 1–3 безопасно делать аддитивно (плановый cron не ломается). Фаза 4 требует одного предварительного шага — регистрации домена `dreams` в MCP brain (отложено с 2026-05-29, см. `project_gemini_brain_dreams.md`).

---

## Что НЕ переносим (и почему)

| Идея Fabric | Почему не переносим |
|---|---|
| Полная NATS KV инфраструктура (sessions/skill_runs/template_versions/install_state/governance) | У нас файлы/git, не KV-multiagent. Для одиночного пользователя избыточно. |
| MEM-01 Session Memory (TTL 24h per task) | У нас нет concept «task» как у агентов. Эквивалент — сессии Claude Code, они и так имеют свой контекст. |
| MEM-03 fire-and-forget Haiku после каждого task_result | У нас нет тасков. Эквивалент — observer (§8), но он в фазе 6, не сразу. |
| Santa-pattern с двумя ПОЛНЫМИ независимыми LLM-вызовами каждую ночь | Дорого по сессии Max 5x: 2× Sonnet × 10 инсайтов = ~20 вызовов = 10% сессии каждую ночь. Облегчённая еженедельная версия — фаза 7. |
| `template_versions` контракт с promotion/rollback | У нас нет шаблонов агентов. Не применимо. |
| `factory-knowledge` как глобальная KV-таблица | У нас граф `~/brain/`, не KV. Эквивалент — домен `dreams/permanent/`. |
| MEM-06 Instinct schema | Сами авторы отложили: нужны ≥2 проекта. Преждевременно везде. |
| MEM-09 Formal Provenance на всём импортированном | Слишком формально для нашего пайплайна. Provenance на learned-пути (фаза 2) достаточно. |

---

## Open questions для discuss-phase

1. **Регистрация домена `dreams` в MCP brain** (`TM_BRAIN_ROOTS` в `~/.claude.json` мак + VPS, reindex). Это блокер для фазы 4. Сделать ручным шагом под надзором — или автоматизировать с jq-валидацией бэкапа?
2. **Хранение `.insight-hashes.jsonl` и `.observations.jsonl`** — в `~/brain/dreams/` (не трекается git домена, .gitignore нашего изолированного слоя) или в `~/life/state/` (трекается life)? Первое чище, второе видно в git.
3. **Recency-window и сила веса**: 70% веса для нод моложе 7 дней — стартовое предположение. Тонкая настройка после первых 2 недель данных.
4. **Сложение confidence при дедапе**: `+0.1` за повтор — линейно или насыщающе (`1 - (1 - c) * 0.9`)? Линейно проще, насыщающе биологичнее.
5. **`dream:<N> continues-in dream:<N-1>` метрика близости**: cosine эмбеддингов топ-3 инсайтов через какую модель? Gemini text-embedding или локальный sentence-transformers? Первое требует API-вызовов, второе — Python venv (есть на VPS уже для движка `brain/engine`).
6. **Telegram-feedback кнопки**: в edit_message или отдельным callback? И как маппить нажатие на конкретный инсайт (нужны insight-hash в callback_data ≤ 64 байт — sha-16 влезает).
7. **Continuous-learning observer rate**: 1×/час или 1× после каждой N новых observations (тот же adaptive trigger принцип)? Второе биологичнее.
8. **Eэжнедельный Santa-pattern критик** — на каком наборе: топ-10 за неделю или ВСЕ инсайты с `confidence ≥ 0.7` за неделю? Второе строже, фильтрует больше.

---

## Метаданные сборки документа

- **Источник Fabric:** `~/Projects/fabric/.planning/phases/05-autodream-memory-v3/` — SPEC.md, CONTEXT.md, RESEARCH.md, PATTERNS.md, DISCUSSION-LOG.md (всего ~250KB на VPS).
- **Выжимка автор:** gemini-2.5-flash через `~/life/scripts/gemini.sh -m flash ask`, 39 242 input + 6 859 output токенов, расход API ~$0.03 (см. `/tmp/fabric-extract.jsonl` на VPS, временный).
- **Синтез автор:** Claude Opus 4.7 в текущей сессии.
- **Связанные памяти:** `[[project_gemini_brain_dreams]]`, `[[project_brain_federation]]`, `[[reference_brain_vault_sync]]`.
- **Следующий шаг:** `/gsd-discuss-phase brain-dream-v2` или ручное обсуждение open questions выше перед фазой 1.
