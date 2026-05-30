#!/usr/bin/env bash
set -euo pipefail

# Этот скрипт - тонкая CLI-обертка над Google Gemini API для Claude Code и
# обычной работы из терминала. Он нужен, чтобы быстро отдавать Gemini большие
# куски текста: один файл, stdin или срез всего репозитория. Тело запроса
# собирается через jq и отправляется через stdin/temp-файлы, чтобы не упираться
# в ARG_MAX и не светить содержимое в списке процессов.
#
# Примеры:
#   gemini.sh ask "Кратко объясни код" src/app.ts package.json
#   gemini.sh stdin "Суммируй лог" < huge.log
#   gemini.sh repo -m pro --max-bytes 5000000 "Объясни архитектуру" .
#   gemini.sh -m flash ask "Что делает этот файл?" README.md

SCRIPT_NAME="$(basename "$0")"
CONFIG_FILE="${HOME}/.config/gemini/config.env"

MODEL="flash"
MAX_BYTES=3000000
MODEL_SET_BY_FLAG=0

TMP_FILES=()
cleanup() {
  local f
  set +u
  for f in "${TMP_FILES[@]}"; do
    [[ -n "$f" && -e "$f" ]] && rm -f "$f"
  done
  set -u
  return 0
}
trap cleanup EXIT

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} [flags] ask "<prompt>" [file ...]
  ${SCRIPT_NAME} [flags] repo "<prompt>" <dir>
  ${SCRIPT_NAME} [flags] stdin "<prompt>"

Flags:
  -m <model>          Model alias or explicit model id. Aliases: flash, pro.
                     Default: \$GEMINI_MODEL if set, otherwise flash.
  --max-bytes <n>     Max collected repo bytes before truncation. Default: 3000000.
  -h, --help          Show this help.

Examples:
  ${SCRIPT_NAME} ask "Summarize this" README.md
  ${SCRIPT_NAME} stdin "Explain this log" < app.log
  ${SCRIPT_NAME} repo "Explain the architecture" .
  ${SCRIPT_NAME} -m pro --max-bytes 5000000 repo "Find risks" ./src
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Error: required dependency not found: $1"
}

make_tmp() {
  local t
  t="$(mktemp "${TMPDIR:-/tmp}/gemini.XXXXXX")"
  TMP_FILES+=("$t")
  printf '%s\n' "$t"
}

validate_uint() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "Error: ${name} must be a non-negative integer"
}

append_file_with_header() {
  local out="$1"
  local header="$2"
  local file_path="$3"

  [[ -f "$file_path" ]] || die "Error: file not found: $file_path"
  [[ -r "$file_path" ]] || die "Error: file is not readable: $file_path"

  {
    printf '\n===== FILE: %s =====\n' "$header"
    cat "$file_path"
    printf '\n'
  } >>"$out"
}

contains_null_byte() {
  local file_path="$1"
  local status

  set +o pipefail
  LC_ALL=C od -An -tx1 -v "$file_path" | grep -qi ' 00'
  status=$?
  set -o pipefail
  return "$status"
}

is_repo_text_file() {
  local file_path="$1"
  local base ext

  [[ -f "$file_path" && -r "$file_path" ]] || return 1
  contains_null_byte "$file_path" && return 1

  base="$(basename "$file_path")"
  case "$base" in
    Dockerfile|Containerfile|Makefile|Gemfile|Rakefile|Procfile|go.mod|go.sum|Cargo.toml|Cargo.lock|package.json|package-lock.json|pnpm-lock.yaml|yarn.lock|tsconfig.json|jsconfig.json|README|LICENSE|NOTICE|CHANGELOG)
      return 0
      ;;
  esac

  ext="${base##*.}"
  [[ "$base" == "$ext" ]] && return 1

  case "$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')" in
    ts|tsx|mts|cts|js|jsx|mjs|cjs|py|pyi|go|rs|java|kt|kts|scala|c|h|cc|cpp|cxx|hpp|cs|rb|php|sh|bash|zsh|fish|sql|md|mdx|txt|json|jsonc|yaml|yml|toml|vue|svelte|css|scss|sass|less|html|htm|xml|svg|graphql|gql|proto|gradle|ini|cfg|conf|env|example|properties|lock|csv|tsv|rst|adoc|dockerfile|tf|tfvars|hcl|lua|pl|pm|r|ex|exs|erl|hrl|clj|cljs|elm|dart|swift)
      return 0
      ;;
  esac

  return 1
}

relative_path() {
  local root="$1"
  local file_path="$2"
  local rel

  rel="${file_path#"$root"/}"
  printf '%s\n' "$rel"
}

append_repo_contents() {
  local out="$1"
  local dir="$2"
  local max_bytes="$3"
  local used=0
  local truncated=0
  local file_path rel file_size

  [[ -d "$dir" ]] || die "Error: directory not found: $dir"
  [[ -r "$dir" ]] || die "Error: directory is not readable: $dir"

  dir="$(cd "$dir" && pwd -P)"

  while IFS= read -r -d '' file_path; do
    is_repo_text_file "$file_path" || continue

    file_size="$(wc -c <"$file_path" | tr -d '[:space:]')"
    validate_uint "file size" "$file_size"

    if (( used + file_size > max_bytes )); then
      truncated=1
      break
    fi

    rel="$(relative_path "$dir" "$file_path")"
    append_file_with_header "$out" "$rel" "$file_path"
    used=$((used + file_size))
  done < <(
    find "$dir" \
      \( -type d \( -name .git -o -name node_modules -o -name dist -o -name build -o -name vendor -o -name .next -o -name coverage -o -name __pycache__ -o -name .cache -o -name .svn \) -prune \) \
      -o -type f -print0 | sort -z
  )

  if (( truncated )); then
    printf '\n[TRUNCATED: достигнут лимит --max-bytes, часть файлов пропущена]\n' >>"$out"
  fi
}

resolve_model() {
  local raw="$1"
  case "$raw" in
    flash) printf '%s\n' "gemini-2.5-flash" ;;
    pro) printf '%s\n' "gemini-2.5-pro" ;;
    '') die "Error: model must not be empty" ;;
    *) printf '%s\n' "$raw" ;;
  esac
}

parse_args() {
  POSITIONALS=()
  SUBCOMMAND=""

  while (($#)); do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -m)
        shift
        (($#)) || die "Error: -m requires a value"
        MODEL="$1"
        MODEL_SET_BY_FLAG=1
        ;;
      --max-bytes)
        shift
        (($#)) || die "Error: --max-bytes requires a value"
        validate_uint "--max-bytes" "$1"
        MAX_BYTES="$1"
        ;;
      --max-bytes=*)
        MAX_BYTES="${1#*=}"
        validate_uint "--max-bytes" "$MAX_BYTES"
        ;;
      --)
        shift
        while (($#)); do
          if [[ -z "$SUBCOMMAND" && ( "$1" == "ask" || "$1" == "repo" || "$1" == "stdin" ) ]]; then
            SUBCOMMAND="$1"
          else
            POSITIONALS+=("$1")
          fi
          shift
        done
        break
        ;;
      ask|repo|stdin)
        if [[ -z "$SUBCOMMAND" ]]; then
          SUBCOMMAND="$1"
        else
          POSITIONALS+=("$1")
        fi
        ;;
      -*)
        die "Error: unknown flag: $1"
        ;;
      *)
        POSITIONALS+=("$1")
        ;;
    esac
    shift
  done
}

require_api_key() {
  if [[ -z "${GEMINI_API_KEY:-}" ]]; then
    die "Error: GEMINI_API_KEY is missing. Set it in the environment or in ${CONFIG_FILE}."
  fi
}

prepare_request_text() {
  local combined_file="$1"
  local prompt="$2"

  printf '%s' "$prompt" >"$combined_file"
}

# Запись реального расхода токенов из ответа API в sink-файл (если задан
# GEMINI_USAGE_SINK). Нужно, чтобы вызывающий (brain-dream.sh) мог считать
# фактическую стоимость и держать денежный лимит. Берём числа из usageMetadata —
# это то, за что реально выставит счёт Google, а не оценка по размеру входа.
record_usage() {
  local model="$1"
  local resp="$2"
  local sink line
  sink="${GEMINI_USAGE_SINK:-}"
  [[ -z "$sink" ]] && return 0

  line="$(jq -c -n --arg ts "$(date -u +%FT%TZ)" --arg model "$model" \
    --argjson u "$(jq -c '.usageMetadata // {}' "$resp" 2>/dev/null || printf '{}')" '
      {ts:$ts, model:$model,
       prompt_tokens:($u.promptTokenCount // 0),
       candidates_tokens:($u.candidatesTokenCount // 0),
       total_tokens:($u.totalTokenCount // 0)}' 2>/dev/null)" || return 0
  [[ -z "$line" ]] && return 0

  # Под flock, т.к. brain-dream запускает несколько gemini.sh параллельно и все
  # пишут в один sink. На маке flock может отсутствовать — тогда дозапись одной
  # короткой строки атомарна сама по себе (< PIPE_BUF).
  if command -v flock >/dev/null 2>&1; then
    {
      flock 9
      printf '%s\n' "$line" >>"$sink"
    } 9>"${sink}.lock"
  else
    printf '%s\n' "$line" >>"$sink"
  fi
}

call_gemini() {
  local model="$1"
  local combined_file="$2"
  local body_file response_file curl_config url

  body_file="$(make_tmp)"
  response_file="$(make_tmp)"
  curl_config="$(make_tmp)"
  url="https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent"

  jq -n --rawfile text "$combined_file" '{"contents":[{"parts":[{"text":$text}]}]}' >"$body_file"

  {
    printf 'url = "%s"\n' "$url"
    printf 'request = "POST"\n'
    printf 'header = "Content-Type: application/json"\n'
    printf 'header = "x-goog-api-key: %s"\n' "$GEMINI_API_KEY"
    printf 'data-binary = "@%s"\n' "$body_file"
    printf 'silent\n'
    printf 'show-error\n'
  } >"$curl_config"

  if ! curl --config "$curl_config" >"$response_file"; then
    if jq -e '.error.message? // empty' "$response_file" >/dev/null 2>&1; then
      jq -r '.error.message' "$response_file" >&2
    elif [[ -s "$response_file" ]]; then
      cat "$response_file" >&2
    else
      printf '%s\n' "Error: Gemini API request failed" >&2
    fi
    return 1
  fi

  if jq -e '.error?' "$response_file" >/dev/null; then
    jq -r '.error.message // "Gemini API returned an error"' "$response_file" >&2
    return 1
  fi

  if jq -e '(.candidates | type == "array") and (.candidates | length > 0) and (.candidates[0].content.parts | type == "array") and (.candidates[0].content.parts | length > 0)' "$response_file" >/dev/null; then
    record_usage "$model" "$response_file"
    jq -r '.candidates[0].content.parts[].text // empty' "$response_file"
    return 0
  fi

  printf '%s\n' "Error: Gemini API returned no candidate text." >&2
  if jq -e '.promptFeedback? // empty' "$response_file" >/dev/null; then
    jq -r '.promptFeedback' "$response_file" >&2
  fi
  if jq -e '.candidates[0].finishReason? // empty' "$response_file" >/dev/null; then
    jq -r '.candidates[0].finishReason' "$response_file" >&2
  fi
  return 1
}

main() {
  local combined_file model_id prompt dir

  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
  fi

  need_cmd curl
  need_cmd jq

  if (($# == 0)); then
    usage
    exit 0
  fi

  if [[ -n "${GEMINI_MODEL:-}" && "$MODEL_SET_BY_FLAG" -eq 0 ]]; then
    MODEL="$GEMINI_MODEL"
  fi

  parse_args "$@"

  if [[ -n "${GEMINI_MODEL:-}" && "$MODEL_SET_BY_FLAG" -eq 0 ]]; then
    MODEL="$GEMINI_MODEL"
  fi

  [[ -n "$SUBCOMMAND" ]] || die "Error: missing subcommand. Use ask, repo, or stdin."
  require_api_key

  combined_file="$(make_tmp)"

  case "$SUBCOMMAND" in
    ask)
      ((${#POSITIONALS[@]} >= 1)) || die "Error: ask requires a prompt"
      prompt="${POSITIONALS[0]}"
      prepare_request_text "$combined_file" "$prompt"
      if ((${#POSITIONALS[@]} > 1)); then
        local i
        for ((i = 1; i < ${#POSITIONALS[@]}; i++)); do
          append_file_with_header "$combined_file" "${POSITIONALS[$i]}" "${POSITIONALS[$i]}"
        done
      fi
      ;;
    repo)
      ((${#POSITIONALS[@]} == 2)) || die "Error: repo requires exactly: <prompt> <dir>"
      prompt="${POSITIONALS[0]}"
      dir="${POSITIONALS[1]}"
      prepare_request_text "$combined_file" "$prompt"
      append_repo_contents "$combined_file" "$dir" "$MAX_BYTES"
      ;;
    stdin)
      ((${#POSITIONALS[@]} == 1)) || die "Error: stdin requires exactly: <prompt>"
      prompt="${POSITIONALS[0]}"
      prepare_request_text "$combined_file" "$prompt"
      printf '\n' >>"$combined_file"
      cat >>"$combined_file"
      ;;
    *)
      die "Error: unknown subcommand: $SUBCOMMAND"
      ;;
  esac

  model_id="$(resolve_model "$MODEL")"

  # Лог использования для вочдога: время, подкоманда, модель, размер входа.
  _usage_log="${GEMINI_USAGE_LOG:-$HOME/life/state/logs/gemini-usage.jsonl}"
  if [[ -d "$(dirname "$_usage_log")" ]]; then
    _in_bytes=$(wc -c <"$combined_file" 2>/dev/null | tr -d ' ')
    printf '{"ts":"%s","cmd":"%s","model":"%s","in_bytes":%s}\n' \
      "$(date -u +%FT%TZ)" "$SUBCOMMAND" "$model_id" "${_in_bytes:-0}" >>"$_usage_log" 2>/dev/null || true
  fi

  call_gemini "$model_id" "$combined_file"
}

main "$@"
