#!/usr/bin/env bash
set -euo pipefail

# Каталог orchestrator-а (соседние gemini.sh и dream-images.sh ищем рядом,
# независимо от того, откуда запущен скрипт).
ORCHESTRATOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Корень репо brain-dream — для подключения общих lib (content-hash, insight-hashes).
BRAIN_DREAM_REPO="${BRAIN_DREAM_REPO:-$(cd "$ORCHESTRATOR_DIR/.." && pwd)}"
# shellcheck disable=SC1091
source "$BRAIN_DREAM_REPO/lib/content-hash.sh"
# shellcheck disable=SC1091
source "$BRAIN_DREAM_REPO/lib/insight-hashes.sh"

# brain-dream.sh
#
# Ночной "сон" над knowledge graph в ~/brain:
# - читает markdown-ноды выбранных доменов, группирует их по type или поддиректории;
# - ночью запускает ограниченное число параллельных Gemini-проходов через разные линзы;
# - собирает кандидаты-инсайты, синтезирует ТОП-10 через Claude и оставляет Markdown-результат;
# - отправляет краткое резюме в Telegram и best-effort обложку-картинку.
#
# Параметры задаются env:
#   DREAM_DOMAINS="travelmart personal"
#   DREAM_MAX_RUNS=500
#   DREAM_DEADLINE_UTC="HH:MM" или epoch-seconds
#   DREAM_OVERRUN_RUNS=25
#   DREAM_OVERRUN_MIN=20
#   DREAM_CONCURRENCY=3
#   DREAM_OUT_DIR="$HOME/brain/dreams"
#   DREAM_IMAGE_MODEL="gemini-2.5-flash-image"
#   DREAM_COST_LIMIT_USD=0.50      # денежный потолок на Gemini за ночь; 0 = выкл
#   DREAM_PRICE_IN_PER_M=1.50      # цена входных токенов за 1M
#   DREAM_PRICE_OUT_PER_M=9.00     # цена выходных токенов за 1M
#
# Важно: доменные данные строго READ-ONLY. Скрипт не делает git-операций,
# не переиндексирует и ничего не пишет в domain repos. Он только читает *.md
# из известных доменов и пишет результат/временные файлы в DREAM_OUT_DIR.
#
# Логи: ~/life/state/logs/brain-dream.log
# Выход: $DREAM_OUT_DIR/dream-<UTC-YYYY-MM-DD>.md и, best-effort, .png

usage() {
  cat <<'USAGE'
Usage:
  brain-dream.sh
  brain-dream.sh -h|--help

Runs a bounded nightly "sleep" over ~/brain knowledge graph nodes.

Examples:
  nohup env DREAM_MAX_RUNS=300 DREAM_CONCURRENCY=4 ~/life/scripts/brain-dream.sh >/dev/null 2>&1 &

  echo 'env DREAM_DEADLINE_UTC=04:30 DREAM_DOMAINS="travelmart personal" ~/life/scripts/brain-dream.sh' | at 01:00

Env params:
  DREAM_DOMAINS         default: "travelmart personal"
  DREAM_MAX_RUNS        default: 500
  DREAM_DEADLINE_UTC    default: empty; "HH:MM" today UTC or epoch seconds
  DREAM_OVERRUN_RUNS    default: 25
  DREAM_OVERRUN_MIN     default: 20
  DREAM_CONCURRENCY     default: 3
  DREAM_OUT_DIR         default: $HOME/brain/dreams
  DREAM_IMAGE_MODEL     default: gemini-2.5-flash-image
  DREAM_COST_LIMIT_USD  default: 0.50   (денежный потолок на Gemini за ночь; 0 = выкл)
  DREAM_PRICE_IN_PER_M  default: 1.50   (цена входных токенов за 1M)
  DREAM_PRICE_OUT_PER_M default: 9.00   (цена выходных токенов за 1M)
  DREAM_SATURATION_MIN_YIELD       default: 3   (early-stop: мин. прирост кандидатов за интервал; 0 = выкл)
  DREAM_SATURATION_CHECK_INTERVAL  default: 50  (проходов между проверками насыщения)

Domain paths:
  travelmart -> $HOME/brain/travelmart/nodes
  personal   -> $HOME/life/brain

The script is read-only on domain data: no git ops, no reindex, no writes there.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "${BRAIN_DREAM_FLOCKED:-}" != "1" ]]; then
  # -E 99 — отличаем «lock уже занят» от нормального exit, чтобы залогировать
  # и не дать cron-job завершиться silently (раньше -E 0 маскировал ситуацию).
  env BRAIN_DREAM_FLOCKED=1 flock -n -E 99 /tmp/brain-dream.lock "$0" "$@"
  rc=$?
  if (( rc == 99 )); then
    log_file="${BRAIN_DREAM_LOG:-$HOME/life/state/logs/brain-dream.log}"
    mkdir -p "$(dirname "$log_file")"
    printf '%s stage=start event=skip reason=lock_held lock=/tmp/brain-dream.lock\n' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$log_file"
    exit 0
  fi
  exit "$rc"
fi

DREAM_DOMAINS="${DREAM_DOMAINS:-travelmart personal}"
DREAM_MAX_RUNS="${DREAM_MAX_RUNS:-500}"
DREAM_DEADLINE_UTC="${DREAM_DEADLINE_UTC:-}"
DREAM_OVERRUN_RUNS="${DREAM_OVERRUN_RUNS:-25}"
DREAM_OVERRUN_MIN="${DREAM_OVERRUN_MIN:-20}"
DREAM_CONCURRENCY="${DREAM_CONCURRENCY:-3}"
DREAM_OUT_DIR="${DREAM_OUT_DIR:-$HOME/brain/dreams}"
DREAM_IMAGE_MODEL="${DREAM_IMAGE_MODEL:-gemini-2.5-flash-image}"

# Early-stop по насыщению кандидатов. Уникальный сигнал исчерпывается в первых
# ~100 проходах; дальше dedup (content_hash_insight) поглощает повторы и проходы
# жгут бюджет почти без выхлопа. Каждые DREAM_SATURATION_CHECK_INTERVAL проходов
# сравниваем прирост строк в CANDIDATES_FILE: если он < DREAM_SATURATION_MIN_YIELD
# — обрываем генерацию. Работает и в Gemini-, и в Sonnet-фазе.
# DREAM_SATURATION_MIN_YIELD=0 полностью отключает проверку.
DREAM_SATURATION_MIN_YIELD="${DREAM_SATURATION_MIN_YIELD:-3}"
DREAM_SATURATION_CHECK_INTERVAL="${DREAM_SATURATION_CHECK_INTERVAL:-50}"

# Денежный потолок на Gemini-генерацию за ночь (в долларах). Считаем фактический
# расход по токенам из ответов API и останавливаем генерацию при достижении
# лимита. 0 = без лимита (старое поведение, только max_runs). Цены — за 1M
# токенов; дефолты под gemini-3.5-flash (вход $1.50 / выход $9.00 на 05.2026).
# Синтез Claude и картинки Higgsfield идут с других балансов — в лимит не входят.
DREAM_COST_LIMIT_USD="${DREAM_COST_LIMIT_USD:-0.50}"
DREAM_PRICE_IN_PER_M="${DREAM_PRICE_IN_PER_M:-1.50}"
DREAM_PRICE_OUT_PER_M="${DREAM_PRICE_OUT_PER_M:-9.00}"

# Бэкенд Gemini-генерации:
#   api (по умолчанию) — REST generativelanguage + API-ключ AIza… из
#     ~/.config/gemini/config.env (биллинг на GCP-проект ключа, monthly spend cap).
#   cli — локальный gemini CLI на OAuth-аккаунте (отдельная free-квота Code
#     Assist, не доллары). Минусы: ~3-6с старта node на вызов и RPM-лимиты
#     OAuth, поэтому держи DREAM_CONCURRENCY/DREAM_MAX_RUNS скромными и модель из
#     поддерживаемых OAuth (gemini-2.5-flash; 3.5 через OAuth недоступна).
# Пробрасывается в gemini.sh как GEMINI_BACKEND. На cli денежный потолок теряет
# смысл (нет $-биллинга), а раздутые входные токены CLI ложно тригерят cap —
# поэтому ниже обнуляем cost-cap и цены (отчёт показывает $0.00, что и есть факт).
DREAM_GEMINI_BACKEND="${DREAM_GEMINI_BACKEND:-api}"
if [[ "$DREAM_GEMINI_BACKEND" == "cli" ]]; then
  export GEMINI_BACKEND="cli"
  DREAM_COST_LIMIT_USD=0
  DREAM_PRICE_IN_PER_M=0
  DREAM_PRICE_OUT_PER_M=0
fi

# Вторая фаза генерации на Claude Sonnet (для сравнения с Gemini и как
# fallback-продолжение, если Gemini рано упёрся в денежный лимит). Включается
# DREAM_SONNET_COMPARE=1. По умолчанию ВЫКЛ — плановый cron работает как раньше.
#
# Sonnet идёт через claude CLI (подписка Claude Code, НЕ API-кошелёк), поэтому
# реальный «расход» — не доллары, а доля от сессионного лимита подписки
# (5-часовое окно). Поле total_cost_usd, которое отдаёт claude --output-format
# json, — расчётная API-цена «сколько бы стоило по прайсу», справочно; в
# биллинге не списывается. Предохранитель — % сессии, не доллары.
DREAM_SONNET_COMPARE="${DREAM_SONNET_COMPARE:-0}"
DREAM_SONNET_MODEL="${DREAM_SONNET_MODEL:-sonnet}"
DREAM_SONNET_CONCURRENCY="${DREAM_SONNET_CONCURRENCY:-2}"
# Потолок проходов Sonnet: пусто = столько же, сколько успел Gemini. Число =
# жёсткий абсолютный потолок (страховка сверху).
DREAM_SONNET_MAX_RUNS="${DREAM_SONNET_MAX_RUNS:-}"
# Сессионный лимит твоего плана Claude Code (вызовов / 5 часов). Max 5x ≈ 200.
DREAM_SONNET_SESSION_LIMIT_CALLS="${DREAM_SONNET_SESSION_LIMIT_CALLS:-200}"
# Предохранитель: остановить Sonnet-фазу, когда она съест эту долю сессии (%).
# 30% при лимите 200 = 60 вызовов за ночь, дневной остаток подписки сохранён.
DREAM_SONNET_SESSION_CAP_PCT="${DREAM_SONNET_SESSION_CAP_PCT:-30}"

# Фолбэк на Sonnet, если Gemini недоступен (упёрся в monthly spend cap, протух
# ключ и т.п.). 1 = пре-флайт проба в начале прогона; при провале праймари-фаза
# Gemini пропускается и весь синтез идёт на Sonnet через подписку Claude Code.
# Реальный потолок проходов всё равно режется DREAM_SONNET_SESSION_CAP_PCT.
DREAM_SONNET_FALLBACK="${DREAM_SONNET_FALLBACK:-1}"
# Сколько проходов делает Sonnet в режиме фолбэка (когда Gemini дал 0 проходов и
# DREAM_SONNET_MAX_RUNS не задан). Сессионный cap-pct всё равно может оборвать раньше.
DREAM_SONNET_FALLBACK_RUNS="${DREAM_SONNET_FALLBACK_RUNS:-60}"

# Запись результата сна нодой в домен dreams (~/brain/dreams/nodes). 1 = писать.
# Домен dreams изолирован: сон его не читает (см. domain_root).
DREAM_WRITE_NODE="${DREAM_WRITE_NODE:-0}"
DREAM_NODE_ROOT="${DREAM_NODE_ROOT:-$HOME/brain/dreams}"

# Режим Telegram-вывода: single = одно фото-сообщение (обложка + топ-10 в
# подписи), без картинок по инсайтам; legacy = старое поведение (текст +
# обложка + media-group инсайтов).
DREAM_TG_MODE="${DREAM_TG_MODE:-legacy}"

# Интерактивная оценка инсайтов кнопками в Telegram. >0 = после дайджеста (режим
# single) шлём отдельное сообщение с топ-N кандидатов и сеткой кнопок 👍/➕/👎.
# Нажатие обрабатывает digest-bot (handlers/dream.py) → dream-feedback.sh.
# 0 = выключить кнопки.
DREAM_FEEDBACK_BUTTONS="${DREAM_FEEDBACK_BUTTONS:-10}"

# Петля фидбэка: взвешивать линзы/домены по оценкам из .feedback.jsonl.
# 1 = генерация чаще берёт линзы/домены с высоким useful_rate и реже — с высоким
# noise_rate (через GCD-нормализованную взвешенную ротацию: без оценок все веса
# равны → схлопывается в исходный round-robin, нулевое изменение поведения).
# 0 = выкл (чистый round-robin). Critic читает оценки независимо от этого флага.
DREAM_FEEDBACK_BIAS="${DREAM_FEEDBACK_BIAS:-1}"
DREAM_FEEDBACK_FILE="${DREAM_FEEDBACK:-$HOME/brain/dreams/.feedback.jsonl}"

# Recency-bias при сэмплинге нод в каждом проходе: % выборки из «свежей»
# половины (по mtime). 70% = свежие имеют приоритет, но не монополию. 50% =
# чисто uniform. Биологический аналог — hippocampal replay свежих эпизодов.
DREAM_RECENT_WEIGHT_PCT="${DREAM_RECENT_WEIGHT_PCT:-70}"

# Top-N кандидатов по confidence, передаваемых в synthesis-prompt Claude.
# Снижает шум при больших объёмах кандидатов (per dream-introspector proposal #2).
# Дефолт 120 = ~30K токенов промпта при средней длине инсайта.
DREAM_SYNTH_TOP_N="${DREAM_SYNTH_TOP_N:-120}"

# NREM/REM-фазы сна (биологический аналог).
# DREAM_NREM_PASSES первых итераций идут в NREM-режиме: узкие consolidating
# линзы (problem/gap/stalled), малые сэмплы, агрессивный recency-bias.
# Остальные — REM: широкие creative линзы, большие сэмплы, чаще cross-проходы.
# 0 = выкл (единая фаза, как раньше).
DREAM_NREM_PASSES="${DREAM_NREM_PASSES:-20}"

# Дедуп ленты дайджеста против недавних ночей (Gemini Flash). brain-dream варит
# каждую ночь изолированно → один и тот же вывод может всплыть несколько ночей
# подряд под другой формулировкой (content-hash дедуп кандидатов это не ловит:
# он до синтеза, а Claude переформулирует). Слой поверх готового топ-10: Flash
# сверяет сегодняшние инсайты с реально показанными за последние N дней
# (.digest-published.jsonl) и гасит near-duplicate. Fail-open: при любой осечке
# (нет ключа / Gemini упал / пустой реестр) лента публикуется целиком.
# 1 = включено. Окно сравнения — DREAM_DIGEST_DEDUP_DAYS дней.
DREAM_DIGEST_DEDUP="${DREAM_DIGEST_DEDUP:-1}"
DREAM_DIGEST_DEDUP_DAYS="${DREAM_DIGEST_DEDUP_DAYS:-5}"
DREAM_DIGEST_DEDUP_MODEL="${DREAM_DIGEST_DEDUP_MODEL:-flash}"

LOG_FILE="$HOME/life/state/logs/brain-dream.log"
GEMINI_SH="$ORCHESTRATOR_DIR/gemini.sh"
UTC_DATE="$(date -u +%F)"
OUT_MD="$DREAM_OUT_DIR/dream-$UTC_DATE.md"
OUT_PNG="$DREAM_OUT_DIR/dream-$UTC_DATE.png"
CANDIDATES_FILE="$DREAM_OUT_DIR/.candidates.jsonl"
CANDIDATES_LOCK="$DREAM_OUT_DIR/.candidates.lock"
USAGE_SINK="$DREAM_OUT_DIR/.dream-usage.jsonl"
USAGE_LOCK="$USAGE_SINK.lock"
# Дочерние gemini.sh дописывают сюда фактический расход токенов.
export GEMINI_USAGE_SINK="$USAGE_SINK"
# Раздельный учёт Sonnet-фазы.
SONNET_SINK="$DREAM_OUT_DIR/.dream-usage-sonnet.jsonl"
SONNET_LOCK="$SONNET_SINK.lock"
NODES_FILE="$DREAM_OUT_DIR/.brain-dream-nodes.tsv"
CLUSTERS_FILE="$DREAM_OUT_DIR/.brain-dream-clusters.tsv"
PROMPT_FILE=""
# Реестр показанных в ленте инсайтов (для дедупа против недавних ночей) и
# готовый дедупнутый блок заголовков для подписи Telegram (заполняет
# run_digest_dedup; пусто => digest_title_block падает на extract_top_titles).
DIGEST_REGISTRY="$DREAM_OUT_DIR/.digest-published.jsonl"
DIGEST_TITLES_FILE="$DREAM_OUT_DIR/.digest-titles.txt"

TEMP_FILES=()
PIDS=()
LAUNCHED=0
RUNS=0
FAILS=0
ITERATION=0
DEADLINE_EPOCH=0
DEADLINE_CUT=0
STOP_REASON="not_started"
STAGE="start"
RUN_ENGINE="gemini"
GEMINI_UNAVAILABLE=0
GEMINI_LAUNCHED=0
GEMINI_RUNS=0
SONNET_LAUNCHED=0
STOP_REASON_SONNET="none"

# Взвешенные (по фидбэку) последовательности индексов линз/кластеров. Пусто =
# fallback на чистый round-robin (iteration % len). Заполняются в main().
WEIGHTED_NREM_IDX=()
WEIGHTED_REM_IDX=()
WEIGHTED_LENS_IDX=()
WEIGHTED_CLUSTER_IDX=()

mkdir -p "$(dirname "$LOG_FILE")" "$DREAM_OUT_DIR"

register_temp_file() {
  TEMP_FILES+=("$1")
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  if ((${#PIDS[@]} > 0)); then
    local pid
    for pid in "${PIDS[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
      fi
    done
  fi

  local running_pid
  while IFS= read -r running_pid; do
    [[ -z "$running_pid" ]] && continue
    kill "$running_pid" 2>/dev/null || true
  done < <(jobs -pr 2>/dev/null || true)

  if ((${#TEMP_FILES[@]} > 0)); then
    rm -f "${TEMP_FILES[@]}" 2>/dev/null || true
  fi

  exit "$status"
}

trap cleanup EXIT INT TERM

register_temp_file "$CANDIDATES_FILE"
register_temp_file "$CANDIDATES_LOCK"
register_temp_file "$NODES_FILE"
register_temp_file "$CLUSTERS_FILE"
register_temp_file "$USAGE_SINK"
register_temp_file "$USAGE_LOCK"
register_temp_file "$SONNET_SINK"
register_temp_file "$SONNET_LOCK"

log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG_FILE"
}

is_nonnegative_int() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

is_nonneg_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

validate_params() {
  local name value

  for name in DREAM_MAX_RUNS DREAM_OVERRUN_RUNS DREAM_OVERRUN_MIN DREAM_CONCURRENCY \
              DREAM_SATURATION_MIN_YIELD DREAM_SATURATION_CHECK_INTERVAL; do
    value="${!name}"
    if ! is_nonnegative_int "$value"; then
      log "stage=start error=invalid_integer param=$name value=$value"
      exit 1
    fi
  done

  for name in DREAM_COST_LIMIT_USD DREAM_PRICE_IN_PER_M DREAM_PRICE_OUT_PER_M DREAM_SONNET_SESSION_CAP_PCT; do
    value="${!name}"
    if ! is_nonneg_number "$value"; then
      log "stage=start error=invalid_number param=$name value=$value"
      exit 1
    fi
  done

  if ! is_nonnegative_int "$DREAM_SONNET_SESSION_LIMIT_CALLS" || ((DREAM_SONNET_SESSION_LIMIT_CALLS < 1)); then
    log "stage=start error=invalid_session_limit value=$DREAM_SONNET_SESSION_LIMIT_CALLS"
    exit 1
  fi

  if ((DREAM_CONCURRENCY < 1)); then
    log "stage=start error=invalid_concurrency value=$DREAM_CONCURRENCY"
    exit 1
  fi

  # Интервал должен быть >=1: при 0 чекпоинт срабатывал бы каждый проход и почти
  # гарантированно ронял генерацию на первом же шаге. Отключение проверки — через
  # DREAM_SATURATION_MIN_YIELD=0, а не через интервал.
  if ((DREAM_SATURATION_CHECK_INTERVAL < 1)); then
    log "stage=start error=invalid_saturation_interval value=$DREAM_SATURATION_CHECK_INTERVAL"
    exit 1
  fi
}

check_dependencies() {
  local missing=0
  local dep

  for dep in jq curl claude flock; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      log "stage=start error=missing_dependency dependency=$dep"
      missing=1
    fi
  done

  if [[ ! -x "$GEMINI_SH" ]]; then
    log "stage=start error=missing_dependency dependency=$GEMINI_SH"
    missing=1
  fi

  if ((missing != 0)); then
    exit 1
  fi
}

parse_deadline_epoch() {
  local value="$1"
  local today

  if [[ -z "$value" ]]; then
    printf '0\n'
    return 0
  fi

  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
    return 0
  fi

  if [[ "$value" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    today="$(date -u +%F)"
    date -u -d "$today $value:00 UTC" +%s
    return 0
  fi

  log "stage=start error=invalid_deadline value=$value"
  exit 1
}

now_epoch() {
  date -u +%s
}

# Фактический расход Gemini в долларах: суммируем токены из sink-файла и
# умножаем на цены за 1M. Печатаем число (доллары) с округлением до 6 знаков.
spent_usd() {
  if [[ ! -s "$USAGE_SINK" ]]; then
    printf '0\n'
    return 0
  fi

  jq -s -r \
    --argjson pin "$DREAM_PRICE_IN_PER_M" \
    --argjson pout "$DREAM_PRICE_OUT_PER_M" '
      (map(.prompt_tokens // 0) | add // 0) as $in
      | (map(.candidates_tokens // 0) | add // 0) as $out
      | (($in / 1000000 * $pin) + ($out / 1000000 * $pout))
      | (. * 1000000 | round) / 1000000
    ' "$USAGE_SINK" 2>/dev/null || printf '0\n'
}

# Число уже учтённых вызовов Gemini (строк в sink).
usage_calls() {
  if [[ -s "$USAGE_SINK" ]]; then
    wc -l < "$USAGE_SINK" | tr -d '[:space:]'
  else
    printf '0\n'
  fi
}

# Достигнут ли денежный лимит. Лимит 0 = выключен.
# Резервируем бюджет на проходы «в полёте»: их токены ещё не записаны в sink,
# но деньги потратятся. Оцениваем их по средней цене завершённых проходов и
# останавливаемся упреждающе — так фактический перебор за лимит держится в
# пределах ~одного прохода, а не concurrency проходов.
cost_limit_reached() {
  local spent calls in_flight projected
  awk "BEGIN{exit !($DREAM_COST_LIMIT_USD > 0)}" || return 1
  spent="$(spent_usd)"
  calls="$(usage_calls)"
  in_flight=${#PIDS[@]}
  if ((calls > 0 && in_flight > 0)); then
    projected="$(awk "BEGIN{printf \"%.6f\", $spent + ($spent / $calls) * $in_flight}")"
  else
    projected="$spent"
  fi
  awk "BEGIN{exit !($projected >= $DREAM_COST_LIMIT_USD)}"
}

# --- Sonnet-фаза: вторая модель (сравнение расхода + fallback-продолжение) ---

# Дописать расход Sonnet-вызова из claude-json (есть готовый total_cost_usd).
record_sonnet_usage() {
  local model="$1" resp="$2" line
  line="$(printf '%s' "$resp" | jq -c --arg model "$model" '
    {ts:(now|todate), model:$model,
     prompt_tokens:((.usage.input_tokens // 0)+(.usage.cache_creation_input_tokens // 0)+(.usage.cache_read_input_tokens // 0)),
     candidates_tokens:(.usage.output_tokens // 0),
     cost_usd:(.total_cost_usd // 0)}' 2>/dev/null)" || return 0
  [[ -z "$line" ]] && return 0
  {
    flock 9
    printf '%s\n' "$line" >> "$SONNET_SINK"
  } 9>"$SONNET_LOCK"
}

# Расход Sonnet-фазы в долларах — суммируем готовый cost_usd из каждого вызова.
spent_usd_sonnet() {
  if [[ ! -s "$SONNET_SINK" ]]; then printf '0\n'; return 0; fi
  jq -s -r '(map(.cost_usd // 0) | add // 0) | (. * 1000000 | round) / 1000000' "$SONNET_SINK" 2>/dev/null || printf '0\n'
}

token_usage_summary_sonnet() {
  if [[ ! -s "$SONNET_SINK" ]]; then printf 'calls=0 in=0 out=0\n'; return 0; fi
  jq -s -r '{calls:length, in:(map(.prompt_tokens // 0)|add//0), out:(map(.candidates_tokens // 0)|add//0)}
    | "calls=\(.calls) in=\(.in) out=\(.out)"' "$SONNET_SINK" 2>/dev/null || printf 'calls=0 in=0 out=0\n'
}

# Sonnet через подписку Claude Code — реальный «расход» это вызовы из
# сессионного окна 5ч, не доллары. spent_usd_sonnet остаётся как СПРАВОЧНАЯ
# «сколько бы стоило по API-прайсу», но не используется для предохранителя.

# Сколько вызовов Sonnet уже сделано (строк в sink).
sonnet_calls() {
  if [[ -s "$SONNET_SINK" ]]; then
    wc -l < "$SONNET_SINK" | tr -d '[:space:]'
  else
    printf '0\n'
  fi
}

# Доля сессии подписки, съеденная Sonnet-фазой (вызовы / лимит окна × 100).
sonnet_session_share_pct() {
  local calls
  calls="$(sonnet_calls)"
  awk -v c="$calls" -v l="$DREAM_SONNET_SESSION_LIMIT_CALLS" \
    'BEGIN{ if (l <= 0) { print "0"; exit } printf "%.2f", (c / l) * 100 }'
}

# Достигнут ли потолок сессии (DREAM_SONNET_SESSION_CAP_PCT). 0 = без лимита.
sonnet_quota_reached() {
  local share
  awk "BEGIN{exit !($DREAM_SONNET_SESSION_CAP_PCT > 0)}" || return 1
  share="$(sonnet_session_share_pct)"
  awk "BEGIN{exit !($share >= $DREAM_SONNET_SESSION_CAP_PCT)}"
}

# Один проход Sonnet — зеркало run_generation_iteration, но через claude CLI.
# Кандидаты идут в общий CANDIDATES_FILE (помечены model:sonnet), расход — в
# SONNET_SINK. Те же линзы/кластеры/сэмплы, что у Gemini → честное сравнение.
run_sonnet_iteration() {
  local iteration="$1" mode="$2" domain_label="$3" lens_key="$4" lens_text="$5" context="$6" allowed_ids_json="$7"
  local instruction response result line normalized valid_count=0

  instruction="$lens_text

Верни только JSONL без markdown и без пояснений вокруг.
Нужно 1-3 инсайта, каждый на отдельной строке, строго в формате:
{\"title\":\"\",\"insight\":\"\",\"why\":\"\",\"novelty\":\"obvious|non-obvious\",\"confidence\":0.7,\"source_ids\":[],\"domain\":\"\",\"lens\":\"\"}

Правила:
- опирайся только на source_ids из контекста;
- source_ids должны быть id нод, которые реально использованы;
- domain поставь \"$domain_label\" или более точный домен из контекста;
- lens поставь \"$lens_key\";
- confidence — твоя уверенность 0.3-1.0, что инсайт точен И применим на практике (а не просто факт). Дефолт 0.7. 0.3-0.5 = гипотеза, 0.6-0.8 = вероятно, 0.9-1.0 = уверен, действие напрашивается;
- insight и why пиши по-русски, конкретно и без общих советов.

КОНТЕКСТ НОД:
$context"

  if ! response="$(claude -p --model "$DREAM_SONNET_MODEL" --output-format json "$instruction" 2>/dev/null)"; then
    log "stage=sonnet event=claude_failed iteration=$iteration mode=$mode lens=$lens_key"
    return 1
  fi

  record_sonnet_usage "$DREAM_SONNET_MODEL" "$response"

  result="$(printf '%s' "$response" | jq -r '.result // empty' 2>/dev/null || true)"
  if [[ -z "$result" ]]; then
    log "stage=sonnet event=empty_result iteration=$iteration mode=$mode lens=$lens_key"
    return 0
  fi

  local objects
  objects="$(printf '%s\n' "$result" \
    | sed -E '/^[[:space:]]*```/d' \
    | jq -c -R 'fromjson? // empty | if type=="array" then .[] else . end' 2>/dev/null || true)"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if normalized="$(printf '%s\n' "$line" | jq -c -e \
      --arg domain "$domain_label" --arg lens "$lens_key" --argjson allowed "$allowed_ids_json" '
        select(type == "object")
        | .title = (.title // "") | .insight = (.insight // "") | .why = (.why // "")
        | .novelty = (if .novelty == "obvious" or .novelty == "non-obvious" then .novelty else "non-obvious" end)
        | .source_ids = (if (.source_ids|type)=="array" then [.source_ids[]|tostring|select(($allowed|index(.))!=null)] else [] end)
        | .domain = (if (.domain|type)=="string" and (.domain|length)>0 then .domain else $domain end)
        | .lens = (if (.lens|type)=="string" and (.lens|length)>0 then .lens else $lens end)
        | .confidence = (
            if (.confidence | type) == "number"
            then (if .confidence < 0.3 then 0.3
                  elif .confidence > 1.0 then 1.0
                  else .confidence end)
            else 0.7
            end
          )
        | .model = "sonnet"
        | select((.title|type)=="string" and (.title|length)>0)
        | select((.insight|type)=="string" and (.insight|length)>0)
        | select((.why|type)=="string" and (.why|length)>0)
      ' 2>/dev/null)"; then
      # Phase 2: content_hash + provenance (с model:sonnet).
      local _title _insight _hash _gen_at
      _title=$(printf '%s' "$normalized" | jq -r '.title')
      _insight=$(printf '%s' "$normalized" | jq -r '.insight')
      _hash=$(content_hash_insight "$_title" "$_insight")
      _gen_at=$(date -u +%FT%TZ)
      normalized=$(printf '%s' "$normalized" | jq -c \
        --arg h "$_hash" \
        --arg dream_id "dream:$UTC_DATE" \
        --argjson iter "$iteration" \
        --arg mode "$mode" \
        --arg target "$domain_label" \
        --arg model "$DREAM_SONNET_MODEL" \
        --argjson sample_ids "$allowed_ids_json" \
        --arg gen_at "$_gen_at" \
        '. + {content_hash: $h, provenance: {
           dream_id: $dream_id, iteration: $iter, mode: $mode, target: $target,
           sample_node_ids: $sample_ids, prompt_version: "v2",
           model: $model, generated_at: $gen_at
        }}')
      append_candidate "$normalized"
      valid_count=$((valid_count + 1))
    fi
  done <<< "$objects"

  log "stage=sonnet event=claude_ok iteration=$iteration mode=$mode lens=$lens_key candidates=$valid_count"
  return 0
}

deadline_generation_open() {
  local now

  if ((LAUNCHED >= DREAM_MAX_RUNS)); then
    STOP_REASON="max_runs"
    return 1
  fi

  if cost_limit_reached; then
    STOP_REASON="cost_limit"
    return 1
  fi

  if ((DEADLINE_EPOCH > 0)); then
    now="$(now_epoch)"
    if ((now >= DEADLINE_EPOCH - 300)); then
      DEADLINE_CUT=1
      STOP_REASON="deadline_buffer"
      return 1
    fi
  fi

  STOP_REASON="running"
  return 0
}

domain_root() {
  # Все доменные корни мозга по схеме ~/brain/<домен>/nodes. Домен dreams
  # сознательно НЕ включён: туда сон пишет свой результат, и читать собственные
  # сны как вход нельзя (иначе сон начнёт пересказывать сам себя).
  case "$1" in
    travelmart|personal|marquiz|skvo|indie|govori)
      printf '%s\n' "$HOME/brain/$1/nodes"
      ;;
    *)
      return 1
      ;;
  esac
}

clean_scalar() {
  sed \
    -e 's/^[[:space:]]*//' \
    -e 's/[[:space:]]*$//' \
    -e 's/^"//' \
    -e 's/"$//' \
    -e "s/^'//" \
    -e "s/'$//"
}

yaml_field() {
  local file="$1"
  local field="$2"

  awk -v field="$field" '
    NR == 1 && $0 ~ /^---[[:space:]]*$/ { in_fm = 1; next }
    in_fm && $0 ~ /^---[[:space:]]*$/ { exit }
    in_fm {
      pattern = "^" field ":[[:space:]]*"
      if ($0 ~ pattern) {
        sub(pattern, "")
        print
        exit
      }
    }
  ' "$file" | clean_scalar
}

yaml_links_compact() {
  local file="$1"

  awk '
    NR == 1 && $0 ~ /^---[[:space:]]*$/ { in_fm = 1; next }
    in_fm && $0 ~ /^---[[:space:]]*$/ { exit }
    in_fm {
      if ($0 ~ /^links:[[:space:]]*/) {
        in_links = 1
        print
        next
      }
      if (in_links) {
        if ($0 ~ /^[A-Za-z0-9_-]+:[[:space:]]*/ && $0 !~ /^[[:space:]-]/) {
          exit
        }
        print
      }
    }
  ' "$file" | head -n 40 | tr '\n' ' ' | sed -e 's/[[:space:]][[:space:]]*/ /g' | cut -c 1-900
}

body_slice() {
  local file="$1"

  awk '
    /^---[[:space:]]*$/ {
      sep += 1
      next
    }
    sep >= 2 { print }
  ' "$file" | tr '\n' ' ' | sed -e 's/[[:space:]][[:space:]]*/ /g' | cut -c 1-500
}

# Второй рубеж: вырезать значения токенов из текста ноды ПЕРЕД отправкой в
# Gemini (первый рубеж — guard в engine не пускает их в ноты вовсе). Паттерны
# синхронизированы с SECRET_PATTERNS в ~/brain/engine/server.py.
redact_secrets() {
  sed -E \
    -e 's/ntn_[A-Za-z0-9]{40,}/[REDACTED-notion]/g' \
    -e 's/secret_[A-Za-z0-9]{40,}/[REDACTED-notion]/g' \
    -e 's/xox[abcdprs]-[0-9A-Za-z-]{10,}/[REDACTED-slack]/g' \
    -e 's/xapp-[0-9A-Za-z-]{10,}/[REDACTED-slack]/g' \
    -e 's/sk-[A-Za-z0-9_-]{20,}/[REDACTED-key]/g' \
    -e 's/AKIA[0-9A-Z]{16}/[REDACTED-aws]/g' \
    -e 's/gh[pousr]_[A-Za-z0-9]{36,}/[REDACTED-github]/g' \
    -e 's/glpat-[A-Za-z0-9_-]{20,}/[REDACTED-gitlab]/g' \
    -e 's/AIza[0-9A-Za-z_-]{35}/[REDACTED-google]/g' \
    -e 's/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/[REDACTED-jwt]/g' \
    -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----/[REDACTED-pem]/g'
}

fallback_node_id() {
  local file="$1"
  local base
  base="$(basename "$file")"
  printf '%s\n' "${base%.md}"
}

node_id_for_path() {
  local file="$1"
  local id
  id="$(yaml_field "$file" id || true)"
  if [[ -z "$id" ]]; then
    id="$(fallback_node_id "$file")"
  fi
  printf '%s\n' "$id"
}

cluster_for_file() {
  local root="$1"
  local file="$2"
  local type rel

  type="$(yaml_field "$file" type || true)"
  if [[ -n "$type" ]]; then
    printf '%s\n' "$type"
    return 0
  fi

  rel="${file#"$root"/}"
  if [[ "$rel" == "$file" || "$rel" != */* ]]; then
    printf '_root\n'
  else
    printf '%s\n' "${rel%%/*}"
  fi
}

collect_nodes() {
  local domain root file cluster

  : > "$NODES_FILE"
  : > "$CLUSTERS_FILE"

  for domain in $DREAM_DOMAINS; do
    if ! root="$(domain_root "$domain")"; then
      log "stage=collect action=skip_unknown_domain domain=$domain"
      continue
    fi

    if [[ ! -d "$root" ]]; then
      log "stage=collect action=skip_absent_domain domain=$domain path=$root"
      continue
    fi

    while IFS= read -r -d '' file; do
      cluster="$(cluster_for_file "$root" "$file")"
      printf '%s\t%s\t%s\n' "$domain" "$cluster" "$file" >> "$NODES_FILE"
    done < <(find "$root" -type f -name '*.md' -print0)
  done

  if [[ -s "$NODES_FILE" ]]; then
    awk -F '\t' '!seen[$1 FS $2]++ { print $1 "\t" $2 }' "$NODES_FILE" > "$CLUSTERS_FILE"
  fi
}

line_count() {
  local file="$1"
  if [[ ! -s "$file" ]]; then
    printf '0\n'
  else
    wc -l < "$file" | tr -d '[:space:]'
  fi
}

cluster_line_at() {
  local index="$1"
  local line_number=$((index + 1))
  awk -v n="$line_number" 'NR == n { print; exit }' "$CLUSTERS_FILE"
}

sample_paths() {
  local domain="$1"
  local cluster="$2"
  local iteration="$3"
  local desired="$4"
  local count take i path mtime
  local -a pool extra unique sorted_with_mtime
  local -A seen
  local recent_pct recent_zone_end recent_take old_take offset_r offset_o old_size

  mapfile -t pool < <(awk -F '\t' -v d="$domain" -v c="$cluster" '$1 == d && $2 == c { print $3 }' "$NODES_FILE" | sort)

  if ((${#pool[@]} < desired)); then
    mapfile -t extra < <(awk -F '\t' -v d="$domain" '$1 == d { print $3 }' "$NODES_FILE" | sort)
    pool+=("${extra[@]}")
  fi

  if ((${#pool[@]} < desired)); then
    mapfile -t extra < <(awk -F '\t' '{ print $3 }' "$NODES_FILE" | sort)
    pool+=("${extra[@]}")
  fi

  for path in "${pool[@]}"; do
    [[ -z "$path" ]] && continue
    if [[ -n "${seen[$path]:-}" ]]; then continue; fi
    seen["$path"]=1
    unique+=("$path")
  done

  count=${#unique[@]}
  if ((count == 0)); then return 0; fi

  take="$desired"
  ((take > count)) && take="$count"

  # Recency-weighted bias: сортируем unique по mtime DESC, делим на recent-зону
  # (первая половина) и old-зону. DREAM_RECENT_WEIGHT_PCT% от take берём из
  # recent-зоны. При iteration-фиксированном offset = воспроизводимый сэмпл.
  recent_pct="${DREAM_RECENT_WEIGHT_PCT:-70}"

  for path in "${unique[@]}"; do
    mtime=$(stat -c %Y "$path" 2>/dev/null || echo 0)
    sorted_with_mtime+=("$mtime"$'\t'"$path")
  done
  mapfile -t unique < <(printf '%s\n' "${sorted_with_mtime[@]}" | sort -rn -t $'\t' -k1 | cut -f2-)

  recent_zone_end=$(( count / 2 ))
  ((recent_zone_end == 0)) && recent_zone_end=1
  recent_take=$(( take * recent_pct / 100 ))
  ((recent_take == 0)) && recent_take=1
  old_take=$(( take - recent_take ))

  offset_r=$(( (iteration * 5) % recent_zone_end ))
  for ((i = 0; i < recent_take; i += 1)); do
    printf '%s\n' "${unique[$(( (offset_r + i) % recent_zone_end ))]}"
  done

  if ((old_take > 0 && count > recent_zone_end)); then
    old_size=$(( count - recent_zone_end ))
    offset_o=$(( (iteration * 7) % old_size ))
    for ((i = 0; i < old_take; i += 1)); do
      printf '%s\n' "${unique[$(( recent_zone_end + (offset_o + i) % old_size ))]}"
    done
  fi
}

manifest_domain_for_path() {
  local path="$1"
  awk -F '\t' -v p="$path" '$3 == p { print $1; exit }' "$NODES_FILE"
}

manifest_cluster_for_path() {
  local path="$1"
  awk -F '\t' -v p="$path" '$3 == p { print $2; exit }' "$NODES_FILE"
}

node_context() {
  local file="$1"
  local domain cluster id title type tags links body

  domain="$(manifest_domain_for_path "$file")"
  cluster="$(manifest_cluster_for_path "$file")"
  id="$(node_id_for_path "$file")"
  title="$(yaml_field "$file" title || true)"
  type="$(yaml_field "$file" type || true)"
  tags="$(yaml_field "$file" tags || true)"
  links="$(yaml_links_compact "$file" || true)"
  body="$(body_slice "$file" || true)"

  if [[ -z "$title" ]]; then
    title="$(fallback_node_id "$file")"
  fi

  {
    printf -- '--- NODE ---\n'
    printf 'domain: %s\n' "$domain"
    printf 'cluster: %s\n' "$cluster"
    printf 'id: %s\n' "$id"
    printf 'title: %s\n' "$title"
    printf 'type: %s\n' "${type:-unknown}"
    printf 'tags: %s\n' "${tags:-[]}"
    printf 'links: %s\n' "${links:-[]}"
    printf 'body_slice: %s\n' "$body"
  } | redact_secrets
}

build_context() {
  local file

  for file in "$@"; do
    node_context "$file"
  done
}

ids_json_for_paths() {
  local file
  local -a ids

  for file in "$@"; do
    ids+=("$(node_id_for_path "$file")")
  done

  if ((${#ids[@]} == 0)); then
    printf '[]\n'
  else
    printf '%s\n' "${ids[@]}" | jq -R -s 'split("\n") | map(select(length > 0))'
  fi
}

# Все линзы (legacy uniform-режим использует именно этот массив).
LENS_KEYS=(
  "problem"
  "gap"
  "contradiction"
  "stalled"
  "cross-analogy"
  "risk"
  "opportunity"
  "wow"
)

LENS_PROMPTS=(
  "Найди проблемы и болевые точки, которые прямо или косвенно видны в этих нодах."
  "Найди белые пятна: чего не хватает, какие знания, решения или проверки отсутствуют."
  "Найди противоречия между нодами, решениями, целями или предположениями."
  "Найди, что застряло, заброшено или требует следующего действия."
  "Найди переносимые аналогии: какие идеи из одного кластера/домена можно применить в другом."
  "Найди неочевидные риски, слабые сигналы и будущие проблемы."
  "Найди 10x-возможности: малые действия или инсайты с непропорционально большим эффектом."
  "Найди неочевидное важное открытие: то, что трудно заметить при обычном чтении."
)

# NREM-линзы — узкие, consolidating. Цель: усилить уверенность в уже
# известном через повтор + добить confidence существующих хешей.
NREM_LENS_KEYS=("problem" "gap" "stalled")
NREM_LENS_PROMPTS=(
  "Найди проблемы и болевые точки, которые прямо или косвенно видны в этих нодах. Фокус на свежих заметках."
  "Найди белые пятна: чего не хватает, какие знания, решения или проверки отсутствуют. Фокус на недавно изменённом."
  "Найди, что застряло, заброшено или требует следующего действия. Особенно — давние задачи без движения."
)

# REM-линзы — широкие, creative. Цель: новые ассоциации, неочевидные связи.
REM_LENS_KEYS=("contradiction" "cross-analogy" "risk" "opportunity" "wow")
REM_LENS_PROMPTS=(
  "Найди противоречия между нодами, решениями, целями или предположениями."
  "Найди переносимые аналогии: какие идеи из одного кластера/домена можно применить в другом."
  "Найди неочевидные риски, слабые сигналы и будущие проблемы."
  "Найди 10x-возможности: малые действия или инсайты с непропорционально большим эффектом."
  "Найди неочевидное важное открытие: то, что трудно заметить при обычном чтении."
)

# ── Feedback-bias: веса линз/доменов из .feedback.jsonl ──────────────────────
# Emit "key<TAB>weight" (1|2|3) для измерения dim ∈ {lens,domain}: джойн
# feedback.hash → registry(.lens/.domain), neutral=2, useful≥0.5→3, noise≥0.5→1
# (только при n≥3 оценок ключа). Ключи без фидбэка не выводятся (consumer → 2).
fb_weight_lines() {
  local dim="$1"
  [[ "${DREAM_FEEDBACK_BIAS:-1}" == "1" ]] || return 0
  [[ -f "$DREAM_FEEDBACK_FILE" && -f "${INSIGHT_REGISTRY:-}" ]] || return 0
  jq -rn --slurpfile reg "$INSIGHT_REGISTRY" --slurpfile fb "$DREAM_FEEDBACK_FILE" --arg dim "$dim" '
    ($fb | sort_by(.epoch) | reduce .[] as $x ({}; .[$x.hash] = $x.verdict)) as $fv
    | (reduce $reg[] as $r ({};
         ($fv[$r.hash]) as $v
         | if $v == null then .
           else ($r[$dim] // "?") as $k
                | .[$k] = ((.[$k] // {useful:0,known:0,noise:0}) | .[$v] += 1)
           end)) as $agg
    | $agg | to_entries[]
    | .value as $c | (($c.useful//0)+($c.known//0)+($c.noise//0)) as $n
    | "\(.key)\t\(if $n < 3 then 2 elif (($c.noise//0)/$n) >= 0.5 then 1 elif (($c.useful//0)/$n) >= 0.5 then 3 else 2 end)"
  ' 2>/dev/null
}

_gcd() { local a="$1" b="$2" t; while ((b)); do t=$((a % b)); a=$b; b=$t; done; printf '%s' "$a"; }

# Печатает индексы 0..count-1, каждый повторён (weight/gcd) раз, по порядку.
# $1=count, $2=файл "key<TAB>weight", далее keys[i] (ключ для индекса i).
# При равных весах gcd-нормализация даёт 1× каждый → исходный порядок [0..count-1].
build_weighted_idx() {
  local count="$1" wfile="$2"; shift 2
  local -a keys=("$@") w=()
  local i k wt g=0 out="" rep j
  for ((i = 0; i < count; i++)); do
    k="${keys[$i]:-?}"
    wt="$(awk -F'\t' -v k="$k" '$1==k{print $2; f=1} END{if(!f)print 2}' "$wfile" 2>/dev/null)"
    [[ "$wt" =~ ^[0-9]+$ ]] || wt=2
    ((wt < 1)) && wt=1
    w[$i]=$wt
    if ((g == 0)); then g=$wt; else g="$(_gcd "$g" "$wt")"; fi
  done
  ((g < 1)) && g=1
  for ((i = 0; i < count; i++)); do
    rep=$(( w[i] / g )); ((rep < 1)) && rep=1
    for ((j = 0; j < rep; j++)); do out+="$i "; done
  done
  printf '%s' "$out"
}

pick_second_cluster_index() {
  local first_index="$1"
  local cluster_count="$2"
  local first_line first_domain first_cluster candidate_index candidate_line candidate_domain candidate_cluster i

  first_line="$(cluster_line_at "$first_index")"
  IFS=$'\t' read -r first_domain first_cluster <<< "$first_line"

  for ((i = 1; i <= cluster_count; i += 1)); do
    candidate_index=$(((first_index + i) % cluster_count))
    candidate_line="$(cluster_line_at "$candidate_index")"
    IFS=$'\t' read -r candidate_domain candidate_cluster <<< "$candidate_line"
    if [[ "$candidate_domain" != "$first_domain" ]]; then
      printf '%s\n' "$candidate_index"
      return 0
    fi
  done

  for ((i = 1; i <= cluster_count; i += 1)); do
    candidate_index=$(((first_index + i) % cluster_count))
    candidate_line="$(cluster_line_at "$candidate_index")"
    IFS=$'\t' read -r candidate_domain candidate_cluster <<< "$candidate_line"
    if [[ "$candidate_cluster" != "$first_cluster" ]]; then
      printf '%s\n' "$candidate_index"
      return 0
    fi
  done

  printf '%s\n' "$first_index"
}

append_candidate() {
  local json_line="$1"

  {
    flock 9
    printf '%s\n' "$json_line" >> "$CANDIDATES_FILE"
  } 9>"$CANDIDATES_LOCK"
}

run_generation_iteration() {
  local iteration="$1"
  local mode="$2"
  local domain_label="$3"
  local lens_key="$4"
  local lens_text="$5"
  local context="$6"
  local allowed_ids_json="$7"
  local instruction response line normalized valid_count=0

  instruction="$lens_text

Верни только JSONL без markdown и без пояснений вокруг.
Нужно 1-3 инсайта, каждый на отдельной строке, строго в формате:
{\"title\":\"\",\"insight\":\"\",\"why\":\"\",\"novelty\":\"obvious|non-obvious\",\"confidence\":0.7,\"source_ids\":[],\"domain\":\"\",\"lens\":\"\"}

Правила:
- опирайся только на source_ids из контекста;
- source_ids должны быть id нод, которые реально использованы;
- domain поставь \"$domain_label\" или более точный домен из контекста;
- lens поставь \"$lens_key\";
- confidence — твоя уверенность 0.3-1.0, что инсайт точен И применим на практике (а не просто факт). Дефолт 0.7. 0.3-0.5 = гипотеза, 0.6-0.8 = вероятно, 0.9-1.0 = уверен, действие напрашивается;
- insight и why пиши по-русски, конкретно и без общих советов."

  if ! response="$("$GEMINI_SH" -m "${DREAM_GEMINI_MODEL:-flash}" stdin "$instruction" <<< "$context" 2>/dev/null)"; then
    log "stage=generation event=gemini_failed iteration=$iteration mode=$mode lens=$lens_key"
    return 1
  fi

  local objects
  objects="$(printf '%s\n' "$response" \
    | sed -E '/^[[:space:]]*```/d' \
    | jq -c -R 'fromjson? // empty | if type=="array" then .[] else . end' 2>/dev/null || true)"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    if normalized="$(printf '%s\n' "$line" | jq -c -e \
      --arg domain "$domain_label" \
      --arg lens "$lens_key" \
      --argjson allowed "$allowed_ids_json" '
        select(type == "object")
        | .title = (.title // "")
        | .insight = (.insight // "")
        | .why = (.why // "")
        | .novelty = (if .novelty == "obvious" or .novelty == "non-obvious" then .novelty else "non-obvious" end)
        | .source_ids = (
            if (.source_ids | type) == "array"
            then [.source_ids[] | tostring | select(($allowed | index(.)) != null)]
            else []
            end
          )
        | .domain = (if (.domain | type) == "string" and (.domain | length) > 0 then .domain else $domain end)
        | .lens = (if (.lens | type) == "string" and (.lens | length) > 0 then .lens else $lens end)
        | .confidence = (
            if (.confidence | type) == "number"
            then (if .confidence < 0.3 then 0.3
                  elif .confidence > 1.0 then 1.0
                  else .confidence end)
            else 0.7
            end
          )
        | select((.title | type) == "string" and (.title | length) > 0)
        | select((.insight | type) == "string" and (.insight | length) > 0)
        | select((.why | type) == "string" and (.why | length) > 0)
      ' 2>/dev/null)"; then
      # Phase 2: добавить content_hash и provenance ДО append.
      local _title _insight _hash _gen_at
      _title=$(printf '%s' "$normalized" | jq -r '.title')
      _insight=$(printf '%s' "$normalized" | jq -r '.insight')
      _hash=$(content_hash_insight "$_title" "$_insight")
      _gen_at=$(date -u +%FT%TZ)
      normalized=$(printf '%s' "$normalized" | jq -c \
        --arg h "$_hash" \
        --arg dream_id "dream:$UTC_DATE" \
        --argjson iter "$iteration" \
        --arg mode "$mode" \
        --arg target "$domain_label" \
        --arg model "${DREAM_GEMINI_MODEL:-flash}" \
        --argjson sample_ids "$allowed_ids_json" \
        --arg gen_at "$_gen_at" \
        '. + {content_hash: $h, provenance: {
           dream_id: $dream_id, iteration: $iter, mode: $mode, target: $target,
           sample_node_ids: $sample_ids, prompt_version: "v2",
           model: $model, generated_at: $gen_at
        }}')
      append_candidate "$normalized"
      valid_count=$((valid_count + 1))
    fi
  done <<< "$objects"

  log "stage=generation event=gemini_ok iteration=$iteration mode=$mode lens=$lens_key candidates=$valid_count"
  return 0
}

wait_for_one_job() {
  local pid status

  if ((${#PIDS[@]} == 0)); then
    return 0
  fi

  pid="${PIDS[0]}"
  PIDS=("${PIDS[@]:1}")

  if wait "$pid"; then
    status=0
  else
    status=$?
  fi

  if ((status == 0)); then
    RUNS=$((RUNS + 1))
  else
    FAILS=$((FAILS + 1))
  fi

  log "stage=generation iterations_launched=$LAUNCHED runs=$RUNS failed=$FAILS active=${#PIDS[@]}"
}

launch_iteration() {
  local iteration="$1"
  local cluster_count="$2"
  local lens_index lens_key lens_text desired mode domain_label context allowed_ids_json
  local first_index second_index line first_domain first_cluster second_domain second_cluster
  local phase cross_modulo
  local -a selected selected_a selected_b lens_arr prompt_arr _widx

  # Phase selection: NREM первые DREAM_NREM_PASSES итераций (Gemini phase),
  # REM остальные. Для Sonnet phase (siter 0..N) ровно те же inputs.
  if (( DREAM_NREM_PASSES > 0 )) && (( iteration < DREAM_NREM_PASSES )); then
    phase="nrem"
    lens_arr=("${NREM_LENS_KEYS[@]}")
    prompt_arr=("${NREM_LENS_PROMPTS[@]}")
    desired=$((3 + (iteration % 3)))     # 3-5 нод
    cross_modulo=0                        # cross выключен в NREM
    export DREAM_RECENT_WEIGHT_PCT=90    # агрессивный recency-bias
  else
    phase="rem"
    if (( DREAM_NREM_PASSES > 0 )); then
      lens_arr=("${REM_LENS_KEYS[@]}")
      prompt_arr=("${REM_LENS_PROMPTS[@]}")
    else
      # legacy режим: все линзы вместе
      lens_arr=("${LENS_KEYS[@]}")
      prompt_arr=("${LENS_PROMPTS[@]}")
    fi
    desired=$((5 + (iteration % 5)))     # 5-9 нод (большие сэмплы)
    cross_modulo=3                        # cross каждый 3-й проход
    export DREAM_RECENT_WEIGHT_PCT="${_DREAM_RECENT_WEIGHT_PCT_BASE:-70}"
  fi

  # Взвешенная по фидбэку ротация линз (пусто → исходный round-robin).
  _widx=()
  if [[ "$phase" == "nrem" ]]; then
    _widx=("${WEIGHTED_NREM_IDX[@]}")
  elif (( DREAM_NREM_PASSES > 0 )); then
    _widx=("${WEIGHTED_REM_IDX[@]}")
  else
    _widx=("${WEIGHTED_LENS_IDX[@]}")
  fi
  if ((${#_widx[@]} > 0)); then
    lens_index="${_widx[$((iteration % ${#_widx[@]}))]}"
  else
    lens_index=$((iteration % ${#lens_arr[@]}))
  fi
  lens_key="${lens_arr[$lens_index]}"
  lens_text="${prompt_arr[$lens_index]}"
  mode="single"

  if (( cross_modulo > 0 )) && ((cluster_count >= 2 && iteration % cross_modulo == cross_modulo - 1)); then
    mode="cross"
    desired=$((desired + 2))
    if ((${#WEIGHTED_CLUSTER_IDX[@]} > 0)); then
      first_index="${WEIGHTED_CLUSTER_IDX[$((iteration % ${#WEIGHTED_CLUSTER_IDX[@]}))]}"
    else
      first_index=$((iteration % cluster_count))
    fi
    second_index="$(pick_second_cluster_index "$first_index" "$cluster_count")"

    line="$(cluster_line_at "$first_index")"
    IFS=$'\t' read -r first_domain first_cluster <<< "$line"
    line="$(cluster_line_at "$second_index")"
    IFS=$'\t' read -r second_domain second_cluster <<< "$line"

    mapfile -t selected_a < <(sample_paths "$first_domain" "$first_cluster" "$iteration" $(((desired + 1) / 2)))
    mapfile -t selected_b < <(sample_paths "$second_domain" "$second_cluster" "$((iteration + 11))" $((desired / 2)))
    selected=("${selected_a[@]}" "${selected_b[@]}")
    domain_label="$first_domain/$first_cluster + $second_domain/$second_cluster"
  else
    if ((${#WEIGHTED_CLUSTER_IDX[@]} > 0)); then
      first_index="${WEIGHTED_CLUSTER_IDX[$((iteration % ${#WEIGHTED_CLUSTER_IDX[@]}))]}"
    else
      first_index=$((iteration % cluster_count))
    fi
    line="$(cluster_line_at "$first_index")"
    IFS=$'\t' read -r first_domain first_cluster <<< "$line"

    mapfile -t selected < <(sample_paths "$first_domain" "$first_cluster" "$iteration" "$desired")
    domain_label="$first_domain/$first_cluster"
  fi

  if ((${#selected[@]} == 0)); then
    log "stage=generation event=skip_empty_sample iteration=$iteration mode=$mode lens=$lens_key"
    return 1
  fi

  context="$(build_context "${selected[@]}")"
  allowed_ids_json="$(ids_json_for_paths "${selected[@]}")"

  if [[ "${RUN_ENGINE:-gemini}" == "sonnet" ]]; then
    run_sonnet_iteration "$iteration" "$mode" "$domain_label" "$lens_key" "$lens_text" "$context" "$allowed_ids_json" &
  else
    run_generation_iteration "$iteration" "$mode" "$domain_label" "$lens_key" "$lens_text" "$context" "$allowed_ids_json" &
  fi
  PIDS+=("$!")
  LAUNCHED=$((LAUNCHED + 1))

  log "stage=${RUN_ENGINE:-gemini} phase=$phase iterations_launched=$LAUNCHED runs=$RUNS active=${#PIDS[@]} mode=$mode lens=$lens_key target=\"$domain_label\""
}

# Дедупликация кандидатов против registry .insight-hashes.jsonl.
# Дубликаты (hash уже в окне DREAM_DEDUP_WINDOW_DAYS) ВЫХОДЯТ из CANDIDATES_FILE,
# а у их соответствующих registry-записей инкрементится hit_count + confidence.
# Так синтез видит только новые инсайты, а повторяющиеся набирают силу в registry.
dedup_against_registry() {
  if [[ ! -s "$CANDIDATES_FILE" ]] || [[ ! -f "$INSIGHT_REGISTRY" ]]; then
    log "stage=dedup event=skip reason=empty_registry_or_candidates"
    return 0
  fi
  local tmp dup_count=0 kept_count=0 hash
  tmp="$(mktemp "$DREAM_OUT_DIR/.candidates-deduped.XXXXXX")"
  register_temp_file "$tmp"
  while IFS= read -r cand; do
    [[ -z "$cand" ]] && continue
    hash=$(printf '%s' "$cand" | jq -r '.content_hash // ""')
    if [[ -n "$hash" ]] && registry_has_hash "$hash"; then
      registry_bump_hit "$hash"
      dup_count=$((dup_count + 1))
      log "stage=dedup event=duplicate_bumped hash=$hash"
    else
      printf '%s\n' "$cand" >> "$tmp"
      kept_count=$((kept_count + 1))
    fi
  done < "$CANDIDATES_FILE"
  mv "$tmp" "$CANDIDATES_FILE"
  log "stage=dedup event=done kept=$kept_count duplicates=$dup_count"
}

# Записать ВСЕ свежие кандидаты (после dedup) в registry — каждая запись = новый
# инсайт со счётом hits=1, confidence от LLM.
register_new_candidates() {
  if [[ ! -s "$CANDIDATES_FILE" ]]; then return 0; fi
  local added=0 hash title lens domain confidence
  while IFS= read -r cand; do
    [[ -z "$cand" ]] && continue
    hash=$(printf '%s' "$cand" | jq -r '.content_hash // ""')
    [[ -z "$hash" ]] && continue
    # Не записывать дубликаты — они уже в registry (после dedup они отфильтрованы).
    if registry_has_hash "$hash"; then continue; fi
    title=$(printf '%s' "$cand" | jq -r '.title // ""')
    lens=$(printf '%s' "$cand" | jq -r '.lens // ""')
    domain=$(printf '%s' "$cand" | jq -r '.domain // ""')
    confidence=$(printf '%s' "$cand" | jq -r '.confidence // 0.7')
    local cand_dream_id
    cand_dream_id=$(printf '%s' "$cand" | jq -r '.provenance.dream_id // ""')
    registry_append "$hash" "$title" "$lens" "$domain" "$confidence" "$cand_dream_id"
    added=$((added + 1))
  done < "$CANDIDATES_FILE"
  log "stage=registry event=appended count=$added"
}

candidate_count() {
  if [[ ! -s "$CANDIDATES_FILE" ]]; then
    printf '0\n'
  else
    wc -l < "$CANDIDATES_FILE" | tr -d '[:space:]'
  fi
}

# Проверка насыщения для pass-цикла. Состояние держит вызывающий в двух
# глобальных переменных (имена передаются 1-м и 2-м аргументами через nameref):
# prev_count — кол-во кандидатов на прошлом чекпоинте, passes_since — проходов с
# тех пор. Возвращает 0 (стоп), если интервал набран и прирост < min_yield.
# 3-й аргумент — метка движка для лога. set -e: инкремент делаем через
# присваивание, а не (( x++ )), чтобы нулевой результат не уронил скрипт.
saturation_reached() {
  local -n _sat_prev="$1" _sat_since="$2"
  local label="$3" cur delta
  (( DREAM_SATURATION_MIN_YIELD > 0 )) || return 1
  _sat_since=$(( _sat_since + 1 ))
  (( _sat_since >= DREAM_SATURATION_CHECK_INTERVAL )) || return 1
  cur="$(candidate_count)"
  delta=$(( cur - _sat_prev ))
  _sat_prev=$cur
  _sat_since=0
  if (( delta < DREAM_SATURATION_MIN_YIELD )); then
    log "stage=generation event=early_stop reason=saturation engine=$label candidates=$cur delta=$delta interval=$DREAM_SATURATION_CHECK_INTERVAL min_yield=$DREAM_SATURATION_MIN_YIELD"
    return 0
  fi
  return 1
}

candidate_breakdown() {
  local field="$1"

  if [[ ! -s "$CANDIDATES_FILE" ]]; then
    printf '%s\n' "- none: 0"
    return 0
  fi

  jq -r -s --arg field "$field" '
    group_by(.[$field] // "unknown")
    | .[]
    | "- " + (.[0][$field] // "unknown") + ": " + (length | tostring)
  ' "$CANDIDATES_FILE"
}

token_usage_summary() {
  if [[ ! -s "$USAGE_SINK" ]]; then
    printf 'calls=0 in=0 out=0\n'
    return 0
  fi

  jq -s -r '
    {calls: length,
     in: (map(.prompt_tokens // 0) | add // 0),
     out: (map(.candidates_tokens // 0) | add // 0)}
    | "calls=\(.calls) in=\(.in) out=\(.out)"
  ' "$USAGE_SINK" 2>/dev/null || printf 'calls=0 in=0 out=0\n'
}

fallback_synthesis() {
  jq -r -s '
    sort_by((.novelty == "non-obvious") | not)
    | .[0:10]
    | to_entries[]
    | "## " + ((.key + 1) | tostring) + ". " + .value.title + "\n\n" +
      "**Суть:** " + .value.insight + "\n\n" +
      "**Почему важно:** " + .value.why + "\n\n" +
      "**Предлагаемое действие:** Проверить источник, сформулировать следующий конкретный шаг и связать его с текущими планами.\n\n" +
      "**source_ids:** " + (.value.source_ids | join(", ")) + "\n\n" +
      "**Метка:** " + .value.novelty + "\n"
  ' "$CANDIDATES_FILE"

  cat <<'MERMAID'

```mermaid
flowchart TD
  A[Кандидаты инсайтов] --> B[ТОП-10]
  B --> C[Следующие действия]
```
MERMAID
}

run_synthesis() {
  local synthesis_text

  PROMPT_FILE="$(mktemp "$DREAM_OUT_DIR/.brain-dream-claude-prompt.XXXXXX")"
  register_temp_file "$PROMPT_FILE"

  # Per introspector proposal #2: предотвратить «шум в синтезе» — взять только
  # топ-N кандидатов по confidence. При меньшем объёме — все.
  local _total _candidates_for_prompt
  _total=$(wc -l < "$CANDIDATES_FILE" 2>/dev/null || echo 0)
  if (( _total > DREAM_SYNTH_TOP_N )); then
    _candidates_for_prompt="$DREAM_OUT_DIR/.candidates-top.jsonl"
    register_temp_file "$_candidates_for_prompt"
    jq -s -c --argjson n "$DREAM_SYNTH_TOP_N" \
      'sort_by(-(.confidence // 0.7)) | .[:$n] | .[]' "$CANDIDATES_FILE" \
      > "$_candidates_for_prompt"
    log "stage=synthesis event=pruned_for_synth total=$_total kept=$DREAM_SYNTH_TOP_N"
  else
    _candidates_for_prompt="$CANDIDATES_FILE"
  fi

  {
    cat <<'PROMPT'
Ты синтезатор. Из этих кандидатов-инсайтов собери ТОП-10 по (важность × новизна × применимость), дедупни близкие.
Для каждого: заголовок, суть, почему важно, предлагаемое действие, ссылки на source_ids, метка obvious/non-obvious.
В конце — Mermaid flowchart связей топ-10.
Ответ — Markdown на русском.

Кандидаты JSONL (отсортированы по убыванию confidence, не более N топ):
PROMPT
    cat "$_candidates_for_prompt"
  } > "$PROMPT_FILE"

  # Промпт идёт через stdin, НЕ одним CLI-аргументом: при ~120 кандидатах он
  # превышает лимит Linux на длину одного аргумента (MAX_ARG_STRLEN ≈ 128 КБ) →
  # «Argument list too long» → мгновенный фейл синтеза (нода = сырой fallback).
  if synthesis_text="$(claude -p --model "$DREAM_SONNET_MODEL" < "$PROMPT_FILE" 2>/dev/null)" \
     && [[ -n "$synthesis_text" ]]; then
    printf '%s\n' "$synthesis_text"
  else
    log "stage=synthesis event=claude_failed action=fallback_synthesis"
    {
      printf 'Claude synthesis failed; ниже fallback-сводка из кандидатов.\n\n'
      fallback_synthesis
    }
  fi
}

deadline_summary_line() {
  local now overrun_until

  if ((DEADLINE_EPOCH == 0)); then
    printf 'нет\n'
    return 0
  fi

  now="$(now_epoch)"
  overrun_until=$((DEADLINE_EPOCH + DREAM_OVERRUN_MIN * 60))

  if ((now <= DEADLINE_EPOCH)); then
    printf 'не превышен\n'
  elif ((now <= overrun_until)); then
    printf 'превышен в soft-overrun окне\n'
  else
    printf 'превышен за предел soft-overrun окна\n'
  fi
}

write_markdown_output() {
  local synthesis_text="$1"
  local count="$2"
  local stage_history="$3"

  {
    printf '# Сон мозга — %s UTC\n\n' "$UTC_DATE"
    printf '## Header\n\n'
    printf -- '- Date UTC: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf -- '- Domains: %s\n' "$DREAM_DOMAINS"
    printf -- '- Runs successful: %s\n' "$RUNS"
    printf -- '- Iterations launched: %s\n' "$LAUNCHED"
    printf -- '- Failed calls: %s\n' "$FAILS"
    printf -- '- Stages: %s\n' "$stage_history"
    printf -- '- Stop reason: %s\n' "$STOP_REASON"
    printf -- '- Deadline cut generation: %s\n' "$([[ "$DEADLINE_CUT" == "1" ]] && printf 'yes' || printf 'no')"
    printf -- '- Deadline UTC: %s\n' "${DREAM_DEADLINE_UTC:-none}"
    printf -- '- Deadline status at write: %s\n' "$(deadline_summary_line)"
    printf -- '- Overrun budget: %s runs, %s min\n' "$DREAM_OVERRUN_RUNS" "$DREAM_OVERRUN_MIN"
    printf -- '- Gemini spent: $%s of $%s limit (in $%s/M, out $%s/M)\n' \
      "$(spent_usd)" "$DREAM_COST_LIMIT_USD" "$DREAM_PRICE_IN_PER_M" "$DREAM_PRICE_OUT_PER_M"
    printf -- '- Token usage: %s\n\n' "$(token_usage_summary)"

    if [[ "$DREAM_SONNET_COMPARE" == "1" ]]; then
      printf '## Сравнение Gemini vs Sonnet\n\n'
      printf 'Gemini оплачивается из API-кошелька ($); Sonnet идёт через подписку Claude Code (лимит %s вызовов / 5ч окно), поэтому его реальный расход — доля сессии, а не доллары. API-цена Sonnet справа — справочная, в биллинге не списывается.\n\n' "$DREAM_SONNET_SESSION_LIMIT_CALLS"
      printf -- '| Модель | Проходов | Токены (in/out) | Реальный расход | Справочно (API-прайс) |\n'
      printf -- '|---|---|---|---|---|\n'
      printf -- '| Gemini (%s) | %s | %s | **$%s** из API-баланса | — |\n' \
        "${DREAM_GEMINI_MODEL:-flash}" "$GEMINI_LAUNCHED" \
        "$(token_usage_summary | sed -E 's/calls=[0-9]+ in=([0-9]+) out=([0-9]+)/\1 \/ \2/')" "$(spent_usd)"
      printf -- '| Sonnet (%s) | %s | %s | **%s%% сессии** (%s / %s вызовов) | $%s |\n' \
        "$DREAM_SONNET_MODEL" "$SONNET_LAUNCHED" \
        "$(token_usage_summary_sonnet | sed -E 's/calls=[0-9]+ in=([0-9]+) out=([0-9]+)/\1 \/ \2/')" \
        "$(sonnet_session_share_pct)" "$(sonnet_calls)" "$DREAM_SONNET_SESSION_LIMIT_CALLS" "$(spent_usd_sonnet)"
      printf -- '\n- Sonnet stop reason: %s (cap %s%% = %s вызовов)\n' "$STOP_REASON_SONNET" \
        "$DREAM_SONNET_SESSION_CAP_PCT" \
        "$(awk -v l="$DREAM_SONNET_SESSION_LIMIT_CALLS" -v p="$DREAM_SONNET_SESSION_CAP_PCT" 'BEGIN{printf "%d", l*p/100}')"
      printf -- '- Примечание: claude CLI тащит ~32K системного контекста на вызов → input-токены Sonnet за проход на порядок больше Gemini.\n\n'
    fi

    printf '## Синтез\n\n'
    printf '%s\n\n' "$synthesis_text"

    printf '## Статистика\n\n'
    printf -- '- Candidate count: %s\n\n' "$count"
    printf '### By domain\n\n'
    candidate_breakdown "domain"
    printf '\n### By lens\n\n'
    candidate_breakdown "lens"
    if [[ "$DREAM_SONNET_COMPARE" == "1" ]]; then
      printf '\n### By model\n\n'
      candidate_breakdown "model"
    fi
    printf '\n'
  } > "$OUT_MD"
}

# Записать результат сна нодой в домен dreams (~/brain/dreams/nodes). Домен
# изолирован — сон его не читает. Reindex движка тут НЕ делаем (нужен MCP);
# нода появится в brain_search после ближайшего reindex. Если домен — git-репо,
# коммитим (без push: remote у dreams не настроен).
# Jaccard similarity на двух пробел-разделённых списках id.
# Используется для решения «считать ли сегодняшний сон продолжением вчерашнего».
_jaccard_score() {
  local a="$1" b="$2"
  if [[ -z "$a" || -z "$b" ]]; then
    printf '0\n'; return 0
  fi
  awk -v a="$a" -v b="$b" '
    BEGIN {
      na = split(a, aa, " ")
      nb = split(b, bb, " ")
      for (i = 1; i <= na; i++) if (aa[i] != "") A[aa[i]] = 1
      for (j = 1; j <= nb; j++) if (bb[j] != "") B[bb[j]] = 1
      inter = 0; union = 0
      for (k in A) { union++; if (k in B) inter++ }
      for (k in B) if (!(k in A)) union++
      if (union == 0) { print "0"; exit }
      printf "%.3f", inter / union
    }'
}

# Достать source_ids из frontmatter существующей dream-ноды (поле relates-to
# через python-yaml или простой grep).
_extract_relates_to_from_dream() {
  local node_path="$1"
  [[ -f "$node_path" ]] || return 0
  # Простой парс: ищем блок relates-to в links, до следующего ключа верхнего уровня.
  awk '
    /^---/ { sep++; if (sep >= 2) exit; next }
    sep == 1 && /^links:/ { in_links = 1; next }
    in_links && /^[a-z]/ && !/^  / { in_links = 0; next }
    in_links && /^  relates-to:/ { in_rt = 1; next }
    in_links && in_rt && /^    - / { sub(/^    - /, ""); print; next }
    in_links && /^  [a-z]/ && in_rt { in_rt = 0; next }
  ' "$node_path" | tr "\n" " "
}

write_dream_node() {
  local synthesis_text="$1"
  local node_dir="$DREAM_NODE_ROOT/nodes"
  local node_file="$node_dir/dream-$UTC_DATE.md"
  local title

  if ! mkdir -p "$node_dir" 2>/dev/null; then
    log "stage=node event=mkdir_failed dir=$node_dir"
    return 0
  fi

  title="$(extract_top_titles "$OUT_MD" | sed -n '1p' | sed -E 's/^[0-9]+\.[[:space:]]*//')"
  [[ -z "$title" ]] && title="ночной синтез"
  title="${title//\'/\'\'}"

  # === Active consolidation: рёбра relates-to и continues-in ===
  # relates-to: уникальные source_ids из TOP-10 (по confidence DESC) кандидатов.
  local relates_to_json relates_to_space
  relates_to_json=$(jq -s -c \
    'sort_by(-(.confidence // 0.7)) | .[:10] | [.[].source_ids[]?] | unique' \
    "$CANDIDATES_FILE" 2>/dev/null || echo '[]')
  relates_to_space=$(printf '%s' "$relates_to_json" | jq -r '.[]' 2>/dev/null | tr "\n" " ")

  # continues-in: ищем последнюю dream-ноду до сегодняшней, считаем Jaccard
  # source_ids. Порог DREAM_CONTINUES_JACCARD (default 0.3) — если выше, помечаем.
  local prev_dream prev_relates jaccard continues_in_id=""
  prev_dream=$(find "$node_dir" -maxdepth 1 -name 'dream-*.md' -type f \
    ! -name "dream-$UTC_DATE.md" 2>/dev/null | sort | tail -1)
  if [[ -n "$prev_dream" ]]; then
    prev_relates=$(_extract_relates_to_from_dream "$prev_dream")
    if [[ -n "$prev_relates" ]] && [[ -n "$relates_to_space" ]]; then
      jaccard=$(_jaccard_score "$prev_relates" "$relates_to_space")
      local threshold="${DREAM_CONTINUES_JACCARD:-0.3}"
      if awk -v j="$jaccard" -v t="$threshold" 'BEGIN{exit !(j >= t)}'; then
        # id формата dream:<date> из basename
        continues_in_id=$(basename "$prev_dream" .md | sed 's/^dream-/dream:/')
        log "stage=node event=continues_detected prev=$continues_in_id jaccard=$jaccard"
      fi
    fi
  fi

  # Top insight hashes — для отслеживания повторяемости конкретных инсайтов.
  local top_hashes_json
  top_hashes_json=$(jq -s -c \
    'sort_by(-(.confidence // 0.7)) | .[:10] | [.[].content_hash // empty]' \
    "$CANDIDATES_FILE" 2>/dev/null || echo '[]')

  {
    printf -- '---\n'
    printf -- 'id: dream:%s\n' "$UTC_DATE"
    printf -- 'type: dream\n'
    printf -- "title: 'Сон мозга %s: %s'\n" "$UTC_DATE" "$title"
    printf -- 'source: brain-dream\n'
    printf -- 'source_system: brain-dream\n'
    printf -- "observed_at: '%s'\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf -- "date: '%s'\n" "$UTC_DATE"
    printf -- 'domains: [%s]\n' "$(printf '%s' "$DREAM_DOMAINS" | sed 's/ /, /g')"
    printf -- 'gemini_passes: %s\n' "$GEMINI_LAUNCHED"
    printf -- 'gemini_cost_usd: %s\n' "$(spent_usd)"
    printf -- 'sonnet_passes: %s\n' "$SONNET_LAUNCHED"
    printf -- 'sonnet_calls: %s\n' "$(sonnet_calls)"
    printf -- 'sonnet_session_limit: %s\n' "$DREAM_SONNET_SESSION_LIMIT_CALLS"
    printf -- 'sonnet_session_share_pct: %s\n' "$(sonnet_session_share_pct)"
    printf -- 'sonnet_ref_api_cost_usd: %s  # справочная API-цена; через подписку не списывается\n' "$(spent_usd_sonnet)"
    printf -- 'candidate_count: %s\n' "$(candidate_count)"
    printf -- 'top_insight_hashes: %s\n' "$top_hashes_json"

    # Структурированные рёбра вместо links: [].
    printf -- 'links:\n'
    printf -- '  relates-to:\n'
    printf '%s' "$relates_to_json" | jq -r '.[]' 2>/dev/null | while IFS= read -r src_id; do
      [[ -z "$src_id" ]] && continue
      printf -- "    - '%s'\n" "${src_id//\'/\'\'}"
    done
    if [[ -n "$continues_in_id" ]]; then
      printf -- '  continues-in:\n'
      printf -- "    - '%s'   # jaccard=%s threshold=%s\n" \
        "$continues_in_id" "$jaccard" "${DREAM_CONTINUES_JACCARD:-0.3}"
    fi

    printf -- 'tags: [dream, synthesis]\n'
    printf -- '---\n\n'
    printf '%s\n\n' "$synthesis_text"
  } > "$node_file"
  log "stage=node event=written file=$node_file relates_to_count=$(printf '%s' "$relates_to_json" | jq 'length')"

  if git -C "$DREAM_NODE_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$DREAM_NODE_ROOT" add "$node_file" >/dev/null 2>&1 || true
    git -C "$DREAM_NODE_ROOT" -c user.name='brain-dream' -c user.email='brain-dream@local' \
      commit -q -m "dream: $UTC_DATE" >/dev/null 2>&1 || true
    log "stage=node event=committed"
  fi
}

extract_top_titles() {
  local file="$1"

  awk '
    function clean(s) {
      sub(/^#+[[:space:]]*/, "", s)        # markdown-заголовок: ## / ####
      sub(/^#[[:space:]]*/, "", s)         # остаток "#" в форме "#1"
      sub(/^[0-9]+[[:space:]]*[.):—–-][[:space:]]*/, "", s)  # "N." / "N)" / "N —" / "N -"
      gsub(/\*\*/, "", s)
      sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s)
      return s
    }
    # Заголовок-пункт: "## #1 — …", "#### 1) …", "## 1. …".
    /^#{1,6}[[:space:]]*#?[[:space:]]*[0-9]+[[:space:]]*[.):—–-]/ {
      title = clean($0)
      if (length(title) > 0) {
        count += 1
        print count ". " title
      }
      next
    }
    # Голый нумерованный пункт: "1. …", "1) …".
    /^[0-9]+[.)][[:space:]]+/ {
      title = clean($0)
      if (length(title) > 0) {
        count += 1
        print count ". " title
      }
    }
    count >= 10 { exit }
  ' "$file"
}

fallback_titles_from_candidates() {
  if [[ ! -s "$CANDIDATES_FILE" ]]; then
    return 0
  fi

  jq -r -s '.[0:10] | to_entries[] | ((.key + 1) | tostring) + ". " + .value.title' "$CANDIDATES_FILE"
}

# Дедуп ленты против недавних ночей. Тащит топ-10 из ## Синтез готового OUT_MD,
# Gemini Flash сверяет с показанным за DREAM_DIGEST_DEDUP_DAYS дней
# (.digest-published.jsonl), гасит повторы и кладёт дедупнутый нумерованный блок
# в DIGEST_TITLES_FILE (его потом берёт digest_title_block). Сам инструмент
# дописывает показанное в реестр и компактит его. Fail-open: при любой осечке
# инструмент печатает все заголовки (или возвращает !=0) — лента не страдает.
run_digest_dedup() {
  local tool="$BRAIN_DREAM_REPO/tools/dream-digest-dedup.py"
  if [[ ! -f "$tool" ]]; then
    log "stage=digest-dedup event=tool_missing path=$tool"
    return 0
  fi
  if python3 "$tool" render \
       --synthesis "$OUT_MD" \
       --registry "$DIGEST_REGISTRY" \
       --today "$UTC_DATE" \
       --days "$DREAM_DIGEST_DEDUP_DAYS" \
       --gemini "$GEMINI_SH" \
       --model "$DREAM_DIGEST_DEDUP_MODEL" \
       --max-titles 10 \
       > "$DIGEST_TITLES_FILE" 2> >(while IFS= read -r l; do log "stage=digest-dedup $l"; done); then
    log "stage=digest-dedup event=done titles_file=$DIGEST_TITLES_FILE"
  else
    # !=0 → инсайты не распарсились; чистим файл, digest_title_block упадёт на
    # extract_top_titles / candidate-fallback.
    : > "$DIGEST_TITLES_FILE"
    log "stage=digest-dedup event=fallback reason=no_insights"
  fi
}

# Единый источник нумерованного блока заголовков для всех TG-веток: дедупнутый
# блок из run_digest_dedup, иначе — extract_top_titles, иначе — кандидаты.
digest_title_block() {
  local titles
  if [[ -s "$DIGEST_TITLES_FILE" ]]; then
    cat "$DIGEST_TITLES_FILE"
    return 0
  fi
  titles="$(extract_top_titles "$OUT_MD" || true)"
  [[ -z "$titles" ]] && titles="$(fallback_titles_from_candidates || true)"
  [[ -z "$titles" ]] && titles="топ-10 не извлечён; см. ноду/файл"
  printf '%s\n' "$titles"
}

load_telegram_pair() {
  local env_file="$HOME/.config/digest-bot/env"
  local pair tab

  TG_TOKEN=""
  TG_CHAT=""

  if [[ ! -f "$env_file" ]]; then
    log "stage=telegram event=missing_env path=$env_file"
    return 1
  fi

  pair="$(
    set +e +u
    # shellcheck source=/dev/null
    source "$env_file" >/dev/null 2>&1
    set +x
    token="${DIGEST_BOT_TOKEN:-${TELEGRAM_BOT_TOKEN:-${TG_BOT_TOKEN:-${TELEGRAM_TOKEN:-${TG_TOKEN:-${BOT_TOKEN:-}}}}}}"
    chat="${DIGEST_ADMIN_CHAT_ID:-${TELEGRAM_CHAT_ID:-${TG_CHAT_ID:-${CHAT_ID:-${TELEGRAM_CHAT:-}}}}}"
    printf '%s\t%s\n' "$token" "$chat"
  )"

  tab=$'\t'
  TG_TOKEN="${pair%%${tab}*}"
  TG_CHAT="${pair#*${tab}}"

  if [[ -z "$TG_TOKEN" || -z "$TG_CHAT" ]]; then
    log "stage=telegram event=missing_token_or_chat"
    return 1
  fi

  return 0
}

truncate_for_telegram() {
  local text="$1"

  if ((${#text} > 4000)); then
    printf '%s\n\n%s\n' "${text:0:3850}" "…обрезано до лимита Telegram; полный текст в Markdown-файле."
  else
    printf '%s\n' "$text"
  fi
}

send_telegram_message() {
  local text="$1"
  local safe_text

  if ! load_telegram_pair; then
    return 0
  fi

  safe_text="$(truncate_for_telegram "$text")"

  if curl -fs -o /dev/null -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT}" \
    -d "disable_web_page_preview=true" \
    --data-urlencode "text=${safe_text}"; then
    log "stage=telegram event=sendMessage_ok"
  else
    log "stage=telegram event=sendMessage_failed"
  fi
}

# Текстовое сообщение с инлайн-клавиатурой (reply_markup — компактный JSON).
send_telegram_message_markup() {
  local text="$1" markup="$2"

  if ! load_telegram_pair; then
    return 0
  fi

  if curl -fs -o /dev/null -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT}" \
    -d "disable_web_page_preview=true" \
    --data-urlencode "text=${text}" \
    --data-urlencode "reply_markup=${markup}"; then
    log "stage=telegram event=feedback_buttons_ok"
  else
    log "stage=telegram event=feedback_buttons_failed"
  fi
}

# Интерактивная оценка: одно сообщение с нумерованным списком топ-N кандидатов
# по confidence и сеткой кнопок (строка на инсайт: 👍/➕/👎). callback_data =
# df:<content_hash>:<u|k|n>:<idx>. Нажатие ловит digest-bot → dream-feedback.sh.
# Синхронно опубликовать ноду сна в Notion (идемпотентно с cron-publisher 18:30)
# и вернуть URL полного документа — чтобы вложить ссылку в дайджест сразу.
# Publisher пишет notion_url во frontmatter ноды; читаем оттуда. Best-effort.
publish_dream_and_get_url() {
  [[ "${DREAM_PUBLISH_NOTION:-1}" == "1" ]] || return 0
  local node="${DREAM_NODE_ROOT:-$HOME/brain/dreams}/nodes/dream-${UTC_DATE}.md"
  local pub="$BRAIN_DREAM_REPO/agents/dream-publisher-notion.sh"
  [[ -f "$node" && -f "$pub" ]] || return 0
  printf '{"invoked_by":"brain-dream"}\n' | timeout 90 bash "$pub" >/dev/null 2>&1 || true
  grep -m1 '^notion_url:' "$node" 2>/dev/null \
    | sed -E "s/^notion_url:[[:space:]]*['\"]?//; s/['\"]?[[:space:]]*$//"
}

send_feedback_buttons() {
  local link_url="${1:-}"
  local n="${DREAM_FEEDBACK_BUTTONS:-10}" payload lines markup top_count footer

  (( n > 0 )) || return 0
  [[ -s "$CANDIDATES_FILE" ]] || return 0

  payload="$(jq -s --argjson n "$n" '
    ( map(select((.content_hash // "") != "" and (.title // "") != ""))
      | group_by(.content_hash) | map(max_by(.confidence))
      | sort_by(-.confidence) | .[:$n] ) as $top
    | { count: ($top | length),
        lines: ($top | to_entries
                 | map("\(.key+1). \(.value.title | gsub("\n";" ") | .[0:72])")
                 | join("\n")),
        kb: { inline_keyboard: ($top | to_entries | map(
                (.key+1) as $i | (.value.content_hash) as $h |
                [ {text:"\($i) 👍", callback_data:"df:\($h):u:\($i)"},
                  {text:"\($i) ➕", callback_data:"df:\($h):k:\($i)"},
                  {text:"\($i) 👎", callback_data:"df:\($h):n:\($i)"} ])) } }
  ' "$CANDIDATES_FILE" 2>/dev/null)"

  [[ -z "$payload" ]] && return 0
  top_count="$(jq -r '.count // 0' <<<"$payload" 2>/dev/null || echo 0)"
  (( top_count > 0 )) || return 0

  lines="$(jq -r '.lines' <<<"$payload")"
  markup="$(jq -c '.kb' <<<"$payload")"

  # Ссылка на полный текст (суть/почему/действие/источники по каждому инсайту).
  footer="👍 полезно · ➕ знал · 👎 мимо"
  if [[ -n "$link_url" ]]; then
    footer="${footer}"$'\n\n'"📖 Полный текст (суть · почему · действие): ${link_url}"
  fi

  send_telegram_message_markup \
    "🌙 Сон мозга ${UTC_DATE} — оцени инсайты"$'\n\n'"${lines}"$'\n\n'"${footer}" \
    "$markup"
}

send_telegram_photo() {
  local photo_path="$1"
  local caption="$2"

  if ! load_telegram_pair; then
    return 0
  fi

  if curl -fs -o /dev/null -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendPhoto" \
    -F "chat_id=${TG_CHAT}" \
    -F "photo=@${photo_path}" \
    -F "caption=${caption}"; then
    log "stage=image event=sendPhoto_ok"
  else
    log "stage=image event=sendPhoto_failed"
  fi
}

telegram_summary_text() {
  local titles

  titles="$(digest_title_block)"

  printf 'Сон мозга %s UTC\n\n%s\n\nGemini: $%s / $%s (%s)\nСтоп: %s\nФайл: %s\n' \
    "$UTC_DATE" "$titles" "$(spent_usd)" "$DREAM_COST_LIMIT_USD" \
    "$(token_usage_summary)" "$STOP_REASON" "$OUT_MD"
}

# Отправить ОДНО фото по URL (обложка с Higgsfield CloudFront) с подписью.
# Telegram sendPhoto принимает прямой URL в поле photo.
send_telegram_photo_url() {
  local url="$1" caption="$2"

  if ! load_telegram_pair; then
    return 0
  fi

  if curl -fs -o /dev/null -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendPhoto" \
    --data-urlencode "chat_id=${TG_CHAT}" \
    --data-urlencode "photo=${url}" \
    --data-urlencode "caption=${caption}"; then
    log "stage=telegram event=sendPhoto_url_ok"
  else
    log "stage=telegram event=sendPhoto_url_failed"
  fi
}

# Подпись для режима single: топ-10 + раздельный расход, обрезано под лимит
# подписи Telegram (1024 символа).
telegram_caption_single() {
  local titles spend

  titles="$(digest_title_block)"

  spend="Gemini: \$$(spent_usd)"
  if [[ "$DREAM_SONNET_COMPARE" == "1" ]]; then
    spend="$spend | Sonnet: $(sonnet_session_share_pct)% сессии ($(sonnet_calls)/$DREAM_SONNET_SESSION_LIMIT_CALLS)"
  fi

  printf '🌙 Сон мозга %s\n\n%s\n\n%s' "$UTC_DATE" "$titles" "$spend" | cut -c1-1024
}

load_gemini_key() {
  local env_file="$HOME/.config/gemini/config.env"
  local key

  GEMINI_API_KEY_VALUE="${GEMINI_API_KEY:-}"

  if [[ -z "$GEMINI_API_KEY_VALUE" && -f "$env_file" ]]; then
    key="$(
      set +e +u
      # shellcheck source=/dev/null
      source "$env_file" >/dev/null 2>&1
      set +x
      printf '%s\n' "${GEMINI_API_KEY:-}"
    )"
    GEMINI_API_KEY_VALUE="$key"
  fi

  if [[ -z "$GEMINI_API_KEY_VALUE" ]]; then
    log "stage=image event=missing_gemini_api_key"
    return 1
  fi

  return 0
}

# Пре-флайт проба Gemini тем же путём, что и генерация (gemini.sh + та же модель),
# чтобы поймать недоступность ДО запуска 500 заведомо провальных проходов.
# gemini.sh при 429/cap печатает текст ошибки и отдаёт exit 0 (тихий фейл),
# поэтому помимо кода выхода проверяем тело ответа на сигнатуры ошибок API.
# Возврат: 0 = Gemini отвечает, 1 = недоступен (cap / ключ / сеть).
gemini_available() {
  local out
  out="$(printf 'ping\n' | timeout 30 "$GEMINI_SH" -m "${DREAM_GEMINI_MODEL:-flash}" stdin "Ответь одним словом: ok" 2>/dev/null)" || return 1
  [[ -z "${out//[[:space:]]/}" ]] && return 1
  if printf '%s' "$out" | grep -qiE 'spending cap|RESOURCE_EXHAUSTED|exceeded|quota|expired|INVALID|PERMISSION_DENIED|UNAUTHENTICATED|"error"'; then
    return 1
  fi
  return 0
}

top_three_theme() {
  local titles

  titles="$(extract_top_titles "$OUT_MD" | sed -n '1,3p' | tr '\n' '; ' || true)"
  if [[ -z "$titles" ]]; then
    titles="ночной синтез knowledge graph; топ-10 инсайтов; связи между доменами"
  fi

  printf '%s\n' "$titles"
}

best_effort_cover_image() {
  local now max_gemini_with_overrun body_file response_file image_prompt image_data caption

  if ! command -v base64 >/dev/null 2>&1; then
    log "stage=image event=skip_missing_base64"
    return 0
  fi

  max_gemini_with_overrun=$((DREAM_MAX_RUNS + DREAM_OVERRUN_RUNS))
  if ((LAUNCHED + 1 > max_gemini_with_overrun)); then
    log "stage=image event=skip_budget launched=$LAUNCHED max_with_overrun=$max_gemini_with_overrun"
    return 0
  fi

  if ((DEADLINE_EPOCH > 0)); then
    now="$(now_epoch)"
    if ((now >= DEADLINE_EPOCH)); then
      log "stage=image event=skip_deadline"
      return 0
    fi
  fi

  if ! load_gemini_key; then
    return 0
  fi

  body_file="$(mktemp "$DREAM_OUT_DIR/.brain-dream-image-body.XXXXXX")" || return 0
  response_file="$(mktemp "$DREAM_OUT_DIR/.brain-dream-image-response.XXXXXX")" || {
    rm -f "$body_file" 2>/dev/null || true
    return 0
  }

  image_prompt="Абстрактная обложка для ночного синтеза knowledge graph. Темы: $(top_three_theme). Визуальный стиль: тихая ночная карта знаний, тонкие светящиеся связи между узлами, ощущение глубокого анализа, без текста, без логотипов, без интерфейсных элементов."

  jq -n --arg text "$image_prompt" '{contents:[{parts:[{text:$text}]}]}' > "$body_file"

  if ! curl -fs -o "$response_file" -X POST \
    -H "Content-Type: application/json" \
    -H "x-goog-api-key: ${GEMINI_API_KEY_VALUE}" \
    --data @"$body_file" \
    "https://generativelanguage.googleapis.com/v1beta/models/${DREAM_IMAGE_MODEL}:generateContent"; then
    log "stage=image event=generateContent_failed"
    rm -f "$body_file" "$response_file" 2>/dev/null || true
    return 0
  fi

  image_data="$(jq -r '[.candidates[0].content.parts[]? | (.inlineData.data // .inline_data.data // empty)][0] // empty' "$response_file" 2>/dev/null || true)"
  if [[ -z "$image_data" || "$image_data" == "null" ]]; then
    log "stage=image event=no_inline_image"
    rm -f "$body_file" "$response_file" 2>/dev/null || true
    return 0
  fi

  if printf '%s' "$image_data" | base64 -d > "$OUT_PNG" 2>/dev/null; then
    log "stage=image event=png_written path=$OUT_PNG"
    caption="Сон мозга $UTC_DATE UTC"
    send_telegram_photo "$OUT_PNG" "$caption"
  else
    log "stage=image event=base64_decode_failed"
    rm -f "$OUT_PNG" 2>/dev/null || true
  fi

  rm -f "$body_file" "$response_file" 2>/dev/null || true
}

main() {
  local cluster_count node_count count synthesis_text summary_text stage_history synthesis_file

  validate_params
  check_dependencies
  DEADLINE_EPOCH="$(parse_deadline_epoch "$DREAM_DEADLINE_UTC")"

  # Сохраняем базовое значение recency-bias чтобы REM-фаза восстанавливала его
  # после NREM-перезаписи. Если пользователь дал DREAM_RECENT_WEIGHT_PCT=50,
  # REM-фаза вернётся к 50, а не к дефолтному 70.
  _DREAM_RECENT_WEIGHT_PCT_BASE="${DREAM_RECENT_WEIGHT_PCT:-70}"
  export _DREAM_RECENT_WEIGHT_PCT_BASE

  log "stage=start domains=\"$DREAM_DOMAINS\" max_runs=$DREAM_MAX_RUNS deadline=${DREAM_DEADLINE_UTC:-none} concurrency=$DREAM_CONCURRENCY nrem_passes=$DREAM_NREM_PASSES gemini_backend=$DREAM_GEMINI_BACKEND"

  STAGE="collect"
  log "stage=collect event=start"
  collect_nodes
  node_count="$(line_count "$NODES_FILE")"
  cluster_count="$(line_count "$CLUSTERS_FILE")"
  log "stage=collect event=done nodes=$node_count clusters=$cluster_count"

  : > "$CANDIDATES_FILE"
  : > "$USAGE_SINK"
  : > "$SONNET_SINK"
  # Сбрасываем прошлогодний дедупнутый блок: при выключенном дедупе или раннем
  # выходе digest_title_block не должен подхватить заголовки вчерашней ночи.
  : > "$DIGEST_TITLES_FILE"

  # Петля фидбэка: взвесить ротацию линз и кластеров по оценкам из .feedback.jsonl.
  # При отсутствии оценок веса равны → массивы = [0..n-1] → исходный round-robin.
  if [[ "${DREAM_FEEDBACK_BIAS:-1}" == "1" ]] && ((cluster_count > 0)); then
    local lens_wfile dom_wfile ci cline cdom
    local -a cl_domains=()
    lens_wfile="$(mktemp "${DREAM_OUT_DIR}/.fb-lens.XXXXXX")"; register_temp_file "$lens_wfile"
    dom_wfile="$(mktemp "${DREAM_OUT_DIR}/.fb-dom.XXXXXX")"; register_temp_file "$dom_wfile"
    fb_weight_lines lens   > "$lens_wfile" || true
    fb_weight_lines domain > "$dom_wfile"  || true
    read -r -a WEIGHTED_NREM_IDX <<< "$(build_weighted_idx "${#NREM_LENS_KEYS[@]}" "$lens_wfile" "${NREM_LENS_KEYS[@]}")"
    read -r -a WEIGHTED_REM_IDX  <<< "$(build_weighted_idx "${#REM_LENS_KEYS[@]}"  "$lens_wfile" "${REM_LENS_KEYS[@]}")"
    read -r -a WEIGHTED_LENS_IDX <<< "$(build_weighted_idx "${#LENS_KEYS[@]}"      "$lens_wfile" "${LENS_KEYS[@]}")"
    for ((ci = 0; ci < cluster_count; ci++)); do
      cline="$(cluster_line_at "$ci")"; cdom="${cline%%$'\t'*}"; cl_domains[$ci]="${cdom:-?}"
    done
    read -r -a WEIGHTED_CLUSTER_IDX <<< "$(build_weighted_idx "$cluster_count" "$dom_wfile" "${cl_domains[@]}")"
    log "stage=generation event=feedback_bias lens_rot=${#WEIGHTED_REM_IDX[@]} cluster_rot=${#WEIGHTED_CLUSTER_IDX[@]} base_clusters=$cluster_count"
  fi

  STAGE="generation"
  if ((cluster_count > 0)); then
    log "stage=generation event=start"
    # Пре-флайт проба Gemini. Если он недоступен (spend cap / протухший ключ) и
    # включён фолбэк — праймари-цикл Gemini пропускается (gate ниже), весь синтез
    # уходит на Sonnet через подписку Claude Code (фаза 2 принудительно ниже).
    if [[ "$DREAM_SONNET_FALLBACK" == "1" ]] && ! gemini_available; then
      GEMINI_UNAVAILABLE=1
      RUN_ENGINE="sonnet"
      STOP_REASON="gemini_unavailable"
      log "stage=generation event=gemini_unavailable fallback=sonnet"
    fi
    # Cap страхует от бесконечного цикла, если sample_paths постоянно даёт
    # пустоту (skip_empty_sample не инкрементирует LAUNCHED, значит max_runs
    # сам по себе не остановит). По аналогии с sonnet-циклом ниже.
    local iteration_cap=$((DREAM_MAX_RUNS * 3 + 10))
    local _gsat_prev=0 _gsat_since=0
    while [[ "$RUN_ENGINE" == "gemini" ]] && deadline_generation_open && ((ITERATION < iteration_cap)); do
      while ((${#PIDS[@]} >= DREAM_CONCURRENCY)); do
        wait_for_one_job
      done

      if launch_iteration "$ITERATION" "$cluster_count"; then
        ITERATION=$((ITERATION + 1))
      else
        ITERATION=$((ITERATION + 1))
      fi

      if saturation_reached _gsat_prev _gsat_since gemini; then
        STOP_REASON="saturation"
        break
      fi

      # Пейсинг под free-tier лимит (20 запросов/мин у gemini-2.5-flash):
      # пауза между запусками держит нас заметно ниже лимита.
      sleep "${DREAM_SLEEP:-0}"
    done
    if [[ "$RUN_ENGINE" == "gemini" ]] && ((ITERATION >= iteration_cap)) && [[ "$STOP_REASON" == "running" ]]; then
      STOP_REASON="iteration_cap"
      log "stage=generation event=iteration_cap_hit iterations=$ITERATION launched=$LAUNCHED cap=$iteration_cap"
    fi
  else
    STOP_REASON="no_nodes"
    log "stage=generation event=skip_no_nodes"
  fi

  log "stage=generation event=drain_start iterations_launched=$LAUNCHED active=${#PIDS[@]} reason=$STOP_REASON"
  while ((${#PIDS[@]} > 0)); do
    wait_for_one_job
  done
  log "stage=generation event=done iterations_launched=$LAUNCHED runs=$RUNS failed=$FAILS reason=$STOP_REASON"

  GEMINI_LAUNCHED=$LAUNCHED
  GEMINI_RUNS=$RUNS

  # ФАЗА 2 (опц.): Sonnet прогоняет те же проходы, что Gemini — для сравнения
  # расхода и как продолжение, если Gemini рано упёрся в денежный лимит.
  if { [[ "$DREAM_SONNET_COMPARE" == "1" ]] || ((GEMINI_UNAVAILABLE == 1)); } && ((cluster_count > 0)); then
    local sonnet_target=$GEMINI_LAUNCHED siter=0 now
    if [[ -n "$DREAM_SONNET_MAX_RUNS" ]]; then
      # Абсолютный override: и понижает, и поднимает. Полезно, когда Sonnet
      # должен идти глубже Gemini (Gemini ограничен cost limit, Sonnet — нет,
      # он расходует не доллары, а долю подписочной сессии — отдельный
      # предохранитель DREAM_SONNET_SESSION_CAP_PCT).
      sonnet_target=$DREAM_SONNET_MAX_RUNS
    elif ((GEMINI_UNAVAILABLE == 1)); then
      # Фолбэк: Gemini дал 0 проходов, поэтому таргет = свой дефолт, а не 0.
      sonnet_target=$DREAM_SONNET_FALLBACK_RUNS
    fi
    STAGE="sonnet"
    RUN_ENGINE="sonnet"
    STOP_REASON_SONNET="completed"
    log "stage=sonnet event=start target_passes=$sonnet_target session_cap=${DREAM_SONNET_SESSION_CAP_PCT}% session_limit=$DREAM_SONNET_SESSION_LIMIT_CALLS model=$DREAM_SONNET_MODEL concurrency=$DREAM_SONNET_CONCURRENCY"
    # siter-кап страхует от бесконечного цикла, если сэмплы пустые.
    # Чекпоинт насыщения seed-им текущим счётчиком: в фазе сравнения в файле уже
    # лежат Gemini-кандидаты, и мерить надо именно прирост от Sonnet.
    local _ssat_prev _ssat_since=0
    _ssat_prev="$(candidate_count)"
    while ((SONNET_LAUNCHED < sonnet_target && siter < sonnet_target * 2 + 5)); do
      if sonnet_quota_reached; then STOP_REASON_SONNET="session_cap"; break; fi
      if ((DEADLINE_EPOCH > 0)); then
        now="$(now_epoch)"
        if ((now >= DEADLINE_EPOCH - 300)); then STOP_REASON_SONNET="deadline_buffer"; break; fi
      fi
      while ((${#PIDS[@]} >= DREAM_SONNET_CONCURRENCY)); do
        wait_for_one_job
      done
      if launch_iteration "$siter" "$cluster_count"; then
        SONNET_LAUNCHED=$((SONNET_LAUNCHED + 1))
      fi
      siter=$((siter + 1))
      if saturation_reached _ssat_prev _ssat_since sonnet; then
        STOP_REASON_SONNET="saturation"
        break
      fi
      sleep "${DREAM_SONNET_SLEEP:-0}"
    done
    while ((${#PIDS[@]} > 0)); do
      wait_for_one_job
    done
    RUN_ENGINE="gemini"
    log "stage=sonnet event=done launched=$SONNET_LAUNCHED reason=$STOP_REASON_SONNET session_share=$(sonnet_session_share_pct)% ref_api_cost=\$$(spent_usd_sonnet)"
  fi

  STAGE="dedup"
  dedup_against_registry

  count="$(candidate_count)"
  if ((count == 0)); then
    # Отличаем "движок упал" (все вызовы зафейлились — Gemini cap И/ИЛИ Sonnet
    # недоступен) от честной "свежих инсайтов нет" ночи. RUNS = суммарно успешных
    # проходов (gemini+sonnet), FAILS = суммарно зафейленных. RUNS==0 при FAILS>0
    # значит ни один движок не ответил → это поломка, а не пустой сон.
    if ((RUNS == 0 && FAILS > 0)); then
      log "stage=synthesis event=no_candidates cause=engine_failure failed=$FAILS gemini_launched=$GEMINI_LAUNCHED sonnet_launched=$SONNET_LAUNCHED"
      stage_history="collect,generation,engine-failure"
      write_markdown_output "Сон не дал кандидатов: движок генерации недоступен — все $FAILS вызовов зафейлились. Проверь Gemini spend cap (ai.studio/spend) и доступность Sonnet-подписки." "$count" "$stage_history"
      send_telegram_message "⚠️ brain-dream: движок генерации НЕДОСТУПЕН — все $FAILS вызовов зафейлились, сон пуст. Вероятно Gemini уперся в spend cap, а Sonnet-фолбэк тоже не ответил."$'\n'"Файл: $OUT_MD"
      exit 3
    fi
    log "stage=synthesis event=no_candidates cause=no_new_insights"
    stage_history="collect,generation,no-candidates-output"
    write_markdown_output "Сон не дал кандидатов." "$count" "$stage_history"
    send_telegram_message "сон не дал кандидатов"$'\n'"Файл: $OUT_MD"
    exit 0
  fi

  STAGE="synthesis"
  log "stage=synthesis event=start candidates=$count"
  synthesis_file="$(mktemp "$DREAM_OUT_DIR/.brain-dream-synthesis.XXXXXX")"
  register_temp_file "$synthesis_file"
  run_synthesis > "$synthesis_file"
  synthesis_text="$(cat "$synthesis_file")"
  log "stage=synthesis event=done"

  STAGE="output"
  stage_history="collect,generation,synthesis,output"
  write_markdown_output "$synthesis_text" "$count" "$stage_history"
  log "stage=output event=markdown_written path=$OUT_MD"

  # Phase 2: записать новые candidates в insight registry — теперь будущие сны
  # будут считать их повторами (с инкрементом confidence).
  register_new_candidates

  # Раз в неделю компактим registry (выбрасываем записи вне окна).
  if (( $(date -u +%u) == 7 )); then
    registry_compact
    log "stage=registry event=compacted_weekly"
  fi

  # Записать результат нодой в домен dreams (опц.).
  if [[ "$DREAM_WRITE_NODE" == "1" ]]; then
    write_dream_node "$synthesis_text"
  fi

  # Дедуп ленты против недавних ночей (Gemini Flash) ПЕРЕД публикацией в TG.
  # Гасит near-duplicate инсайты, уже показанные за последние дни. OUT_MD/Notion
  # остаются полным записями — фильтруется только показываемый в TG топ-10.
  if [[ "$DREAM_DIGEST_DEDUP" == "1" ]]; then
    STAGE="digest-dedup"
    run_digest_dedup
  fi

  # Опубликовать ноду в Notion и получить ссылку на полный текст для дайджеста.
  local notion_url=""
  if [[ "$DREAM_WRITE_NODE" == "1" ]]; then
    notion_url="$(publish_dream_and_get_url || true)"
  fi

  if [[ "$DREAM_TG_MODE" == "single" ]]; then
    # Одно сообщение: обложка (cover-only) + топ-10 в подписи. Без картинок
    # по инсайтам.
    local cover_url caption
    cover_url="$(DREAM_IMAGES_MODE=cover-only bash "$ORCHESTRATOR_DIR/dream-images.sh" "$OUT_MD" 2>/dev/null | tail -n 1)"
    caption="$(telegram_caption_single)"
    if [[ -n "$cover_url" && "$cover_url" == http* ]]; then
      send_telegram_photo_url "$cover_url" "$caption"
    else
      send_telegram_message "$caption"
    fi
    send_feedback_buttons "$notion_url"
  else
    summary_text="$(telegram_summary_text)"
    send_telegram_message "$summary_text"
    (
      set +e
      bash "$ORCHESTRATOR_DIR/dream-images.sh" "$OUT_MD"
    ) || true
  fi

  log "stage=done gemini_launched=$GEMINI_LAUNCHED gemini_spent=\$$(spent_usd) sonnet_launched=$SONNET_LAUNCHED sonnet_session_share=$(sonnet_session_share_pct)% candidates=$count output=$OUT_MD"
}

main "$@"
