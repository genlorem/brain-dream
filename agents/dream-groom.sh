#!/usr/bin/env bash
set -uo pipefail

# dream-groom — agent (plugin contract v1).
# Dry-run безопасен по умолчанию; только config.dry_run=false включает --apply.

AGENT_NAME="dream-groom"
AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$AGENT_DIR/.." && pwd)"
START_TIME=$(date +%s)

INPUT="{}"
if [ ! -t 0 ]; then
  INPUT=$(cat)
fi
[ -z "${INPUT//[[:space:]]/}" ] && INPUT="{}"

if ! printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  printf '{"version":"1","agent_name":"%s","status":"failed","duration_s":%s,"result":{},"side_effects":[],"telemetry":{"llm_calls":[]},"errors":["invalid_input_json"]}\n' \
    "$AGENT_NAME" "$(($(date +%s)-START_TIME))"
  exit 1
fi

for name in BRAIN_ENGINE DREAM_NODE_ROOT BRAIN_MCP_URL; do
  value=$(printf '%s' "$INPUT" | jq -r --arg name "$name" '.env[$name] // empty')
  if [ -n "$value" ]; then
    export "$name=$value"
  fi
done

DRY_RUN=$(printf '%s' "$INPUT" | jq -r \
  'if .config.dry_run == false then "false" else "true" end')
PYTHON="${BRAIN_ENGINE:-$HOME/brain/engine}/.venv/bin/python"
if [ ! -x "$PYTHON" ]; then
  PYTHON=$(command -v python3)
fi

ARGS=()
if [ "$DRY_RUN" = "false" ]; then
  ARGS+=(--apply)
fi
for item in "min_sim:--min-sim" "auto_sim:--auto-sim" \
  "max_links:--max-links" "top_neighbors:--top-neighbors" \
  "proposals_days:--proposals-days"; do
  key="${item%%:*}"
  flag="${item#*:}"
  value=$(printf '%s' "$INPUT" | jq -r --arg key "$key" '.config[$key] // empty')
  if [ -n "$value" ]; then
    ARGS+=("$flag" "$value")
  fi
done

RESULT=$("$PYTHON" "$REPO/tools/graph-groom.py" "${ARGS[@]}")
RC=$?
DURATION=$(($(date +%s)-START_TIME))

if [ "$RC" -eq 0 ] && printf '%s' "$RESULT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  REPORT=$(printf '%s' "$RESULT" | jq -r '.report // empty')
  jq -nc \
    --arg agent "$AGENT_NAME" \
    --argjson duration "$DURATION" \
    --argjson result "$RESULT" \
    --arg report "$REPORT" \
    '{
      version:"1", agent_name:$agent, status:"ok", duration_s:$duration,
      result:$result,
      side_effects:(if $report == "" then [] else [{type:"file_written",path:$report}] end),
      telemetry:{llm_calls:[]}, errors:[]
    }'
  exit 0
fi

if [ "$RC" -eq 2 ]; then
  jq -nc --arg agent "$AGENT_NAME" --argjson duration "$DURATION" \
    '{
      version:"1", agent_name:$agent, status:"skipped", duration_s:$duration,
      result:{reason:"guard_blocked"}, side_effects:[],
      telemetry:{llm_calls:[],guards_triggered:["kill-switch"]}, errors:[]
    }'
  exit 2
fi

jq -nc --arg agent "$AGENT_NAME" --argjson duration "$DURATION" \
  '{
    version:"1", agent_name:$agent, status:"failed", duration_s:$duration,
    result:{}, side_effects:[], telemetry:{llm_calls:[]},
    errors:["graph_groom_failed"]
  }'
exit 1
