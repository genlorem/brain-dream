#!/usr/bin/env bash
set -euo pipefail

# session-observer — agent (plugin contract v1).
#
# Дистиллирует находки из файлов сессий Claude Code (~/.claude/projects/**/*.jsonl)
# в домен dreams. Детерминированная (cron) замена ручной природы /learn.
#
# Контракт (ARCHITECTURE.md):
#   Вход: stdin JSON { task:"observe-sessions", config:{...}, env:{...} }
#   Выход: stdout один JSON-объект { version, agent_name, status, result, side_effects, telemetry, errors }
#   stderr: JSON-per-line логи
#   Exit: 0=ok/skipped, 1=internal error, 2=guard refused, 124=timeout
#
# SPEC: docs/04-session-observer.md
# Рубрика: rubrics/session-finding-v1.yaml

AGENT_NAME="session-observer"
AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${BRAIN_DREAM_REPO:-$(cd "$AGENT_DIR/.." && pwd)}"
DREAM_NODE_ROOT="${DREAM_NODE_ROOT:-$HOME/brain/dreams}"
BRAIN_ROOT="${BRAIN_ROOT:-$HOME/brain}"
INSIGHT_REGISTRY="${INSIGHT_REGISTRY:-$DREAM_NODE_ROOT/.insight-hashes.jsonl}"
GEMINI_SH="$REPO/orchestrator/gemini.sh"

# Финализированная сессия: mtime старше N минут (чтобы не трогать активную).
SESSION_IDLE_MIN="${SESSION_IDLE_MIN:-30}"
# Не трогать древний бэклог: только сессии не старше N дней (дедуп-окно реестра = 14д).
SESSION_MAX_AGE_DAYS="${SESSION_OBSERVER_MAX_AGE_DAYS:-30}"
# Per-run предохранитель: не более N сессий с LLM-вызовом за прогон (cost-guard сейчас
# no-op, т.к. gemini.sh не возвращает $). Остаток догоняется следующими прогонами.
SESSION_MAX_PER_RUN="${SESSION_OBSERVER_MAX_PER_RUN:-25}"
# Пропускать сессии короче N сообщений (тривиальные, без находок).
SESSION_MIN_MSGS="${SESSION_OBSERVER_MIN_MSGS:-8}"

# Guards: дешёвый агент, но cron каждые 6ч → rate-limit 5/6ч.
GUARD_COST_DAILY_USD="${GUARD_COST_DAILY_USD:-0.20}"
GUARD_RATE_LIMIT_CALLS="${GUARD_RATE_LIMIT_CALLS:-5}"
GUARD_RATE_LIMIT_WINDOW_MIN="${GUARD_RATE_LIMIT_WINDOW_MIN:-360}"

# shellcheck disable=SC1091
source "$REPO/lib/guards.sh"
# shellcheck disable=SC1091
source "$REPO/lib/content-hash.sh"
# shellcheck disable=SC1091
source "$REPO/lib/insight-hashes.sh"

# ── Stdin ─────────────────────────────────────────────────────────────────────
INPUT="{}"
if [ ! -t 0 ]; then INPUT=$(cat); fi

DRY_RUN=$(printf '%s' "$INPUT" | jq -r '.config.dry_run // false' 2>/dev/null || printf 'false')
MODEL_BUDGET_USD=$(printf '%s' "$INPUT" | jq -r '.config.model_budget_usd // 0.10' 2>/dev/null || printf '0.10')
INVOKED_BY=$(printf '%s' "$INPUT" | jq -r '.invoked_by // "manual"' 2>/dev/null || printf 'manual')
INPUT_DEPTH=$(printf '%s' "$INPUT" | jq -r '.input.depth // 0' 2>/dev/null || printf '0')
export INVOKED_BY INPUT_DEPTH

# Env overrides из stdin
ENV_BRAIN_ROOT=$(printf '%s' "$INPUT" | jq -r '.env.BRAIN_ROOT // empty' 2>/dev/null || true)
ENV_DREAM_NODE_ROOT=$(printf '%s' "$INPUT" | jq -r '.env.DREAM_NODE_ROOT // empty' 2>/dev/null || true)
ENV_BRAIN_DREAM_REPO=$(printf '%s' "$INPUT" | jq -r '.env.BRAIN_DREAM_REPO // empty' 2>/dev/null || true)
[ -n "$ENV_BRAIN_ROOT" ] && BRAIN_ROOT="$ENV_BRAIN_ROOT"
[ -n "$ENV_DREAM_NODE_ROOT" ] && DREAM_NODE_ROOT="$ENV_DREAM_NODE_ROOT"
[ -n "$ENV_BRAIN_DREAM_REPO" ] && REPO="$ENV_BRAIN_DREAM_REPO"

CURSOR_FILE="$DREAM_NODE_ROOT/.session-observer-cursor.jsonl"
LEARN_LEDGER="$DREAM_NODE_ROOT/.learn-ledger.jsonl"

START_TIME=$(date +%s)

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
  local level="$1"; shift
  printf '{"ts":"%s","level":"%s","agent":"%s","msg":"%s"}\n' \
    "$(date -u +%FT%TZ)" "$level" "$AGENT_NAME" "$*" >&2
}

emit_result() {
  local status="$1" result="$2" side_effects="$3" telemetry="$4" errors="$5"
  local duration
  duration=$(($(date +%s) - START_TIME))
  printf '{"version":"1","agent_name":"%s","status":"%s","duration_s":%s,"result":%s,"side_effects":%s,"telemetry":%s,"errors":%s}\n' \
    "$AGENT_NAME" "$status" "$duration" "$result" "$side_effects" "$telemetry" "$errors"
}

log INFO "start dry_run=$DRY_RUN budget=$MODEL_BUDGET_USD invoked_by=$INVOKED_BY"

# ── Dependency checks ─────────────────────────────────────────────────────────
if [ ! -x "$GEMINI_SH" ]; then
  log ERROR "missing_dependency path=$GEMINI_SH"
  emit_result "failed" '{"reason":"missing_gemini_sh"}' "[]" '{"llm_calls":[]}' '["missing_gemini_sh"]'
  exit 1
fi

# ── Guards ─────────────────────────────────────────────────────────────────────
if ! guards_pass_all; then
  emit_result "skipped" '{"reason":"guard_blocked"}' "[]" '{"llm_calls":[],"guards_triggered":["see_stderr"]}' "[]"
  exit 2
fi

# ── Find finalized sessions ───────────────────────────────────────────────────
# Финализированные = mtime старше SESSION_IDLE_MIN минут.
sessions_dir="$HOME/.claude/projects"
sessions_file=$(mktemp /tmp/so-sessions.XXXXXX)
trap 'rm -f "$sessions_file" 2>/dev/null' EXIT

if [ ! -d "$sessions_dir" ]; then
  log WARN "no_sessions_dir path=$sessions_dir"
  emit_result "skipped" '{"reason":"no_sessions_dir","sessions_found":0}' "[]" '{"llm_calls":[]}' "[]"
  exit 0
fi

# Финализированные (mtime >= SESSION_IDLE_MIN) и не старше SESSION_MAX_AGE_DAYS.
# Сортировка newest-first, чтобы per-run лимит брал самые свежие/релевантные.
max_age_min=$(( SESSION_MAX_AGE_DAYS * 1440 ))
tmp_scan=$(mktemp /tmp/so-scan.XXXXXX)
while IFS= read -r -d '' f; do
  mtime_epoch=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  age_min=$(( (now_epoch - mtime_epoch) / 60 ))
  if (( age_min >= SESSION_IDLE_MIN && age_min <= max_age_min )); then
    printf '%s\t%s\n' "$mtime_epoch" "$f" >> "$tmp_scan"
  fi
done < <(find "$sessions_dir" -maxdepth 3 -name "*.jsonl" -type f -print0 2>/dev/null)
sort -rn "$tmp_scan" 2>/dev/null | cut -f2- > "$sessions_file"
rm -f "$tmp_scan"

total_sessions=$(wc -l < "$sessions_file" | tr -d ' ')
log INFO "sessions_found=$total_sessions idle_min=$SESSION_IDLE_MIN"

if [ "$total_sessions" -eq 0 ]; then
  emit_result "skipped" '{"reason":"no_finalized_sessions","sessions_found":0}' "[]" '{"llm_calls":[]}' "[]"
  exit 0
fi

# ── Load cursor ────────────────────────────────────────────────────────────────
# cursor: {session_id, path, processed_through_msg, bytes, last_seen_mtime, status}
load_cursor_for_session() {
  local session_path="$1"
  [[ -f "$CURSOR_FILE" ]] || { printf '0'; return 0; }
  local idx
  idx=$(jq -r --arg p "$session_path" \
    'select(.path == $p) | .processed_through_msg // 0' \
    "$CURSOR_FILE" 2>/dev/null | tail -1)
  printf '%s' "${idx:-0}"
}

# ── Load learn-ledger for session ─────────────────────────────────────────────
# ledger: {session_id, path, processed_through_msg, node_ids, content_hashes, captured_at}
load_ledger_for_session() {
  local session_path="$1"
  [[ -f "$LEARN_LEDGER" ]] || { printf '0'; return 0; }
  local idx
  idx=$(jq -r --arg p "$session_path" \
    'select(.path == $p) | .processed_through_msg // 0' \
    "$LEARN_LEDGER" 2>/dev/null | tail -1)
  printf '%s' "${idx:-0}"
}

# ── Inline secret scrub ───────────────────────────────────────────────────────
# TODO: когда появится lib/scrub.sh — переключиться на него (lib/scrub.sh упомянут в
# ARCHITECTURE.md, но файл ещё не создан, зависимость не подключаем).
#
# Минимальный инлайновый гард: вырезаем строки, похожие на токены.
scrub_secrets() {
  local text="$1"
  # Bearer/JWT/high-entropy base64/sk-*/xox*/OAuth токены
  printf '%s' "$text" \
    | sed \
      -e 's/Bearer [A-Za-z0-9+/=._-]\{20,\}/Bearer [REDACTED]/g' \
      -e 's/eyJ[A-Za-z0-9+/=._-]\{40,\}/[JWT_REDACTED]/g' \
      -e 's/sk-[A-Za-z0-9]\{20,\}/sk-[REDACTED]/g' \
      -e 's/xox[bpoas]-[A-Za-z0-9-]\{10,\}/xox-[REDACTED]/g' \
      -e 's/OAuth [A-Za-z0-9+/=._-]\{20,\}/OAuth [REDACTED]/g'
}

# ── Parse session messages ────────────────────────────────────────────────────
# Читаем jsonl начиная с индекса $start_idx, возвращаем:
#   - transcript текст
#   - последний индекс
# Вывод через глобальные переменные (bash не поддерживает многозначный return).
TRANSCRIPT=""
LAST_MSG_IDX=0

parse_session_chunk() {
  local session_path="$1"
  local start_idx="$2"
  local line_num=0
  local transcript_parts=()
  local last_idx=0
  local tool_dump_limit=2000

  TRANSCRIPT=""
  LAST_MSG_IDX="$start_idx"

  while IFS= read -r line; do
    [ -z "$line" ] && { line_num=$((line_num + 1)); continue; }

    if (( line_num < start_idx )); then
      line_num=$((line_num + 1))
      continue
    fi

    last_idx="$line_num"

    # Извлечь role и content
    local role content_raw content_text
    role=$(printf '%s' "$line" | jq -r '.message.role // empty' 2>/dev/null || true)
    content_raw=$(printf '%s' "$line" | jq -c '.message.content // empty' 2>/dev/null || true)

    [ -z "$role" ] && { line_num=$((line_num + 1)); continue; }

    # content может быть строкой или массивом блоков
    local content_type
    content_type=$(printf '%s' "$content_raw" | jq -r 'type' 2>/dev/null || printf 'null')

    if [ "$content_type" = "string" ]; then
      content_text=$(printf '%s' "$content_raw" | jq -r '.' 2>/dev/null || true)
    elif [ "$content_type" = "array" ]; then
      # Собрать текстовые части: type="text" -> .text; tool_result -> text part
      content_text=$(printf '%s' "$content_raw" | jq -r '
        .[] |
        if .type == "text" then .text
        elif .type == "tool_result" then
          (.content // []) |
          if type == "array" then [.[] | select(.type=="text") | .text] | join(" ")
          elif type == "string" then .
          else ""
          end
        else ""
        end' 2>/dev/null | tr '\n' ' ' || true)
    else
      content_text=""
    fi

    [ -z "$content_text" ] && { line_num=$((line_num + 1)); continue; }

    # Усечь большие дампы
    if [ "${#content_text}" -gt "$tool_dump_limit" ]; then
      content_text="${content_text:0:$tool_dump_limit}...[truncated]"
    fi

    transcript_parts+=("[${role}] ${content_text}")
    line_num=$((line_num + 1))
  done < "$session_path"

  LAST_MSG_IDX="$last_idx"

  if [ "${#transcript_parts[@]}" -gt 0 ]; then
    TRANSCRIPT=$(printf '%s\n' "${transcript_parts[@]}")
  fi
}

# ── Build distillation prompt ─────────────────────────────────────────────────
build_distillation_prompt() {
  local session_id="$1"
  local transcript="$2"
  local msg_start="$3"
  local msg_end="$4"

  cat <<PROMPT
Ты — агент-наблюдатель за сессиями Claude Code. Проанализируй транскрипт сессии
и извлеки находки, которые стоит сохранить в базе знаний.

Рубрика (session-finding-v1): сохраняй только то, что удивило, изменило архитектуру
или сэкономит время в будущем:
- **Surprises** — поведение, отличавшееся от ожидания (баг тулы, устаревшая дока, ограничение API)
- **Workarounds** — неочевидные обходы проблем
- **Non-obvious commands/queries** — shell-трюки, SQL, curl, собранные методом тыка
- **Traps** — ошибки с неочевидным корнем (escaping, race conditions, caching)
- **Decisions** — развилки, где выбор был неочевиден (с trade-off)
- **Связи** — новые зависимости между проектами/сервисами/сущностями

НЕ сохранять: рутинные команды, секреты/токены, общие принципы из документации.

Верни только JSONL без markdown-обёрток. Нужно 0-5 инсайтов, каждый на отдельной строке:
{"type":"lesson|decision|procedure|note","title":"...","body":"...","tags":["..."],"confidence":0.3-1.0}

Правила:
- type: lesson (surprise/trap/workaround), decision (trade-off выбор), procedure (runbook/команда), note (связь/статус)
- title и body — по-русски, конкретно, без общих советов
- confidence: 0.3-0.5=гипотеза, 0.6-0.8=вероятно, 0.9-1.0=уверен
- Если находок нет — верни пустой ответ (ни одной строки)

## Транскрипт сессии ${session_id} (сообщения ${msg_start}-${msg_end})

${transcript}
PROMPT
}

# ── Main processing loop ──────────────────────────────────────────────────────
total_llm_calls=0
total_input_tokens=0
total_output_tokens=0
total_cost_usd=0
total_nodes_written=0
git_commits=()
sessions_processed=0
sessions_skipped=0

# Temp files for accumulating results
new_cursor_file=$(mktemp /tmp/so-cursor-new.XXXXXX)
trap 'rm -f "$sessions_file" "$new_cursor_file" 2>/dev/null' EXIT

# Copy existing cursor entries (for sessions we won't touch)
if [ -f "$CURSOR_FILE" ]; then
  cp "$CURSOR_FILE" "$new_cursor_file"
else
  > "$new_cursor_file"
fi

while IFS= read -r session_path; do
  [ -z "$session_path" ] && continue
  [ -f "$session_path" ] || continue

  # Per-run предохранитель: остановиться после SESSION_MAX_PER_RUN обработанных сессий.
  if (( sessions_processed >= SESSION_MAX_PER_RUN )); then
    log INFO "max_per_run_reached limit=$SESSION_MAX_PER_RUN — остаток в следующий прогон"
    break
  fi

  # Derive session_id from path
  session_id=$(basename "$(dirname "$session_path")")/$(basename "$session_path" .jsonl)
  session_id="${session_id//\//-}"

  # Get mtime
  mtime_epoch=$(stat -c %Y "$session_path" 2>/dev/null || stat -f %m "$session_path" 2>/dev/null || echo 0)
  mtime_iso=$(date -u -d "@$mtime_epoch" +%FT%TZ 2>/dev/null || date -u -r "$mtime_epoch" +%FT%TZ 2>/dev/null || echo "unknown")

  # Load cursor and ledger boundaries
  cursor_idx=$(load_cursor_for_session "$session_path")
  ledger_idx=$(load_ledger_for_session "$session_path")

  # Level-1 dedup: start from max of cursor and ledger
  start_idx=$(( cursor_idx > ledger_idx ? cursor_idx : ledger_idx ))

  # Count total messages in file
  total_msgs=$(wc -l < "$session_path" | tr -d ' ')

  log INFO "session session_id=$session_id total_msgs=$total_msgs start_idx=$start_idx"

  if (( total_msgs <= start_idx )); then
    log INFO "session_up_to_date session_id=$session_id"
    sessions_skipped=$((sessions_skipped + 1))
    continue
  fi

  # Пропустить мелкие/тривиальные сессии (бэклог огромен, ~237 сессий/день;
  # короткие не несут находок и не должны жечь LLM-бюджет).
  if (( total_msgs - start_idx < SESSION_MIN_MSGS )); then
    log INFO "session_too_small session_id=$session_id new=$((total_msgs - start_idx)) min=$SESSION_MIN_MSGS"
    sessions_skipped=$((sessions_skipped + 1))
    continue
  fi

  # Parse new chunk
  parse_session_chunk "$session_path" "$start_idx"

  if [ -z "$TRANSCRIPT" ]; then
    log INFO "empty_chunk session_id=$session_id"
    sessions_skipped=$((sessions_skipped + 1))
    # Update cursor even for empty (no new text) chunks
    jq -c --arg p "$session_path" 'select(.path != $p)' "$new_cursor_file" > "${new_cursor_file}.tmp" \
      && mv "${new_cursor_file}.tmp" "$new_cursor_file" 2>/dev/null || true
    jq -nc \
      --arg sid "$session_id" --arg p "$session_path" \
      --argjson idx "$LAST_MSG_IDX" --argjson bytes "$(wc -c < "$session_path" | tr -d ' ')" \
      --arg mtime "$mtime_iso" \
      '{session_id:$sid, path:$p, processed_through_msg:$idx, bytes:$bytes, last_seen_mtime:$mtime, status:"done"}' \
      >> "$new_cursor_file"
    continue
  fi

  sessions_processed=$((sessions_processed + 1))
  new_count=$((LAST_MSG_IDX - start_idx + 1))
  log INFO "chunk_parsed session_id=$session_id new_msgs=$new_count"

  # Dry-run: skip LLM call
  if [ "$DRY_RUN" = "true" ]; then
    log INFO "dry_run_skip_llm session_id=$session_id"
    jq -c --arg p "$session_path" 'select(.path != $p)' "$new_cursor_file" > "${new_cursor_file}.tmp" \
      && mv "${new_cursor_file}.tmp" "$new_cursor_file" 2>/dev/null || true
    jq -nc \
      --arg sid "$session_id" --arg p "$session_path" \
      --argjson idx "$LAST_MSG_IDX" --argjson bytes "$(wc -c < "$session_path" | tr -d ' ')" \
      --arg mtime "$mtime_iso" \
      '{session_id:$sid, path:$p, processed_through_msg:$idx, bytes:$bytes, last_seen_mtime:$mtime, status:"partial"}' \
      >> "$new_cursor_file"
    continue
  fi

  # Cost guard before LLM call
  if ! guard_cost_cb; then
    log WARN "cost_guard_blocked session_id=$session_id"
    break
  fi

  # Build prompt and call Gemini
  prompt_file=$(mktemp /tmp/so-prompt.XXXXXX)
  trap 'rm -f "$sessions_file" "$new_cursor_file" "$prompt_file" 2>/dev/null' EXIT

  build_distillation_prompt "$session_id" "$TRANSCRIPT" "$start_idx" "$LAST_MSG_IDX" > "$prompt_file"

  log INFO "calling_gemini session_id=$session_id"
  gemini_response=""
  if ! gemini_response=$("$GEMINI_SH" -m "${DREAM_GEMINI_MODEL:-flash}" stdin \
    "$(cat "$prompt_file")" < /dev/null 2>/dev/null); then
    log WARN "gemini_failed session_id=$session_id"
    # Continue with next session; don't update cursor (will retry next run)
    rm -f "$prompt_file"
    continue
  fi
  rm -f "$prompt_file"

  total_llm_calls=$((total_llm_calls + 1))
  # Note: gemini.sh (call_gemini) returns only text; token counts go to GEMINI_USAGE_SINK.
  # We record a placeholder cost entry to satisfy guard_cost_cb (actual cost unknown without sink).
  guard_record_cost "0"

  # Parse candidates (JSONL, strip markdown fences)
  candidates_file=$(mktemp /tmp/so-candidates.XXXXXX)
  trap 'rm -f "$sessions_file" "$new_cursor_file" "$candidates_file" 2>/dev/null' EXIT

  printf '%s\n' "$gemini_response" \
    | sed -E '/^[[:space:]]*```/d' \
    | jq -c -R 'fromjson? // empty | select(type == "object") | select(.title and .body)' \
    2>/dev/null > "$candidates_file" || true

  cand_count=$(wc -l < "$candidates_file" | tr -d ' ')
  log INFO "candidates_parsed session_id=$session_id count=$cand_count"

  session_nodes_written=0

  # Process each candidate
  while IFS= read -r candidate; do
    [ -z "$candidate" ] && continue

    c_type=$(printf '%s' "$candidate" | jq -r '.type // "lesson"')
    c_title=$(printf '%s' "$candidate" | jq -r '.title // ""')
    c_body=$(printf '%s' "$candidate" | jq -r '.body // ""')
    c_tags=$(printf '%s' "$candidate" | jq -c '.tags // []')
    c_conf=$(printf '%s' "$candidate" | jq -r '.confidence // 0.6')

    [ -z "$c_title" ] && continue
    [ -z "$c_body" ] && continue

    # Validate type
    case "$c_type" in
      lesson|decision|procedure|note) ;;
      *) c_type="lesson" ;;
    esac

    # Validate confidence range [0.3, 1.0]
    c_conf=$(python3 -c "v=float('$c_conf'); print(max(0.3,min(1.0,v)))" 2>/dev/null || printf '0.6')

    # Inline secret scrub
    c_title=$(scrub_secrets "$c_title")
    c_body=$(scrub_secrets "$c_body")

    # Level-2 dedup: content-hash
    c_hash=$(content_hash_insight "$c_title" "$c_body")

    if registry_has_hash "$c_hash"; then
      log INFO "dedup_hit hash=$c_hash title=$(printf '%s' "$c_title" | head -c 60)"
      registry_bump_hit "$c_hash"
      continue
    fi

    # Append to registry
    registry_append "$c_hash" "$c_title" "session" "dreams" "$c_conf" ""

    # Write node .md in DREAM_NODE_ROOT
    # Phase 2 hook: promotion to source-of-truth + TG-gate NOT implemented here.
    # When ready: check confidence >= 0.85 && hits >= 2, then promote via dream-promoter
    # and send TG notification through tg-feedback-collector. See SPEC §8.

    observed_at=$(date -u +%FT%TZ)
    node_date=$(date -u +%F)
    node_slug=$(printf '%s' "$c_title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-\+/-/g; s/^-//; s/-$//' | cut -c1-40)
    # Писать в nodes/ — единственный tracked путь (.gitignore dreams = allowlist
    # на nodes/**) и место, которое читают brain-dream.sh и Brain-индекс.
    # Префикс finding- отличает от dream-*.md.
    node_filename="finding-${node_date}_${session_id:0:12}_${node_slug}_${c_hash:0:8}.md"
    node_dir="$DREAM_NODE_ROOT/nodes"
    node_file="$node_dir/$node_filename"

    mkdir -p "$node_dir"

    # Escape quotes for YAML single-quoted scalars
    c_title_esc="${c_title//\'/\'\'}"
    c_body_esc="${c_body//\'/\'\'}"

    {
      printf -- '---\n'
      printf -- 'id: finding:%s\n' "$c_hash"
      printf -- 'type: %s\n' "$c_type"
      printf -- "title: '%s'\n" "$c_title_esc"
      printf -- "observed_at: '%s'\n" "$observed_at"
      printf -- "confidence: %s\n" "$c_conf"
      printf -- "source: session\n"
      printf -- "source_system: claude-code\n"
      printf -- "agent: session-observer\n"
      printf -- "rubric: session-finding-v1\n"
      printf -- "provenance:\n"
      printf -- "  session_id: '%s'\n" "$session_id"
      printf -- "  msg_range: [%s, %s]\n" "$start_idx" "$LAST_MSG_IDX"
      printf -- "  observed_at: '%s'\n" "$observed_at"
      printf -- "  model: '%s'\n" "${DREAM_GEMINI_MODEL:-flash}"
      printf -- "  agent: session-observer\n"
      printf -- "  rubric: session-finding-v1\n"
      printf -- "tags: %s\n" "$c_tags"
      printf -- "content_hash: %s\n" "$c_hash"
      printf -- '---\n\n'
      printf '## %s\n\n' "$c_title_esc"
      printf '%s\n' "$c_body_esc"
    } > "$node_file"

    log INFO "node_written file=$node_file hash=$c_hash"
    session_nodes_written=$((session_nodes_written + 1))
    total_nodes_written=$((total_nodes_written + 1))

    # Phase 2 hook: semantic dedup via brain_semantic_search (requires MCP access from agent).
    # When ready: call brain_semantic_search(insight), if cosine >= DEDUP_SIM_THRESHOLD (0.88)
    # to existing node → skip/merge instead of writing. See SPEC §5.2.2.

  done < "$candidates_file"
  rm -f "$candidates_file"

  # Git commit for this session's nodes
  git_sha=""
  if [ "$session_nodes_written" -gt 0 ]; then
    if git -C "$DREAM_NODE_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git -C "$DREAM_NODE_ROOT" add "$node_dir/" 2>/dev/null || true
      if git -C "$DREAM_NODE_ROOT" -c user.name='session-observer' \
           -c user.email='session-observer@local' \
           commit -q -m "session-observer: $session_nodes_written findings from $session_id ($node_date)" \
           2>/dev/null; then
        git_sha=$(git -C "$DREAM_NODE_ROOT" rev-parse --short HEAD 2>/dev/null || true)
        git_commits+=("{\"type\":\"git_commit\",\"sha\":\"$git_sha\",\"repo\":\"dreams\",\"session_id\":\"$session_id\"}")
        log INFO "committed sha=$git_sha nodes=$session_nodes_written"
      fi
    fi
  fi

  # Update cursor for this session
  jq -c --arg p "$session_path" 'select(.path != $p)' "$new_cursor_file" > "${new_cursor_file}.tmp" \
    && mv "${new_cursor_file}.tmp" "$new_cursor_file" 2>/dev/null || true
  jq -nc \
    --arg sid "$session_id" --arg p "$session_path" \
    --argjson idx "$LAST_MSG_IDX" --argjson bytes "$(wc -c < "$session_path" | tr -d ' ')" \
    --arg mtime "$mtime_iso" \
    '{session_id:$sid, path:$p, processed_through_msg:$idx, bytes:$bytes, last_seen_mtime:$mtime, status:"done"}' \
    >> "$new_cursor_file"

done < "$sessions_file"

# ── Adaptive skip: if nothing was processed ───────────────────────────────────
if [ "$sessions_processed" -eq 0 ] && [ "$DRY_RUN" != "true" ]; then
  log INFO "all_sessions_up_to_date skipped=$sessions_skipped"
  emit_result "skipped" \
    "{\"reason\":\"no_new_messages\",\"sessions_found\":$total_sessions,\"sessions_skipped\":$sessions_skipped}" \
    "[]" \
    '{"llm_calls":[],"guards_triggered":[]}' \
    "[]"
  exit 0
fi

# ── Commit updated cursor ─────────────────────────────────────────────────────
# Dry-run не должен менять стейт: ни курсор, ни реестр. Иначе реальный прогон
# пропустит уже «сдвинутые» сообщения и потеряет находки.
if [ "$DRY_RUN" != "true" ]; then
  mkdir -p "$(dirname "$CURSOR_FILE")"
  mv "$new_cursor_file" "$CURSOR_FILE"

  # Compact insight registry (housekeeping)
  registry_compact 2>/dev/null || true
fi

# ── Build output ──────────────────────────────────────────────────────────────
# side_effects array
side_effects_json="["
first=1
for commit_entry in "${git_commits[@]:-}"; do
  [ -z "$commit_entry" ] && continue
  [ "$first" -eq 1 ] && first=0 || side_effects_json+=","
  side_effects_json+="$commit_entry"
done
side_effects_json+="]"

# llm_calls telemetry
# call_gemini returns text only; token/cost data goes to GEMINI_USAGE_SINK.
# We report call count; actual token counts available in GEMINI_USAGE_SINK if configured.
llm_calls_json="["
if [ "$total_llm_calls" -gt 0 ]; then
  llm_calls_json+="{\"model\":\"${DREAM_GEMINI_MODEL:-flash}\",\"calls\":$total_llm_calls,\"cost_usd\":0,\"note\":\"token_counts_in_GEMINI_USAGE_SINK\"}"
fi
llm_calls_json+="]"

final_status="ok"
[ "$DRY_RUN" = "true" ] && final_status="skipped"

emit_result "$final_status" \
  "{\"sessions_found\":$total_sessions,\"sessions_processed\":$sessions_processed,\"sessions_skipped\":$sessions_skipped,\"nodes_written\":$total_nodes_written}" \
  "$side_effects_json" \
  "{\"llm_calls\":$llm_calls_json,\"guards_triggered\":[]}" \
  "[]"
