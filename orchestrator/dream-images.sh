#!/usr/bin/env bash
# Генерирует картинки для уже созданного markdown-отчета о снах.
# Параметр: путь к dream-YYYY-MM-DD.md.
# Работает best-effort: ошибки генерации, Telegram или записи логируются, но не валят весь запуск.

set -uo pipefail

PATH="$HOME/.npm-global/bin:$PATH"

STAGE="hf-images"
LOG_FILE="$HOME/life/state/logs/brain-dream.log"
HF_BIN="higgsfield"

DREAM_HF_MODEL="${DREAM_HF_MODEL:-seedream_v4_5}"
DREAM_HF_PER_INSIGHT="${DREAM_HF_PER_INSIGHT:-10}"
DREAM_HF_SLEEP="${DREAM_HF_SLEEP:-2}"
# full = обложка + картинки по инсайтам + отправка в TG (старое поведение).
# cover-only = сгенерить ТОЛЬКО обложку, в TG ничего не слать, напечатать её URL
# последней строкой stdout (вызывающий сам отправит одно сообщение).
DREAM_IMAGES_MODE="${DREAM_IMAGES_MODE:-full}"

usage() {
  printf 'Usage: %s <path-to-dream-md>\n' "$(basename "$0")"
}

mask_secret() {
  local text="${1:-}"
  local token="${DIGEST_BOT_TOKEN:-}"
  if [ -n "$token" ]; then
    printf '%s' "$text" | sed "s|$token|***MASKED***|g"
  else
    printf '%s' "$text"
  fi
}

log_msg() {
  local level="${1:-INFO}"
  shift || true
  local msg="${*:-}"
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown-time')"
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  printf '%s stage=%s level=%s %s\n' "$ts" "$STAGE" "$level" "$(mask_secret "$msg")" >>"$LOG_FILE" 2>/dev/null || true
}

debug_tg_response() {
  local label="${1:-telegram}"
  local body="${2:-}"
  log_msg "DEBUG" "$label response=$(mask_secret "$body")"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

sanitize_limit() {
  local value="$1"
  local default="$2"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
  else
    printf '%s' "$default"
  fi
}

truncate_caption() {
  local text="${1:-}"
  printf '%s' "$text" | cut -c 1-200
}

extract_date() {
  local file="$1"
  local base
  base="$(basename "$file")"
  if [[ "$base" =~ dream-([0-9]{4}-[0-9]{2}-[0-9]{2})\.md$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    date -u '+%Y-%m-%d' 2>/dev/null || printf 'unknown-date'
  fi
}

generate_image() {
  local prompt="$1"
  local output=""
  local url=""

  if ! have_cmd "$HF_BIN"; then
    log_msg "ERROR" "higgsfield binary not found in PATH"
    printf ''
    return 0
  fi

  log_msg "INFO" "generating image prompt=$(truncate_caption "$prompt")"
  if output="$("$HF_BIN" generate create "$DREAM_HF_MODEL" --prompt "$prompt" --wait 2>&1)"; then
    url="$(printf '%s\n' "$output" | grep -oE 'https://[^[:space:]]+' | tail -1 || true)"
    if [ -z "$url" ]; then
      log_msg "WARN" "higgsfield returned no image URL"
    fi
  else
    log_msg "WARN" "higgsfield command failed output=$(truncate_caption "$output")"
    url=""
  fi

  printf '%s' "$url"
  return 0
}

telegram_post() {
  local method="$1"
  shift || true
  local response_file
  local curl_code=0
  local response=""
  local ok=""

  response_file="$(mktemp 2>/dev/null || printf '/tmp/dream-images-tg-response.%s' "$$")"
  : >"$response_file" 2>/dev/null || true

  if [ -z "${DIGEST_BOT_TOKEN:-}" ] || [ -z "${DIGEST_ADMIN_CHAT_ID:-}" ]; then
    log_msg "WARN" "Telegram env is missing; skipping $method"
    rm -f "$response_file" 2>/dev/null || true
    printf '0'
    return 0
  fi

  if curl -sS -o "$response_file" \
    "https://api.telegram.org/bot${DIGEST_BOT_TOKEN}/${method}" "$@" >/dev/null 2>&1; then
    curl_code=0
  else
    curl_code=$?
  fi

  response="$(cat "$response_file" 2>/dev/null || true)"
  rm -f "$response_file" 2>/dev/null || true
  debug_tg_response "$method" "$response"

  if [ "$curl_code" -ne 0 ]; then
    log_msg "WARN" "Telegram $method curl failed code=$curl_code"
    printf '0'
    return 0
  fi

  ok="$(printf '%s' "$response" | jq -r '.ok // false' 2>/dev/null || printf 'false')"
  if [ "$ok" != "true" ]; then
    log_msg "WARN" "Telegram $method returned ok=false"
    printf '0'
    return 0
  fi

  printf '1'
  return 0
}

send_photo() {
  local url="$1"
  local caption="$2"

  if [ -z "$url" ]; then
    return 0
  fi

  telegram_post "sendPhoto" \
    --data-urlencode "chat_id=${DIGEST_ADMIN_CHAT_ID:-}" \
    --data-urlencode "photo=${url}" \
    --data-urlencode "caption=${caption}" >/dev/null || true
}

send_media_group_batch() {
  local batch_file="$1"
  local media_json=""
  local sent="0"

  media_json="$(jq -s -c 'map(select(.url != "") | {type:"photo", media:.url, caption:.caption})' "$batch_file" 2>/dev/null || printf '[]')"
  if [ "$media_json" = "[]" ] || [ -z "$media_json" ]; then
    return 0
  fi

  sent="$(telegram_post "sendMediaGroup" \
    --data-urlencode "chat_id=${DIGEST_ADMIN_CHAT_ID:-}" \
    --data-urlencode "media=${media_json}" || printf '0')"

  if [ "$sent" != "1" ]; then
    log_msg "WARN" "sendMediaGroup failed; falling back to sendPhoto for batch"
    while IFS= read -r item; do
      local url=""
      local caption=""
      url="$(printf '%s' "$item" | jq -r '.url // ""' 2>/dev/null || printf '')"
      caption="$(printf '%s' "$item" | jq -r '.caption // ""' 2>/dev/null || printf '')"
      if [ -n "$url" ]; then
        send_photo "$url" "$caption"
      fi
    done <"$batch_file"
  fi
}

send_insight_images() {
  local pairs_file="$1"
  local batch_file=""
  local count=0

  batch_file="$(mktemp 2>/dev/null || printf '/tmp/dream-images-batch.%s' "$$")"
  : >"$batch_file" 2>/dev/null || true

  while IFS= read -r item; do
    local number=""
    local title=""
    local url=""
    number="$(printf '%s' "$item" | jq -r '.number // ""' 2>/dev/null || printf '')"
    title="$(printf '%s' "$item" | jq -r '.title // ""' 2>/dev/null || printf '')"
    url="$(printf '%s' "$item" | jq -r '.url // ""' 2>/dev/null || printf '')"
    if [ -z "$url" ]; then
      continue
    fi
    jq -nc --arg url "$url" --arg caption "$(truncate_caption "${number}. ${title}")" \
      '{url:$url, caption:$caption}' >>"$batch_file" 2>/dev/null || true
    count=$((count + 1))
    if [ "$count" -ge 10 ]; then
      send_media_group_batch "$batch_file"
      : >"$batch_file" 2>/dev/null || true
      count=0
    fi
  done <"$pairs_file"

  if [ "$count" -gt 0 ]; then
    send_media_group_batch "$batch_file"
  fi

  rm -f "$batch_file" 2>/dev/null || true
}

append_images_section() {
  local md_file="$1"
  local cover_url="$2"
  local pairs_file="$3"
  local section_file=""
  local tmp_file=""

  section_file="$(mktemp 2>/dev/null || printf '/tmp/dream-images-section.%s' "$$")"
  : >"$section_file" 2>/dev/null || true

  {
    printf '\n## Картинки\n'
    if [ -n "$cover_url" ]; then
      printf '\n![cover](%s)\n' "$cover_url"
    fi
    while IFS= read -r item; do
      local number=""
      local title=""
      local url=""
      number="$(printf '%s' "$item" | jq -r '.number // ""' 2>/dev/null || printf '')"
      title="$(printf '%s' "$item" | jq -r '.title // ""' 2>/dev/null || printf '')"
      url="$(printf '%s' "$item" | jq -r '.url // ""' 2>/dev/null || printf '')"
      if [ -n "$url" ]; then
        printf '\n%s. %s\n![](%s)\n' "$number" "$title" "$url"
      fi
    done <"$pairs_file"
  } >>"$section_file" 2>/dev/null || true

  tmp_file="$(mktemp "${md_file}.tmp.XXXXXX" 2>/dev/null || printf '%s.tmp.%s' "$md_file" "$$")"
  if { cat "$md_file" "$section_file" >"$tmp_file"; } 2>/dev/null && mv "$tmp_file" "$md_file" 2>/dev/null; then
    log_msg "INFO" "appended images section atomically file=$md_file"
  else
    log_msg "WARN" "atomic append failed; falling back to direct append file=$md_file"
    rm -f "$tmp_file" 2>/dev/null || true
    if cat "$section_file" >>"$md_file" 2>/dev/null; then
      log_msg "INFO" "appended images section directly file=$md_file"
    else
      log_msg "ERROR" "failed to append images section file=$md_file"
    fi
  fi

  rm -f "$section_file" 2>/dev/null || true
}

main() {
  if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
  fi

  local md_file="${1:-}"
  if [ -z "$md_file" ]; then
    log_msg "WARN" "no markdown file argument supplied"
    exit 0
  fi
  if [ ! -f "$md_file" ]; then
    log_msg "WARN" "markdown file does not exist file=$md_file"
    exit 0
  fi

  if ! have_cmd jq; then
    log_msg "ERROR" "jq not found in PATH"
    exit 0
  fi
  if ! have_cmd curl; then
    log_msg "ERROR" "curl not found in PATH"
    exit 0
  fi
  if ! have_cmd "$HF_BIN"; then
    log_msg "ERROR" "higgsfield binary not found in PATH"
    exit 0
  fi

  DREAM_HF_PER_INSIGHT="$(sanitize_limit "$DREAM_HF_PER_INSIGHT" "10")"
  DREAM_HF_SLEEP="$(sanitize_limit "$DREAM_HF_SLEEP" "2")"

  local dream_date=""
  local headings_file=""
  local pairs_file=""
  local cover_url=""
  local cover_prompt=""
  local themes=""
  local env_file="$HOME/.config/digest-bot/env"

  dream_date="$(extract_date "$md_file")"
  headings_file="$(mktemp 2>/dev/null || printf '/tmp/dream-images-headings.%s' "$$")"
  pairs_file="$(mktemp 2>/dev/null || printf '/tmp/dream-images-pairs.%s' "$$")"
  : >"$headings_file" 2>/dev/null || true
  : >"$pairs_file" 2>/dev/null || true

  if awk '
    /^##[[:space:]]+[0-9]+\.[[:space:]]+/ {
      line=$0
      sub(/^##[[:space:]]+[0-9]+\.[[:space:]]+/, "", line)
      print line
    }
  ' "$md_file" | head -n "$DREAM_HF_PER_INSIGHT" >"$headings_file"; then
    log_msg "INFO" "extracted insight headings file=$md_file"
  else
    log_msg "WARN" "failed to extract insight headings file=$md_file"
  fi

  themes="$(head -n 3 "$headings_file" | paste -sd ';' - 2>/dev/null || true)"
  if [ -n "$themes" ]; then
    cover_prompt="Abstract minimal conceptual cover, soft neural glow, deep indigo; themes: ${themes}"
  else
    cover_prompt="Abstract minimal conceptual cover, soft neural glow, deep indigo"
  fi
  cover_url="$(generate_image "$cover_prompt")"

  # cover-only: только обложка, без картинок по инсайтам и без отправки в TG.
  # Печатаем URL обложки — вызывающий отправит одно сообщение сам.
  if [ "$DREAM_IMAGES_MODE" = "cover-only" ]; then
    append_images_section "$md_file" "$cover_url" "$pairs_file"
    rm -f "$headings_file" "$pairs_file" 2>/dev/null || true
    log_msg "INFO" "cover-only mode: returning cover URL file=$md_file"
    printf '%s\n' "$cover_url"
    exit 0
  fi

  local idx=0
  local title=""
  while IFS= read -r title; do
    idx=$((idx + 1))
    local url=""
    url="$(generate_image "Abstract minimal conceptual editorial illustration, no text: ${title}")"
    jq -nc --argjson number "$idx" --arg title "$title" --arg url "$url" \
      '{number:$number, title:$title, url:$url}' >>"$pairs_file" 2>/dev/null || true
    sleep "$DREAM_HF_SLEEP" 2>/dev/null || true
  done <"$headings_file"

  if [ -f "$env_file" ]; then
    set +u
    # shellcheck disable=SC1090
    . "$env_file" >/dev/null 2>&1
    local env_status=$?
    set -u
    if [ "$env_status" -ne 0 ]; then
      log_msg "WARN" "failed to source Telegram env file=$env_file"
    fi
  else
    log_msg "WARN" "Telegram env file not found file=$env_file"
  fi

  if [ -n "${DIGEST_BOT_TOKEN:-}" ] && [ -n "${DIGEST_ADMIN_CHAT_ID:-}" ]; then
    if [ -n "$cover_url" ]; then
      send_photo "$cover_url" "🌙 Сон мозга ${dream_date} — обложка"
    else
      log_msg "WARN" "cover URL is empty; skipping Telegram cover"
    fi
    send_insight_images "$pairs_file"
  else
    log_msg "WARN" "Telegram credentials missing; skipping Telegram send"
  fi

  append_images_section "$md_file" "$cover_url" "$pairs_file"

  rm -f "$headings_file" "$pairs_file" 2>/dev/null || true
  log_msg "INFO" "completed image workflow file=$md_file"
  exit 0
}

main "$@"
