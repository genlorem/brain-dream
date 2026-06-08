# 30 сценариев эволюции brain-dream → отбор топ-10

**Дата:** 2026-05-30
**Назначение:** автономный отбор приоритетов перед реализацией.
**Входные данные:** roadmap `brain-dream-from-fabric.md` (8 уже зафиксированных фаз), запрос пользователя (агенты на проекты? самосовершенствование, эксперименты, git-обратимость), биология сна, паттерны Fabric autoDream.
**Принцип отбора:** топ-10 — это **дополнительно** к 8 фазам из brain-dream-from-fabric (они уже подтверждены). Здесь — над-roadmap слой (агенты, инфраструктура, эксперименты).

---

## Все сценарии (32 шт. по 7 категориям)

### A. Архитектура агентов
1. **Functional agents** — 1 агент на функцию (extractor, validator, promoter, edge-builder, pruner, introspector, observer). Контракт стандартный.
2. **Per-project agents** — 1 агент на проект (vipzal-agent, marquiz-agent, life-agent, persona-agent), знает свой контекст.
3. **Per-domain agents** — 1 агент на домен мозга (travelmart-agent, personal-agent, marquiz-agent, …).
4. **Single orchestrator + skill plugins** — единый `dream-runner`, агенты как плагины со стандартным интерфейсом `input.json → output.json`, hot-swap без перезапуска.
5. **Pub/sub event bus** между агентами (NATS-style, как в Fabric).
6. **A2A через agent-mailbox** — использовать существующую `agent-mailbox` инфру пользователя (NATS-based) для координации агентов.
7. **MCP-агенты** — каждый агент = MCP-сервер; любой LLM (Claude/Gemini/…) может его дёргать через MCP-протокол.

### B. Continuous learning / observer
8. **Daytime notes observer** — fswatch `~/life/notes` → Gemini flash-lite → observations (Fabric MEM-04).
9. **Slack-observer** — мониторит mentions в Slack (Marquiz/Persona/Travelmart workspaces) → observations.
10. **Yandex.Tracker observer** — изменения тикетов VIP-XXXX → observations.
11. **Notion observer** — изменения страниц в Marquiz/personal/skvo воркспейсах → observations.
12. **Gmail observer** — важные письма (Marquiz domain, banking, etc.) → observations.
13. **Browser-history observer** — что я недавно смотрел/гуглил (только опт-ин, приватность).

### C. Защита и безопасность
14. **5-layer guards** для observer/auto-patcher (Fabric MEM-05) — source/rate/cost/depth/kill.
15. **Multi-secret-scrub** на ВСЕХ write-путях (Fabric MEM-07) — расширенные паттерны, Shannon entropy detection.
16. **Git-only writeback** — каждое write-действие любого агента = commit в репо; rollback одной командой; никаких side-effect файлов.
17. **TG approve-gate** для destructive-действий — агент предлагает изменения, пользователь одобряет через TG-кнопки, тогда применяет.
18. **Secret-detection audit в `~/brain/`** — еженедельный проход, гарантирует, что в граф не попали ключи (мог бы поймать regress нашего redact_secrets).

### D. Качество инсайтов
19. **NREM/REM фазы** — узкая консолидация + широкий креатив (roadmap фаза 3, уже зафиксирована).
20. **Santa-pattern облегчённый** — еженедельно Sonnet валидирует топ-10 (roadmap фаза 7, уже зафиксирована).
21. **Cross-model jury** — Gemini + Sonnet + Opus голосуют по каждому инсайту; majority выигрывает.
22. **Bayesian confidence** — confidence обновляется по правилу Байеса при ✅/❌ от пользователя.
23. **Embeddings-based dedup** — cosine ≥ 0.92 на эмбеддингах (вместо content-hash exact match).

### E. KPI и обратная связь
24. **TG inline-кнопки** (✅/❌/💡) под топ-10 → KPI агрегатор (roadmap фаза 5).
25. **Daily morning brief integration** — focus-agent утром подмешивает свежий dream + вчерашний KPI.
26. **Weekly reflection report** — что сработало, что нет, выводы по линзам/доменам/моделям; в TG воскресным утром.
27. **Self-A/B testing** — сон рандомизирует параметры (recency-веса 60% vs 80%, NREM:REM 30:70 vs 50:50), через 2 недели сравнивает `useful_rate`.

### F. Самосовершенствование
28. **Agent-introspector** — еженедельно анализирует свои dreams + код brain-dream, предлагает 1-3 улучшения системы.
29. **Auto-patcher с PR** — introspector не просто предлагает текстом, а пишет patch и открывает PR в репо; пользователь ревьюлит/мёржит.
30. **Self-replicating ARCHITECTURE.md** — раз в месяц сон смотрит `dreams/permanent/`, генерирует новую версию `ARCHITECTURE.md` как PR.

### G. Per-project knowledge (если идём в эту сторону)
31. **vipzal-context-pack** — cross-проходы по personal-задачам подтягивают свежий контекст VIP-тикетов из Tracker (через `yandex-tracker.sh`).
32. **marquiz-financial-context** — финансовые сводки Marquiz из Finolog подгружаются как контекст для cross.

---

## Матрица оценки (32 сценария × 6 критериев, 1–5)

| # | Сценарий | Умн | Совр | Эфф | Безоп | Отд | Объём⁻ | **Σ** |
|---|---|---|---|---|---|---|---|---|
| 4 | Single orchestrator + skill plugins | 5 | 5 | 5 | 5 | 5 | 4 | **29** |
| 16 | Git-only writeback | 5 | 5 | 5 | 5 | 5 | 4 | **29** |
| 14 | 5-layer guards | 4 | 5 | 5 | 5 | 5 | 4 | **28** |
| 6 | A2A через agent-mailbox | 5 | 5 | 5 | 4 | 4 | 3 | **26** |
| 28 | Agent-introspector | 5 | 5 | 4 | 4 | 5 | 3 | **26** |
| 29 | Auto-patcher с PR | 5 | 5 | 4 | 4 | 5 | 3 | **26** |
| 7 | MCP-агенты | 5 | 5 | 4 | 4 | 4 | 3 | **25** |
| 8 | Daytime notes observer | 4 | 4 | 5 | 4 | 5 | 3 | **25** |
| 15 | Multi-secret-scrub | 3 | 4 | 4 | 5 | 4 | 5 | **25** |
| 24 | TG inline-кнопки KPI | 4 | 4 | 5 | 4 | 5 | 3 | **25** |
| 17 | TG approve-gate | 4 | 4 | 4 | 5 | 4 | 3 | 24 |
| 19 | NREM/REM фазы | 5 | 4 | 4 | 4 | 4 | 3 | 24 |
| 20 | Santa облегчённый | 4 | 4 | 4 | 4 | 4 | 4 | 24 |
| 22 | Bayesian confidence | 5 | 5 | 4 | 4 | 3 | 3 | 24 |
| 23 | Embeddings dedup | 4 | 5 | 4 | 4 | 4 | 3 | 24 |
| 26 | Weekly reflection | 4 | 4 | 4 | 5 | 4 | 3 | 24 |
| 27 | Self-A/B testing | 5 | 5 | 4 | 3 | 4 | 2 | 23 |
| 1 | Functional agents | 4 | 4 | 4 | 5 | 4 | 3 | 24 |
| 3 | Per-domain agents | 3 | 3 | 4 | 5 | 4 | 3 | 22 |
| 18 | Secret-detection audit | 3 | 3 | 4 | 5 | 3 | 4 | 22 |
| 5 | Pub/sub event bus | 4 | 5 | 4 | 4 | 3 | 2 | 22 |
| 25 | Daily morning brief integration | 3 | 3 | 4 | 4 | 4 | 4 | 22 |
| 21 | Cross-model jury | 5 | 4 | 3 | 4 | 3 | 2 | 21 |
| 30 | Self-replicating ARCHITECTURE.md | 5 | 4 | 3 | 3 | 3 | 2 | 20 |
| 11 | Notion observer | 4 | 4 | 3 | 3 | 4 | 2 | 20 |
| 9 | Slack-observer | 4 | 4 | 3 | 3 | 3 | 2 | 19 |
| 10 | Tracker observer | 4 | 4 | 3 | 3 | 3 | 2 | 19 |
| 2 | Per-project agents | 3 | 3 | 3 | 4 | 3 | 2 | 18 |
| 31 | vipzal-context-pack | 3 | 3 | 3 | 3 | 3 | 2 | 17 |
| 32 | marquiz-financial-context | 3 | 3 | 3 | 3 | 3 | 2 | 17 |
| 12 | Gmail observer | 3 | 3 | 2 | 2 | 2 | 1 | 13 |
| 13 | Browser-history observer | 3 | 3 | 2 | 1 | 2 | 2 | 13 |

---

## Топ-10 (с обоснованием)

### 1. Single orchestrator + skill plugins (29)
Единый `dream-runner` + агенты-плагины со стандартным интерфейсом. Hot-swap, тесты, замена модели без переписывания. **Это фундамент** — все остальные агенты вписываются в эту инфраструктуру. Без него получим спагетти из 10 разных скриптов.

### 2. Git-only writeback (29)
Каждое write-действие любого агента — атомарный commit в репо. Откат — `git revert`. Это **главная гарантия безопасности** при автономной работе и самосовершенствовании. Пользователь сам это сформулировал: «риски снизятся через git».

### 3. 5-layer guards (28)
Source-filter / rate-limit / cost-CB / depth-counter / kill-switch. Сразу под фундамент, до первого observer'а. Иначе любой автономный пайплайн рискует runaway-петлёй.

### 4. A2A через agent-mailbox (26)
У пользователя **уже есть** `agent-mailbox` инфра (NATS-based, упомянуто в `reference_life_mac_mailbox`). Использовать её для координации агентов вместо изобретения своего bus'а. Это и есть «современно и эффективно».

### 5. Agent-introspector (26)
Еженедельно читает свои dreams + код brain-dream → 1–3 предложения. **Минимальная безопасная форма самосовершенствования**: только текстовые предложения, applies нужно одобрять. Точка входа для авто-патчера #6.

### 6. Auto-patcher с PR (26)
Introspector эволюционирует в реальные patches → PR в репо. Я ревьюлю, мёржу. **Git делает риски обратимыми.** Это полноценный self-improvement loop.

### 7. MCP-агенты (25)
Каждый агент = MCP-сервер. Польза: **любой** LLM (не только сон) может его дёргать. Например, в обычной Claude-сессии я могу вызвать `dream_recall(topic="VIP-7437")` — агент достанет всё что сон знает о тикете. Универсальный API.

### 8. Daytime notes observer (25)
fswatch на `~/life/notes` → лёгкий Gemini → observations. **Превращает сон из «1× в сутки» в фоновый процесс.** Био-параллель: waking replay. Стоит ~$0.7/мес.

### 9. Multi-secret-scrub (25)
Расширенные паттерны на всех write-путях (Notion, AWS, GitHub, JWT, Shannon entropy ≥ 4.5). Обязательно перед observer'ами — иначе через 1 hook утечёт.

### 10. TG inline-кнопки KPI (25)
✅/❌/💡 под топ-10 в TG → агрегатор. **Замыкает feedback loop.** Без него все остальные улучшения летят вслепую — не знаем, что реально работает.

---

## Граф зависимостей (порядок реализации)

```
          ┌─────────────────────────────────────────────┐
          │  Slot 0: Создать GitHub репо + инфра git    │  ← блокер ВСЕГО
          └────────────────────┬────────────────────────┘
                               ▼
          ┌─────────────────────────────────────────────┐
          │  Slot 1: #1 Orchestrator + plugin interface │  ← фундамент для агентов
          │          #2 Git-only writeback политика     │  ← правило для всех агентов
          │          #9 Multi-secret-scrub в общей точке│  ← обязательно ДО любого observer
          └────────────────────┬────────────────────────┘
                               ▼
          ┌─────────────────────────────────────────────┐
          │  Slot 2: #3 5-layer guards (library)        │  ← перед любым автономным агентом
          └────────────────────┬────────────────────────┘
                               ▼
          ┌─────────────────────────────────────────────┐
          │  Slot 3: roadmap-from-fabric фазы 1+2       │  ← adaptive trigger,
          │  (recency-weighted + confidence + provenance)│   provenance, dedup
          └────────────────────┬────────────────────────┘
                               ▼
          ┌──────────────┬─────┴──────┬─────────────────┐
          ▼              ▼            ▼                 ▼
   ┌──────────┐   ┌──────────┐  ┌──────────┐   ┌──────────────┐
   │ #5       │   │ #10 TG   │   │ #7 MCP   │   │ roadmap      │
   │ Agent-   │   │ inline   │   │ exposure │   │ фазы 3,4,7   │
   │ intro-   │   │ KPI      │   │ агентов  │   │ (NREM/REM,   │
   │ spector  │   │          │   │          │   │  рёбра, Santa│
   └────┬─────┘   └──────────┘   └──────────┘   └──────────────┘
        ▼
   ┌──────────┐
   │ #6 Auto- │  ← после того как introspector доказал ценность
   │ patcher  │
   │ с PR     │
   └──────────┘

       параллельно (когда есть guards):
   ┌──────────────┐
   │ #8 Daytime   │
   │ notes obser- │
   │ ver (MEM-04) │
   └──────────────┘

       последним (использует mailbox+orchestrator+guards):
   ┌──────────────────┐
   │ #4 A2A через     │
   │ agent-mailbox    │  ← когда агентов станет ≥ 3, и нужна координация
   └──────────────────┘
```

**Slot 0** — мета-задача (репо).
**Slot 1** — три параллельные подготовки.
**Slot 2** — guards.
**Slot 3** — фазы 1+2 из brain-dream-from-fabric (триггер, confidence, dedup, provenance).
**Дальше** — конкурирующие пути, выбираем по отдаче. Auto-patcher (#6) — только **после** того, как introspector (#5) докажет, что выдаёт ценные предложения.

---

## Что НЕ в топ-10 и почему

- **Per-project / per-domain agents (#2, #3, #31, #32)** — преждевременно. Сначала функциональные агенты + orchestrator (#1). Per-project — только если найдётся реальная нужда (например, vipzal cross-проходы дают мало без контекста тикетов из Tracker — тогда #31). Не делать «на всякий случай».
- **Slack/Tracker/Notion/Gmail observers (#9–12)** — лучше после `notes observer (#8)` как референса. У них есть свои API/rate-limits/secrets — каждый = отдельная фаза. Не до основной инфры.
- **Cross-model jury (#21)** — концептуально красиво, но 3× проходы = 3× расход. Нужен только если #20 (Santa-pattern одиночный) даст слабый отсев.
- **Self-A/B testing (#27)** — мощный, но требует ≥ 4 недели данных KPI. Сначала #10, потом через месяц вернуться.
- **Bayesian confidence (#22)** — улучшение над линейным +0.1 в дедапе. Сначала линейное (фаза 2 из roadmap), потом Bayesian.
- **Embeddings dedup (#23)** — сильнее content-hash, но требует эмбеддинг-модель. Сначала hash (дёшево), потом эмбеддинги.
- **Gmail/Browser observers (#12, #13)** — низкая отдача / высокий риск приватности. Опт-ин, далеко.
- **Self-replicating ARCHITECTURE.md (#30)** — крутая идея, но это уже autonomic-loop без надзора. Включить только после того, как #5+#6 покажут стабильность за 2–3 месяца.

---

## Дополнительный принцип

Все фазы из `brain-dream-from-fabric.md` (1–8) остаются в плане **параллельно** этой инфраструктурной работе. Топ-10 здесь — **архитектурный над-слой**, не замена. Реальная последовательность будет переплетать оба списка.

**Следующий шаг автономной работы:** Slot 0 — создание GitHub репо `brain-dream`.
