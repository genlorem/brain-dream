#!/usr/bin/env bash
set -euo pipefail

# Каталог orchestrator-а (соседние gemini.sh и dream-images.sh ищем рядом,
# независимо от того, откуда запущен скрипт).
ORCHESTRATOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  exec env BRAIN_DREAM_FLOCKED=1 flock -n -E 0 /tmp/brain-dream.lock "$0" "$@"
fi

DREAM_DOMAINS="${DREAM_DOMAINS:-travelmart personal}"
DREAM_MAX_RUNS="${DREAM_MAX_RUNS:-500}"
DREAM_DEADLINE_UTC="${DREAM_DEADLINE_UTC:-}"
DREAM_OVERRUN_RUNS="${DREAM_OVERRUN_RUNS:-25}"
DREAM_OVERRUN_MIN="${DREAM_OVERRUN_MIN:-20}"
DREAM_CONCURRENCY="${DREAM_CONCURRENCY:-3}"
DREAM_OUT_DIR="${DREAM_OUT_DIR:-$HOME/brain/dreams}"
DREAM_IMAGE_MODEL="${DREAM_IMAGE_MODEL:-gemini-2.5-flash-image}"

# Денежный потолок на Gemini-генерацию за ночь (в долларах). Считаем фактический
# расход по токенам из ответов API и останавливаем генерацию при достижении
# лимита. 0 = без лимита (старое поведение, только max_runs). Цены — за 1M
# токенов; дефолты под gemini-3.5-flash (вход $1.50 / выход $9.00 на 05.2026).
# Синтез Claude и картинки Higgsfield идут с других балансов — в лимит не входят.
DREAM_COST_LIMIT_USD="${DREAM_COST_LIMIT_USD:-0.50}"
DREAM_PRICE_IN_PER_M="${DREAM_PRICE_IN_PER_M:-1.50}"
DREAM_PRICE_OUT_PER_M="${DREAM_PRICE_OUT_PER_M:-9.00}"

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

# Запись результата сна нодой в домен dreams (~/brain/dreams/nodes). 1 = писать.
# Домен dreams изолирован: сон его не читает (см. domain_root).
DREAM_WRITE_NODE="${DREAM_WRITE_NODE:-0}"
DREAM_NODE_ROOT="${DREAM_NODE_ROOT:-$HOME/brain/dreams}"

# Режим Telegram-вывода: single = одно фото-сообщение (обложка + топ-10 в
# подписи), без картинок по инсайтам; legacy = старое поведение (текст +
# обложка + media-group инсайтов).
DREAM_TG_MODE="${DREAM_TG_MODE:-legacy}"

# Recency-bias при сэмплинге нод в каждом проходе: % выборки из «свежей»
# половины (по mtime). 70% = свежие имеют приоритет, но не монополию. 50% =
# чисто uniform. Биологический аналог — hippocampal replay свежих эпизодов.
DREAM_RECENT_WEIGHT_PCT="${DREAM_RECENT_WEIGHT_PCT:-70}"

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
GEMINI_LAUNCHED=0
GEMINI_RUNS=0
SONNET_LAUNCHED=0
STOP_REASON_SONNET="none"

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

  for name in DREAM_MAX_RUNS DREAM_OVERRUN_RUNS DREAM_OVERRUN_MIN DREAM_CONCURRENCY; do
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
{\"title\":\"\",\"insight\":\"\",\"why\":\"\",\"novelty\":\"obvious|non-obvious\",\"source_ids\":[],\"domain\":\"\",\"lens\":\"\"}

Правила:
- опирайся только на source_ids из контекста;
- source_ids должны быть id нод, которые реально использованы;
- domain поставь \"$domain_label\" или более точный домен из контекста;
- lens поставь \"$lens_key\";
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
        | .model = "sonnet"
        | select((.title|type)=="string" and (.title|length)>0)
        | select((.insight|type)=="string" and (.insight|length)>0)
        | select((.why|type)=="string" and (.why|length)>0)
      ' 2>/dev/null)"; then
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
    sorted_with_mtime+=("$mtime"\$'\t'"$path")
  done
  mapfile -t unique < <(printf '%s\n' "${sorted_with_mtime[@]}" | sort -rn -t \$'\t' -k1 | cut -f2-)

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
{\"title\":\"\",\"insight\":\"\",\"why\":\"\",\"novelty\":\"obvious|non-obvious\",\"source_ids\":[],\"domain\":\"\",\"lens\":\"\"}

Правила:
- опирайся только на source_ids из контекста;
- source_ids должны быть id нод, которые реально использованы;
- domain поставь \"$domain_label\" или более точный домен из контекста;
- lens поставь \"$lens_key\";
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
        | select((.title | type) == "string" and (.title | length) > 0)
        | select((.insight | type) == "string" and (.insight | length) > 0)
        | select((.why | type) == "string" and (.why | length) > 0)
      ' 2>/dev/null)"; then
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
  local -a selected selected_a selected_b

  lens_index=$((iteration % ${#LENS_KEYS[@]}))
  lens_key="${LENS_KEYS[$lens_index]}"
  lens_text="${LENS_PROMPTS[$lens_index]}"
  desired=$((3 + (iteration % 6)))
  mode="single"

  if ((cluster_count >= 2 && iteration % 5 == 4)); then
    mode="cross"
    desired=$((4 + (iteration % 5)))
    first_index=$((iteration % cluster_count))
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
    first_index=$((iteration % cluster_count))
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

  log "stage=${RUN_ENGINE:-gemini} iterations_launched=$LAUNCHED runs=$RUNS active=${#PIDS[@]} mode=$mode lens=$lens_key target=\"$domain_label\""
}

candidate_count() {
  if [[ ! -s "$CANDIDATES_FILE" ]]; then
    printf '0\n'
  else
    wc -l < "$CANDIDATES_FILE" | tr -d '[:space:]'
  fi
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

  {
    cat <<'PROMPT'
Ты синтезатор. Из этих кандидатов-инсайтов собери ТОП-10 по (важность × новизна × применимость), дедупни близкие.
Для каждого: заголовок, суть, почему важно, предлагаемое действие, ссылки на source_ids, метка obvious/non-obvious.
В конце — Mermaid flowchart связей топ-10.
Ответ — Markdown на русском.

Кандидаты JSONL:
PROMPT
    cat "$CANDIDATES_FILE"
  } > "$PROMPT_FILE"

  if synthesis_text="$(claude -p "$(cat "$PROMPT_FILE")" 2>/dev/null)"; then
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
write_dream_node() {
  local synthesis_text="$1"
  local node_dir="$DREAM_NODE_ROOT/nodes"
  local node_file="$node_dir/dream-$UTC_DATE.md"
  local title src_ids

  if ! mkdir -p "$node_dir" 2>/dev/null; then
    log "stage=node event=mkdir_failed dir=$node_dir"
    return 0
  fi

  title="$(extract_top_titles "$OUT_MD" | sed -n '1p' | sed -E 's/^[0-9]+\.[[:space:]]*//')"
  [[ -z "$title" ]] && title="ночной синтез"
  # Экранировать апостроф для YAML single-quoted строки (удвоением). Байтовую
  # обрезку не делаем — она ломает многобайтные UTF-8 символы.
  title="${title//\'/\'\'}"
  src_ids="$(jq -s -r '[.[].source_ids[]?] | unique | .[0:20] | join(", ")' "$CANDIDATES_FILE" 2>/dev/null || true)"

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
    printf -- 'links: []\n'
    printf -- 'tags: [dream, synthesis]\n'
    printf -- '---\n\n'
    printf '%s\n\n' "$synthesis_text"
    printf -- '---\nИсточники (source_ids топ-кандидатов): %s\n' "${src_ids:-—}"
  } > "$node_file"
  log "stage=node event=written file=$node_file"

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
      sub(/^#+[[:space:]]*/, "", s)
      sub(/^[0-9]+[.)][[:space:]]*/, "", s)
      sub(/^[0-9]+[[:space:]]*[-–—][[:space:]]*/, "", s)
      gsub(/\*\*/, "", s)
      return s
    }
    /^#{1,4}[[:space:]]*[0-9]+[.)[:space:]-]/ {
      title = clean($0)
      if (length(title) > 0) {
        count += 1
        print count ". " title
      }
    }
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

  titles="$(extract_top_titles "$OUT_MD" || true)"
  if [[ -z "$titles" ]]; then
    titles="$(fallback_titles_from_candidates || true)"
  fi
  if [[ -z "$titles" ]]; then
    titles="топ-10 не извлечен; см. файл"
  fi

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

  titles="$(extract_top_titles "$OUT_MD" || true)"
  [[ -z "$titles" ]] && titles="$(fallback_titles_from_candidates || true)"
  [[ -z "$titles" ]] && titles="топ-10 не извлечён; см. ноду/файл"

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

  log "stage=start domains=\"$DREAM_DOMAINS\" max_runs=$DREAM_MAX_RUNS deadline=${DREAM_DEADLINE_UTC:-none} concurrency=$DREAM_CONCURRENCY"

  STAGE="collect"
  log "stage=collect event=start"
  collect_nodes
  node_count="$(line_count "$NODES_FILE")"
  cluster_count="$(line_count "$CLUSTERS_FILE")"
  log "stage=collect event=done nodes=$node_count clusters=$cluster_count"

  : > "$CANDIDATES_FILE"
  : > "$USAGE_SINK"
  : > "$SONNET_SINK"

  STAGE="generation"
  if ((cluster_count > 0)); then
    log "stage=generation event=start"
    while deadline_generation_open; do
      while ((${#PIDS[@]} >= DREAM_CONCURRENCY)); do
        wait_for_one_job
      done

      if launch_iteration "$ITERATION" "$cluster_count"; then
        ITERATION=$((ITERATION + 1))
      else
        ITERATION=$((ITERATION + 1))
      fi

      # Пейсинг под free-tier лимит (20 запросов/мин у gemini-2.5-flash):
      # пауза между запусками держит нас заметно ниже лимита.
      sleep "${DREAM_SLEEP:-0}"
    done
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
  if [[ "$DREAM_SONNET_COMPARE" == "1" ]] && ((cluster_count > 0)); then
    local sonnet_target=$GEMINI_LAUNCHED siter=0 now
    if [[ -n "$DREAM_SONNET_MAX_RUNS" ]] && ((DREAM_SONNET_MAX_RUNS < sonnet_target)); then
      sonnet_target=$DREAM_SONNET_MAX_RUNS
    fi
    STAGE="sonnet"
    RUN_ENGINE="sonnet"
    STOP_REASON_SONNET="completed"
    log "stage=sonnet event=start target_passes=$sonnet_target session_cap=${DREAM_SONNET_SESSION_CAP_PCT}% session_limit=$DREAM_SONNET_SESSION_LIMIT_CALLS model=$DREAM_SONNET_MODEL concurrency=$DREAM_SONNET_CONCURRENCY"
    # siter-кап страхует от бесконечного цикла, если сэмплы пустые.
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
      sleep "${DREAM_SONNET_SLEEP:-0}"
    done
    while ((${#PIDS[@]} > 0)); do
      wait_for_one_job
    done
    RUN_ENGINE="gemini"
    log "stage=sonnet event=done launched=$SONNET_LAUNCHED reason=$STOP_REASON_SONNET session_share=$(sonnet_session_share_pct)% ref_api_cost=\$$(spent_usd_sonnet)"
  fi

  count="$(candidate_count)"
  if ((count == 0)); then
    log "stage=synthesis event=no_candidates"
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

  # Записать результат нодой в домен dreams (опц.).
  if [[ "$DREAM_WRITE_NODE" == "1" ]]; then
    write_dream_node "$synthesis_text"
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
