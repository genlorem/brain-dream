#!/usr/bin/env bash
set -uo pipefail

# dream-publisher-notion — agent (plugin contract v1).
#
# Publishes dream node files from ~/brain/dreams/nodes/dream-<date>.md
# into the Notion database. Idempotent (uses "Источник" property as key).
# No LLM calls. Run from cron after nightly orchestrator.

AGENT_NAME="dream-publisher-notion"
AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${BRAIN_DREAM_REPO:-$(cd "$AGENT_DIR/.." && pwd)}"
DREAM_NODE_ROOT="${DREAM_NODE_ROOT:-$HOME/brain/dreams}"

# Guards: no LLM cost; allow up to 6 runs/hour for backfill bursts.
GUARD_COST_DAILY_USD=999  # no LLM calls; guard will never trigger by cost
GUARD_RATE_LIMIT_CALLS="${GUARD_RATE_LIMIT_CALLS:-6}"
GUARD_RATE_LIMIT_WINDOW_MIN="${GUARD_RATE_LIMIT_WINDOW_MIN:-60}"
# shellcheck disable=SC1091
source "$REPO/lib/guards.sh"

INPUT="{}"
if [ ! -t 0 ]; then INPUT=$(cat); fi

DRY_RUN=$(printf '%s' "$INPUT" | jq -r '.config.dry_run // false' 2>/dev/null || printf 'false')
INVOKED_BY=$(printf '%s' "$INPUT" | jq -r '.invoked_by // "manual"' 2>/dev/null || printf 'manual')
INPUT_DEPTH=$(printf '%s' "$INPUT" | jq -r '.input.depth // 0' 2>/dev/null || printf '0')
export INVOKED_BY INPUT_DEPTH

INPUT_NODE_FILE=$(printf '%s' "$INPUT" | jq -r '.input.node_file // ""' 2>/dev/null || printf '')
INPUT_DATE=$(printf '%s' "$INPUT" | jq -r '.input.date // ""' 2>/dev/null || printf '')
INPUT_MODE=$(printf '%s' "$INPUT" | jq -r '.input.mode // "publish"' 2>/dev/null || printf 'publish')

START_TIME=$(date +%s)

log() {
  local level="$1"; shift
  printf '{"ts":"%s","level":"%s","agent":"%s","msg":"%s"}\n' \
    "$(date -u +%FT%TZ)" "$level" "$AGENT_NAME" "$*" >&2
}

log INFO "start dry_run=$DRY_RUN invoked_by=$INVOKED_BY"

# Guards
if ! guards_pass_all; then
  cat <<GUARD
{"version":"1","agent_name":"$AGENT_NAME","status":"skipped","duration_s":$(($(date +%s)-START_TIME)),"result":{"reason":"guard_blocked"},"side_effects":[],"telemetry":{"llm_calls":[],"notion_calls":0},"errors":[]}
GUARD
  exit 2
fi

# ── Notion config ─────────────────────────────────────────────────────────────
NOTION_CONFIG="$HOME/.config/notion/personal.env"
if [ ! -f "$NOTION_CONFIG" ]; then
  log ERROR "no_notion_config file=$NOTION_CONFIG"
  cat <<FAIL
{"version":"1","agent_name":"$AGENT_NAME","status":"failed","duration_s":$(($(date +%s)-START_TIME)),"result":{},"side_effects":[],"telemetry":{"llm_calls":[],"notion_calls":0},"errors":["no_notion_token"]}
FAIL
  exit 1
fi
# shellcheck disable=SC1090
source "$NOTION_CONFIG" 2>/dev/null || true

if [ -z "${NOTION_PERSONAL_TOKEN:-}" ]; then
  log ERROR "NOTION_PERSONAL_TOKEN empty"
  cat <<FAIL
{"version":"1","agent_name":"$AGENT_NAME","status":"failed","duration_s":$(($(date +%s)-START_TIME)),"result":{},"side_effects":[],"telemetry":{"llm_calls":[],"notion_calls":0},"errors":["no_notion_token"]}
FAIL
  exit 1
fi

NOTION_DB_ID="${NOTION_DREAM_DB_ID:-37184723-14ea-81fb-a457-e8a5f930025a}"
NOTION_VERSION="2022-06-28"
NOTION_BASE="https://api.notion.com/v1"
NOTION_CALLS=0

notion_curl() {
  # Usage: notion_curl <method> <path> [body]
  local method="$1" path="$2" body="${3:-}"
  NOTION_CALLS=$((NOTION_CALLS + 1))
  local args=(-fsS --max-time 30 -X "$method" \
    -H "Authorization: Bearer $NOTION_PERSONAL_TOKEN" \
    -H "Notion-Version: $NOTION_VERSION" \
    -H "Content-Type: application/json" \
    "$NOTION_BASE$path")
  if [ -n "$body" ]; then
    args+=(-d "$body")
  fi
  curl "${args[@]}"
}

# ── sync-scores mode: propagate permanent insight scores to Notion pages ────────
run_sync_scores() {
  local permanent_dir="$DREAM_NODE_ROOT/permanent"
  local permanent_insights_scanned=0
  local skipped_no_dream_id=0
  local dreams_updated=0
  local dreams_not_found=0
  local details_s="[]"
  local side_effects_s="[]"

  # Step 1 — scan permanent insights
  if [ ! -d "$permanent_dir" ]; then
    log INFO "sync_scores permanent_dir_missing dir=$permanent_dir"
    _emit_sync_scores_output 0 0 0 0 "[]" "[]"
    return 0
  fi

  # Parse each insight file, collect into aggregation table via python
  local agg_json
  agg_json=$(python3 - "$permanent_dir" <<'PYEOF2'
import sys, os, re, json
from collections import defaultdict

permanent_dir = sys.argv[1]
files = sorted(f for f in os.listdir(permanent_dir) if f.startswith('insight-') and f.endswith('.md'))

def parse_fm(content):
    lines = content.split('\n')
    fm_start = fm_end = None
    for i, line in enumerate(lines):
        if line.strip() == '---':
            if fm_start is None:
                fm_start = i
            else:
                fm_end = i
                break
    if fm_start is None or fm_end is None:
        return {}
    result = {}
    for line in lines[fm_start+1:fm_end]:
        if ':' not in line:
            continue
        key, _, rest = line.partition(':')
        key = key.strip()
        rest = rest.strip()
        if not key or key.startswith('#'):
            continue
        # Strip quotes
        if (rest.startswith("'") and rest.endswith("'")) or \
           (rest.startswith('"') and rest.endswith('"')):
            rest = rest[1:-1]
        result[key] = rest
    return result

scanned = 0
skipped = 0
by_dream = defaultdict(list)

for fname in files:
    fpath = os.path.join(permanent_dir, fname)
    try:
        with open(fpath, 'r', encoding='utf-8') as f:
            content = f.read()
    except Exception:
        continue
    fm = parse_fm(content)
    dream_id = fm.get('dream_id', '')
    if not dream_id or dream_id in ('null', 'None', ''):
        skipped += 1
        scanned += 1
        continue
    scanned += 1
    try:
        score = float(fm.get('critic_score', '0') or '0')
    except ValueError:
        score = 0.0
    rubric = fm.get('critic_rubric', '')
    by_dream[dream_id].append({'score': score, 'rubric': rubric})

groups = []
for dream_id, items in sorted(by_dream.items()):
    scores = [it['score'] for it in items]
    rubrics = [it['rubric'] for it in items]
    # most common rubric
    from collections import Counter
    rubric = Counter(rubrics).most_common(1)[0][0] if rubrics else ''
    groups.append({
        'dream_id': dream_id,
        'count': len(items),
        'max_score': round(max(scores), 6),
        'avg_score': round(sum(scores)/len(scores), 6),
        'rubric': rubric,
    })

print(json.dumps({'scanned': scanned, 'skipped': skipped, 'groups': groups}, ensure_ascii=False))
PYEOF2
)

  permanent_insights_scanned=$(printf '%s' "$agg_json" | jq -r '.scanned // 0')
  skipped_no_dream_id=$(printf '%s' "$agg_json" | jq -r '.skipped // 0')
  local groups
  groups=$(printf '%s' "$agg_json" | jq -c '.groups // []')
  local group_count
  group_count=$(printf '%s' "$groups" | jq 'length')

  log INFO "sync_scores scanned=$permanent_insights_scanned skipped=$skipped_no_dream_id groups=$group_count"

  # Steps 3–4: per dream — query Notion, patch page
  local i=0
  while [ "$i" -lt "$group_count" ]; do
    local row
    row=$(printf '%s' "$groups" | jq -c ".[$i]")
    local dream_id count max_score avg_score rubric
    dream_id=$(printf '%s' "$row" | jq -r '.dream_id')
    count=$(printf '%s' "$row" | jq -r '.count')
    max_score=$(printf '%s' "$row" | jq -r '.max_score')
    avg_score=$(printf '%s' "$row" | jq -r '.avg_score')
    rubric=$(printf '%s' "$row" | jq -r '.rubric')

    log INFO "sync_scores querying_notion dream_id=$dream_id"

    # Step 3: find Notion page via Источник "contains" dream_id
    local query_body page_resp page_id
    query_body=$(jq -n --arg did "$dream_id" \
      '{"filter":{"property":"Источник","rich_text":{"contains":$did}}}')
    page_resp=$(notion_curl POST "/databases/$NOTION_DB_ID/query" "$query_body" 2>&1) || {
      log WARN "sync_scores notion_query_failed dream_id=$dream_id"
      details_s=$(printf '%s' "$details_s" | jq -c \
        --arg did "$dream_id" --argjson cnt "$count" \
        --argjson ms "$max_score" --argjson as "$avg_score" --arg r "$rubric" \
        '. + [{"dream_id":$did,"insights_count":$cnt,"max_score":$ms,"avg_score":$as,"rubric":$r,"notion_page_id":null,"action":"query_failed"}]')
      i=$((i+1))
      continue
    }

    local result_count
    result_count=$(printf '%s' "$page_resp" | jq -r '.results | length' 2>/dev/null || printf '0')

    if [ "$result_count" -eq 0 ]; then
      log WARN "sync_scores notion_page_not_found dream_id=$dream_id"
      dreams_not_found=$((dreams_not_found + 1))
      details_s=$(printf '%s' "$details_s" | jq -c \
        --arg did "$dream_id" --argjson cnt "$count" \
        --argjson ms "$max_score" --argjson as "$avg_score" --arg r "$rubric" \
        '. + [{"dream_id":$did,"insights_count":$cnt,"max_score":$ms,"avg_score":$as,"rubric":$r,"notion_page_id":null,"action":"page_not_found"}]')
      i=$((i+1))
      continue
    fi

    page_id=$(printf '%s' "$page_resp" | jq -r '.results[0].id')

    # Step 4: PATCH page properties
    local patch_body action
    patch_body=$(jq -n \
      --argjson cnt "$count" \
      --argjson ms "$max_score" \
      --arg r "$rubric" \
      '{
        "properties": {
          "Статус": {"select": {"name": "промоучен"}},
          "Подтверждено критиком": {"number": $cnt},
          "Score критика": {"number": $ms},
          "Рубрика": {"rich_text": [{"text": {"content": $r}}]}
        }
      }')

    if [ "$DRY_RUN" = "true" ]; then
      action="would_update"
      log INFO "sync_scores dry_run action=would_update dream_id=$dream_id page_id=$page_id"
    else
      notion_curl PATCH "/pages/$page_id" "$patch_body" >/dev/null 2>&1 || {
        log WARN "sync_scores patch_failed dream_id=$dream_id page_id=$page_id"
        details_s=$(printf '%s' "$details_s" | jq -c \
          --arg did "$dream_id" --argjson cnt "$count" \
          --argjson ms "$max_score" --argjson as "$avg_score" --arg r "$rubric" --arg pid "$page_id" \
          '. + [{"dream_id":$did,"insights_count":$cnt,"max_score":$ms,"avg_score":$as,"rubric":$r,"notion_page_id":$pid,"action":"patch_failed"}]')
        i=$((i+1))
        continue
      }
      action="updated"
      dreams_updated=$((dreams_updated + 1))
      log INFO "sync_scores updated dream_id=$dream_id page_id=$page_id"
      side_effects_s=$(printf '%s' "$side_effects_s" | jq -c \
        --arg pid "$page_id" --arg did "$dream_id" \
        '. + [{"type":"notion_page_update","page_id":$pid,"dream_id":$did}]')
    fi

    details_s=$(printf '%s' "$details_s" | jq -c \
      --arg did "$dream_id" --argjson cnt "$count" \
      --argjson ms "$max_score" --argjson as "$avg_score" --arg r "$rubric" --arg pid "$page_id" --arg act "$action" \
      '. + [{"dream_id":$did,"insights_count":$cnt,"max_score":$ms,"avg_score":$as,"rubric":$r,"notion_page_id":$pid,"action":$act}]')

    i=$((i+1))
  done

  _emit_sync_scores_output \
    "$permanent_insights_scanned" "$skipped_no_dream_id" \
    "$dreams_updated" "$dreams_not_found" \
    "$details_s" "$side_effects_s"
}

_emit_sync_scores_output() {
  local scanned="$1" skipped="$2" updated="$3" not_found="$4"
  local details_s="$5" side_effects_s="$6"
  local duration=$(($(date +%s) - START_TIME))
  jq -n \
    --arg an "$AGENT_NAME" \
    --argjson dur "$duration" \
    --argjson sc "$scanned" \
    --argjson sk "$skipped" \
    --argjson up "$updated" \
    --argjson nf "$not_found" \
    --argjson det "$details_s" \
    --argjson se "$side_effects_s" \
    --argjson nc "$NOTION_CALLS" \
    '{
      version: "1",
      agent_name: $an,
      status: "ok",
      duration_s: $dur,
      result: {
        mode: "sync-scores",
        permanent_insights_scanned: $sc,
        skipped_no_dream_id: $sk,
        dreams_updated: $up,
        dreams_not_found_in_notion: $nf,
        details: $det
      },
      side_effects: $se,
      telemetry: {llm_calls: [], notion_calls: $nc},
      errors: []
    }'
}

# ── Mode dispatch ──────────────────────────────────────────────────────────────
case "${INPUT_MODE:-publish}" in
  sync-scores)
    log INFO "mode=sync-scores dry_run=$DRY_RUN"
    run_sync_scores
    exit 0
    ;;
  publish|*)
    # fall through to existing publish logic below
    ;;
esac

# ── Collect target files ──────────────────────────────────────────────────────
declare -a TARGET_FILES=()

if [ -n "$INPUT_NODE_FILE" ]; then
  TARGET_FILES=("$INPUT_NODE_FILE")
  log INFO "mode=single_file file=$INPUT_NODE_FILE"
elif [ -n "$INPUT_DATE" ]; then
  node_path="$DREAM_NODE_ROOT/nodes/dream-${INPUT_DATE}.md"
  TARGET_FILES=("$node_path")
  log INFO "mode=date date=$INPUT_DATE file=$node_path"
else
  # Scan for files lacking notion_page_id in frontmatter
  log INFO "mode=scan dir=$DREAM_NODE_ROOT/nodes"
  while IFS= read -r f; do
    if ! grep -q '^notion_page_id:' "$f" 2>/dev/null; then
      TARGET_FILES+=("$f")
    fi
  done < <(find "$DREAM_NODE_ROOT/nodes" -name 'dream-*.md' -type f | sort)
  log INFO "unpublished_count=${#TARGET_FILES[@]}"
fi

# ── Python helper: parse frontmatter + extract top title from body ─────────────
parse_node_file() {
  local filepath="$1"
  python3 - "$filepath" <<'PYEOF'
import sys, re, json

filepath = sys.argv[1]
try:
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
except Exception as e:
    print(json.dumps({"error": str(e)}))
    sys.exit(0)

lines = content.split('\n')

# Find frontmatter boundaries
fm_start = None
fm_end = None
for i, line in enumerate(lines):
    if line.strip() == '---':
        if fm_start is None:
            fm_start = i
        else:
            fm_end = i
            break

if fm_start is None or fm_end is None:
    print(json.dumps({"error": "no_frontmatter"}))
    sys.exit(0)

fm_lines = lines[fm_start+1:fm_end]
body_lines = lines[fm_end+1:]

def strip_comment(s):
    """Strip trailing inline # comment, but not inside quotes."""
    # Simple: find # preceded by space (not inside quoted value)
    result = re.sub(r'\s+#\s+.*$', '', s)
    return result.strip()

def parse_scalar(s):
    s = s.strip()
    # Single-quoted string
    if s.startswith("'") and s.endswith("'"):
        return s[1:-1]
    # Double-quoted string
    if s.startswith('"') and s.endswith('"'):
        return s[1:-1]
    return s

def parse_flow_list(s):
    """Parse [a, b, c] style flow lists."""
    s = s.strip()
    if not (s.startswith('[') and s.endswith(']')):
        return None
    inner = s[1:-1]
    if not inner.strip():
        return []
    items = []
    for part in inner.split(','):
        part = part.strip()
        if part.startswith("'") and part.endswith("'"):
            part = part[1:-1]
        elif part.startswith('"') and part.endswith('"'):
            part = part[1:-1]
        if part:
            items.append(part)
    return items

result = {}
for line in fm_lines:
    if ':' not in line:
        continue
    key, _, rest = line.partition(': ')
    key = key.strip()
    rest = strip_comment(rest)
    if not key or key.startswith('#'):
        continue
    # Try flow list
    fl = parse_flow_list(rest)
    if fl is not None:
        result[key] = fl
    else:
        result[key] = parse_scalar(rest)

# Extract numeric fields safely
for field in ['gemini_passes', 'gemini_cost_usd', 'sonnet_passes',
              'sonnet_session_share_pct', 'candidate_count']:
    if field in result:
        try:
            result[field] = float(result[field])
        except (ValueError, TypeError):
            result[field] = None

# Extract top title from body: first line matching ^##\s+\d+\.\s+
top_title = None
for line in body_lines:
    m = re.match(r'^##\s+\d+\.\s+(.*)', line)
    if m:
        top_title = m.group(1).strip()
        break
result['_top_title'] = top_title
result['_body'] = '\n'.join(body_lines)

print(json.dumps(result, ensure_ascii=False))
PYEOF
}

# ── Python helper: upsert frontmatter keys in file ────────────────────────────
upsert_frontmatter_keys() {
  local filepath="$1" page_id="$2" page_url="$3" published_at="$4"
  python3 - "$filepath" "$page_id" "$page_url" "$published_at" <<'PYEOF'
import sys, os, re

filepath, page_id, page_url, published_at = sys.argv[1:5]

with open(filepath, 'r', encoding='utf-8') as f:
    content = f.read()

lines = content.split('\n')
fm_start = None
fm_end = None
for i, line in enumerate(lines):
    if line.strip() == '---':
        if fm_start is None:
            fm_start = i
        else:
            fm_end = i
            break

if fm_start is None or fm_end is None:
    print("ERROR: no_frontmatter", file=sys.stderr)
    sys.exit(1)

fm_lines = lines[fm_start+1:fm_end]

# Remove existing notion_page_id, notion_url, notion_published_at lines
keys_to_remove = {'notion_page_id', 'notion_url', 'notion_published_at'}
fm_lines = [l for l in fm_lines
            if not any(l.startswith(k + ':') for k in keys_to_remove)]

# Append new keys
fm_lines.append(f"notion_page_id: '{page_id}'")
fm_lines.append(f"notion_url: '{page_url}'")
fm_lines.append(f"notion_published_at: '{published_at}'")

new_content = '\n'.join(
    lines[:fm_start+1] + fm_lines + lines[fm_end:]
)

tmp_path = filepath + '.tmp'
with open(tmp_path, 'w', encoding='utf-8') as f:
    f.write(new_content)
os.rename(tmp_path, filepath)
print("ok")
PYEOF
}

# ── Markdown body → Notion blocks ─────────────────────────────────────────────
body_to_blocks_json() {
  local body="$1"
  python3 - <<PYEOF
import sys, json

body = """${body//\"/\\\"}"""

def make_rich_text(content):
    chunks = []
    while len(content) > 2000:
        chunks.append(content[:2000])
        content = content[2000:]
    if content:
        chunks.append(content)
    return [{"type": "text", "text": {"content": c}} for c in chunks]

blocks = []
in_code = False
code_lines = []

for line in body.split('\n'):
    stripped = line.rstrip()

    # Code fence toggle
    if stripped.startswith('\`\`\`'):
        if in_code:
            # End code block
            code_content = '\n'.join(code_lines)
            blocks.append({
                "object": "block",
                "type": "code",
                "code": {
                    "rich_text": make_rich_text(code_content or " "),
                    "language": "plain text"
                }
            })
            code_lines = []
            in_code = False
        else:
            in_code = True
        continue

    if in_code:
        code_lines.append(stripped)
        continue

    if not stripped:
        continue

    if stripped.startswith('## '):
        text = stripped[3:]
        blocks.append({"object":"block","type":"heading_2",
            "heading_2":{"rich_text": make_rich_text(text)}})
    elif stripped.startswith('### '):
        text = stripped[4:]
        blocks.append({"object":"block","type":"heading_3",
            "heading_3":{"rich_text": make_rich_text(text)}})
    elif stripped.startswith('> '):
        text = stripped[2:]
        blocks.append({"object":"block","type":"quote",
            "quote":{"rich_text": make_rich_text(text)}})
    elif stripped.startswith('- '):
        text = stripped[2:]
        blocks.append({"object":"block","type":"bulleted_list_item",
            "bulleted_list_item":{"rich_text": make_rich_text(text)}})
    else:
        blocks.append({"object":"block","type":"paragraph",
            "paragraph":{"rich_text": make_rich_text(stripped)}})

print(json.dumps(blocks, ensure_ascii=False))
PYEOF
}

# ── Process each file ─────────────────────────────────────────────────────────
files_processed=0
created=0
updated=0
failed=0
details_json="[]"
side_effects_json="[]"

for node_file in "${TARGET_FILES[@]}"; do
  if [ ! -f "$node_file" ]; then
    log WARN "file_not_found file=$node_file"
    failed=$((failed + 1))
    details_json=$(printf '%s' "$details_json" | jq -c \
      --arg f "$node_file" '. + [{"node_file":$f,"action":"failed","error":"file_not_found"}]')
    continue
  fi

  log INFO "processing file=$node_file"

  # Parse frontmatter + body
  parsed=$(parse_node_file "$node_file")
  if printf '%s' "$parsed" | jq -e '.error' >/dev/null 2>&1; then
    err=$(printf '%s' "$parsed" | jq -r '.error')
    log ERROR "parse_failed file=$node_file error=$err"
    failed=$((failed + 1))
    details_json=$(printf '%s' "$details_json" | jq -c \
      --arg f "$node_file" --arg e "$err" '. + [{"node_file":$f,"action":"failed","error":$e}]')
    continue
  fi

  node_id=$(printf '%s' "$parsed" | jq -r '.id // ""')
  node_title=$(printf '%s' "$parsed" | jq -r '.title // ""')
  node_date=$(printf '%s' "$parsed" | jq -r '.date // ""')
  node_domains=$(printf '%s' "$parsed" | jq -c '.domains // []')
  node_gemini_cost=$(printf '%s' "$parsed" | jq -r '.gemini_cost_usd // 0')
  node_gemini_passes=$(printf '%s' "$parsed" | jq -r '.gemini_passes // 0')
  node_sonnet_passes=$(printf '%s' "$parsed" | jq -r '.sonnet_passes // 0')
  node_sonnet_share=$(printf '%s' "$parsed" | jq -r '.sonnet_session_share_pct // 0')
  node_candidates=$(printf '%s' "$parsed" | jq -r '.candidate_count // 0')
  node_top_title=$(printf '%s' "$parsed" | jq -r '._top_title // ""')
  node_body=$(printf '%s' "$parsed" | jq -r '._body // ""')

  # Compute sonnet_share_decimal (e.g. 10.5 → 0.105)
  node_sonnet_share_dec=$(python3 -c "print(round(float('${node_sonnet_share}') / 100, 6))" 2>/dev/null || printf '0')

  # Source marker (idempotency key)
  source_marker="${node_file} · brain id: ${node_id}"

  log INFO "parsed id=$node_id date=$node_date top_title=$node_top_title"

  # Idempotency query
  query_body=$(jq -n --arg src "$source_marker" \
    '{"filter":{"property":"Источник","rich_text":{"equals":$src}}}')

  log INFO "querying_notion source_marker=$source_marker"
  query_resp=$(notion_curl POST "/databases/$NOTION_DB_ID/query" "$query_body" 2>&1) || {
    log ERROR "notion_query_failed file=$node_file"
    failed=$((failed + 1))
    details_json=$(printf '%s' "$details_json" | jq -c \
      --arg f "$node_file" '. + [{"node_file":$f,"action":"failed","error":"notion_query_failed"}]')
    continue
  }

  existing_count=$(printf '%s' "$query_resp" | jq -r '.results | length' 2>/dev/null || printf '0')
  existing_page_id=$(printf '%s' "$query_resp" | jq -r '.results[0].id // ""' 2>/dev/null || printf '')

  log INFO "query_result count=$existing_count existing_page_id=$existing_page_id"

  # Build domains multi_select JSON
  domains_ms=$(printf '%s' "$node_domains" | jq -c '[.[] | {"name":.}]')

  # Build Notion properties payload
  properties_json=$(jq -n \
    --arg title "$node_title" \
    --arg date "$node_date" \
    --argjson domains "$domains_ms" \
    --arg top_title "$node_top_title" \
    --argjson gemini_cost "$node_gemini_cost" \
    --argjson gemini_passes "$node_gemini_passes" \
    --argjson sonnet_passes "$node_sonnet_passes" \
    --argjson sonnet_share "$node_sonnet_share_dec" \
    --argjson candidates "$node_candidates" \
    --arg source "$source_marker" \
    '{
      "Сон":         {"title": [{"text": {"content": $title}}]},
      "Дата":        {"date": {"start": $date}},
      "Статус":      {"select": {"name": "черновик"}},
      "Домены":      {"multi_select": $domains},
      "Главная тема":{"rich_text": [{"text": {"content": $top_title}}]},
      "Стоимость Gemini": {"number": $gemini_cost},
      "Gemini passes":    {"number": $gemini_passes},
      "Sonnet passes":    {"number": $sonnet_passes},
      "Sonnet share %":   {"number": $sonnet_share},
      "Кандидатов":       {"number": $candidates},
      "Подтверждено критиком": {"number": 0},
      "Источник":         {"rich_text": [{"text": {"content": $source}}]}
    }')

  # Build Notion blocks from body
  blocks_json=$(body_to_blocks_json "$node_body")
  block_count=$(printf '%s' "$blocks_json" | jq 'length')
  log INFO "blocks_count=$block_count"

  files_processed=$((files_processed + 1))

  # ── DRY RUN path ──────────────────────────────────────────────────────────
  if [ "$DRY_RUN" = "true" ]; then
    action="would_create"
    [ "$existing_count" -gt 0 ] && action="would_update"
    log INFO "dry_run action=$action file=$node_file"
    details_json=$(printf '%s' "$details_json" | jq -c \
      --arg f "$node_file" --arg a "$action" \
      --arg ep "$existing_page_id" \
      --argjson bc "$block_count" \
      --argjson props "$properties_json" \
      '. + [{"node_file":$f,"action":$a,"existing_page_id":$ep,"blocks":$bc,"properties":$props}]')
    continue
  fi

  # ── LIVE path: create or update ───────────────────────────────────────────
  if [ "$existing_count" -eq 0 ]; then
    # CREATE
    create_body=$(jq -n \
      --arg db_id "$NOTION_DB_ID" \
      --argjson props "$properties_json" \
      --argjson blocks "$blocks_json" \
      '{
        "parent": {"database_id": $db_id},
        "properties": $props,
        "children": $blocks[:100]
      }')

    log INFO "creating_page file=$node_file"
    create_resp=$(notion_curl POST "/pages" "$create_body" 2>&1) || {
      log ERROR "create_failed file=$node_file"
      failed=$((failed + 1))
      details_json=$(printf '%s' "$details_json" | jq -c \
        --arg f "$node_file" '. + [{"node_file":$f,"action":"failed","error":"create_failed"}]')
      continue
    }

    new_page_id=$(printf '%s' "$create_resp" | jq -r '.id // ""')
    new_page_url=$(printf '%s' "$create_resp" | jq -r '.url // ""')

    if [ -z "$new_page_id" ]; then
      log ERROR "create_no_id resp=$create_resp"
      failed=$((failed + 1))
      details_json=$(printf '%s' "$details_json" | jq -c \
        --arg f "$node_file" '. + [{"node_file":$f,"action":"failed","error":"create_no_id"}]')
      continue
    fi

    log INFO "created page_id=$new_page_id"

    # Append remaining blocks in batches of 100
    total_blocks=$block_count
    offset=100
    while [ "$offset" -lt "$total_blocks" ]; do
      batch=$(printf '%s' "$blocks_json" | jq -c --argjson o "$offset" '.[$o:($o+100)]')
      log INFO "appending_blocks offset=$offset"
      notion_curl PATCH "/blocks/$new_page_id/children" \
        "{\"children\": $batch}" >/dev/null 2>&1 || \
        log WARN "block_batch_failed offset=$offset"
      offset=$((offset + 100))
    done

    created=$((created + 1))
    page_id_short="${new_page_id:0:8}"
    details_json=$(printf '%s' "$details_json" | jq -c \
      --arg f "$node_file" --arg pid "$new_page_id" --arg url "$new_page_url" \
      --argjson bc "$block_count" \
      '. + [{"node_file":$f,"action":"created","notion_page_id":$pid,"notion_url":$url,"blocks":$bc}]')
    side_effects_json=$(printf '%s' "$side_effects_json" | jq -c \
      --arg pid "$new_page_id" --arg url "$new_page_url" \
      '. + [{"type":"notion_page_create","page_id":$pid,"url":$url}]')

  else
    # UPDATE
    new_page_id="$existing_page_id"
    log INFO "updating_page page_id=$new_page_id file=$node_file"

    # PATCH properties
    update_resp=$(notion_curl PATCH "/pages/$new_page_id" \
      "{\"properties\": $properties_json}" 2>&1) || {
      log ERROR "update_props_failed page_id=$new_page_id"
      failed=$((failed + 1))
      details_json=$(printf '%s' "$details_json" | jq -c \
        --arg f "$node_file" '. + [{"node_file":$f,"action":"failed","error":"update_props_failed"}]')
      continue
    }
    new_page_url=$(printf '%s' "$update_resp" | jq -r '.url // ""')

    # Replace body: get existing blocks, delete them, append new ones
    existing_blocks_resp=$(notion_curl GET "/blocks/$new_page_id/children" "" 2>&1) || true
    existing_block_ids=$(printf '%s' "$existing_blocks_resp" | jq -r '.results[].id // empty' 2>/dev/null || true)

    while IFS= read -r bid; do
      [ -z "$bid" ] && continue
      log INFO "deleting_block block_id=$bid"
      notion_curl DELETE "/blocks/$bid" "" >/dev/null 2>&1 || \
        log WARN "delete_block_failed block_id=$bid"
    done <<< "$existing_block_ids"

    # Append new blocks in batches of 100
    total_blocks=$block_count
    offset=0
    while [ "$offset" -lt "$total_blocks" ]; do
      batch=$(printf '%s' "$blocks_json" | jq -c --argjson o "$offset" '.[$o:($o+100)]')
      log INFO "appending_blocks offset=$offset"
      notion_curl PATCH "/blocks/$new_page_id/children" \
        "{\"children\": $batch}" >/dev/null 2>&1 || \
        log WARN "block_batch_failed offset=$offset"
      offset=$((offset + 100))
    done

    updated=$((updated + 1))
    page_id_short="${new_page_id:0:8}"
    details_json=$(printf '%s' "$details_json" | jq -c \
      --arg f "$node_file" --arg pid "$new_page_id" --arg url "$new_page_url" \
      --argjson bc "$block_count" \
      '. + [{"node_file":$f,"action":"updated","notion_page_id":$pid,"notion_url":$url,"blocks":$bc}]')
    side_effects_json=$(printf '%s' "$side_effects_json" | jq -c \
      --arg pid "$new_page_id" --arg url "$new_page_url" \
      '. + [{"type":"notion_page_update","page_id":$pid,"url":$url}]')
  fi

  # ── Mutate source file frontmatter ────────────────────────────────────────
  published_at=$(date -u +%FT%TZ)
  mutate_result=$(upsert_frontmatter_keys "$node_file" "$new_page_id" "$new_page_url" "$published_at" 2>&1)
  if [ "$mutate_result" = "ok" ]; then
    log INFO "frontmatter_updated file=$node_file"
  else
    log WARN "frontmatter_update_failed file=$node_file err=$mutate_result"
  fi

  # ── Git commit ────────────────────────────────────────────────────────────
  node_basename=$(basename "$node_file")
  node_date_only=$(printf '%s' "$parsed" | jq -r '.date // "unknown"')
  git_sha=""
  if git -C "$DREAM_NODE_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$DREAM_NODE_ROOT" add "nodes/$node_basename" 2>/dev/null || true
    git -C "$DREAM_NODE_ROOT" \
      -c user.name='dream-publisher-notion' \
      -c user.email='dream-publisher-notion@local' \
      commit -q -m "publisher: ${node_date_only} → notion ${page_id_short}" 2>/dev/null && \
      git_sha=$(git -C "$DREAM_NODE_ROOT" rev-parse --short HEAD) || true
    log INFO "git_committed sha=$git_sha"
    side_effects_json=$(printf '%s' "$side_effects_json" | jq -c \
      --arg sha "$git_sha" '. + [{"type":"git_commit","sha":$sha,"repo":"dreams"}]')
  else
    log WARN "not_a_git_repo path=$DREAM_NODE_ROOT"
  fi
done

# ── Final output ─────────────────────────────────────────────────────────────
DURATION=$(($(date +%s) - START_TIME))

if [ "$DRY_RUN" = "true" ]; then
  status="skipped"
else
  [ "$failed" -eq "$files_processed" ] && [ "$files_processed" -gt 0 ] && status="failed" || status="ok"
fi

jq -n \
  --arg v "1" \
  --arg an "$AGENT_NAME" \
  --arg st "$status" \
  --argjson dur "$DURATION" \
  --argjson fp "$files_processed" \
  --argjson cr "$created" \
  --argjson up "$updated" \
  --argjson fa "$failed" \
  --argjson det "$details_json" \
  --argjson se "$side_effects_json" \
  --argjson nc "$NOTION_CALLS" \
  '{
    version: $v,
    agent_name: $an,
    status: $st,
    duration_s: $dur,
    result: {
      files_processed: $fp,
      created: $cr,
      updated: $up,
      failed: $fa,
      details: $det
    },
    side_effects: $se,
    telemetry: {
      llm_calls: [],
      notion_calls: $nc
    },
    errors: []
  }'
