#!/usr/bin/env bash
# claude-cost-report.sh — 推送 Claude Code 用量到当前 git 仓库的 issue
#
# 用法:
#   claude-cost-report.sh                       # 今天
#   claude-cost-report.sh 2026-04-20            # 补录指定日期
#   claude-cost-report.sh --dry-run             # 预览今天
#   claude-cost-report.sh -n 2026-04-20         # 预览补录
#   claude-cost-report.sh --help

set -euo pipefail

LABEL="cost-report"

# ============================================================
# 参数解析
# ============================================================
parse_args() {
  DRY_RUN=0
  INPUT_DATE=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run|-n) DRY_RUN=1; shift ;;
      -h|--help) print_usage; exit 0 ;;
      *)
        if [[ -z "$INPUT_DATE" ]]; then
          INPUT_DATE="$1"; shift
        else
          echo "❌ 多余参数: $1"; exit 1
        fi
        ;;
    esac
  done

  if [[ -n "$INPUT_DATE" ]]; then
    validate_date "$INPUT_DATE"
    REPORT_DATE="$INPUT_DATE"
    IS_BACKFILL=1
  else
    REPORT_DATE=$(date +%Y-%m-%d)
    IS_BACKFILL=0
  fi
}

print_usage() {
  cat <<USAGE
用法: $0 [--dry-run] [YYYY-MM-DD]

  无参数              生成今天的报告并推送
  YYYY-MM-DD          补录指定日期
  --dry-run, -n       预览输出,不创建 label、不推 issue
USAGE
}

validate_date() {
  local d="$1"
  if ! [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "❌ 日期格式错误,需要 YYYY-MM-DD"; exit 1
  fi
  if ! date -j -f "%Y-%m-%d" "$d" "+%Y-%m-%d" >/dev/null 2>&1; then
    echo "❌ 不是合法日期: $d"; exit 1
  fi
  if [[ "$d" > "$(date +%Y-%m-%d)" ]]; then
    echo "❌ 不能指定未来日期: $d"; exit 1
  fi
}

# ============================================================
# 前置检查
# ============================================================
preflight() {
  command -v gh >/dev/null || { echo "需要 gh CLI: brew install gh && gh auth login"; exit 1; }
  command -v jq >/dev/null || { echo "需要 jq: brew install jq"; exit 1; }
  command -v bc >/dev/null || { echo "需要 bc"; exit 1; }
  git rev-parse --git-dir >/dev/null 2>&1 || { echo "当前目录不是 git 仓库"; exit 1; }

  if [[ "$DRY_RUN" == "0" ]]; then
    gh label list --json name --jq '.[].name' | grep -qx "$LABEL" || \
      gh label create "$LABEL" --color FBCA04 --description "Claude Code 用量滚动报告"
  fi
}

# ============================================================
# 数据加载与字段提取
# ============================================================
load_data() {
  ALL_JSON=$(npx -y ccusage@latest daily --json --breakdown)

  # 一次性提取所有需要的标量
  eval "$(echo "$ALL_JSON" | jq -r --arg date "$REPORT_DATE" '
    .daily as $d
    | ($d | map(.date) | unique | length) as $days_count
    | ($d | map(.totalCost // 0) | add // 0) as $all_total
    | ($d | sort_by(.date) | .[-7:] | map(.totalCost // 0) | add / (length|if .==0 then 1 else . end)) as $avg_7
    | ($d | sort_by(.date) | .[-30:] | map(.totalCost // 0) | add / (length|if .==0 then 1 else . end)) as $avg_30
    | ($d | map(select(.date == $date)) | .[0]) as $t
    | @sh "DAYS_COUNT=\($days_count)",
      @sh "ALL_TOTAL=\($all_total)",
      @sh "AVG_7=\($avg_7)",
      @sh "AVG_30=\($avg_30)",
      @sh "DAY_COST=\($t.totalCost // 0)",
      @sh "DAY_INPUT=\($t.inputTokens // 0)",
      @sh "DAY_OUTPUT=\($t.outputTokens // 0)",
      @sh "DAY_CACHE_CREATE=\($t.cacheCreationTokens // 0)",
      @sh "DAY_CACHE_READ=\($t.cacheReadTokens // 0)"
  ')"
}

check_has_data() {
  local count
  count=$(echo "$ALL_JSON" | jq -r --arg date "$REPORT_DATE" '
    [.daily[] | select(.date == $date)] | length
  ')
  if [[ "$count" == "0" ]]; then
    echo "ℹ️  ${REPORT_DATE} 没有用量数据,跳过推送。"
    exit 0
  fi
  if [[ "$(printf "%.0f" "$(echo "$DAY_COST * 100" | bc -l)")" == "0" ]]; then
    echo "ℹ️  ${REPORT_DATE} 用量为 \$0.00,跳过推送。"
    exit 0
  fi
}

# ============================================================
# 格式化辅助
# ============================================================
fmt_money() { printf "%.2f" "$1"; }
fmt_num()   { printf "%'d" "$1" 2>/dev/null || echo "$1"; }

# ============================================================
# 报告区块构造
# ============================================================
build_header() {
  if [[ "$IS_BACKFILL" == "1" ]]; then
    echo "## Claude Cost Report — ${REPORT_DATE} (backfilled on $(date +%Y-%m-%d))"
  else
    echo "## Claude Cost Report — ${REPORT_DATE}"
  fi
}

build_model_table() {
  local rows
  rows=$(echo "$ALL_JSON" | jq -r --arg date "$REPORT_DATE" '
    .daily[]
    | select(.date == $date)
    | .modelBreakdowns[]?
    | "| \(.modelName) | \(.inputTokens) | \(.outputTokens) | \(.cacheCreationTokens) | \(.cacheReadTokens) | $\(.cost | . * 100 | floor / 100) |"
  ')

  # 老版本退化
  if [[ -z "$rows" ]]; then
    local models
    models=$(echo "$ALL_JSON" | jq -r --arg date "$REPORT_DATE" '
      .daily[] | select(.date == $date) | .modelsUsed // [] | join(", ")
    ')
    rows="| ${models:-(无)} | ${DAY_INPUT} | ${DAY_OUTPUT} | ${DAY_CACHE_CREATE} | ${DAY_CACHE_READ} | \$$(fmt_money "$DAY_COST") |"
  fi

  cat <<EOF
| Model | Input Tokens | Output Tokens | Cache Created | Cache Read | Cost (USD) |
|-------|-------------:|--------------:|--------------:|-----------:|-----------:|
${rows}

**Total Cost: \$$(fmt_money "$DAY_COST")**
EOF
}

build_cumulative_section() {
  cat <<EOF

### Cumulative

| Metric | Value |
|--------|------:|
| All-time total (${DAYS_COUNT} days) | \$$(fmt_money "$ALL_TOTAL") |
| 7-day daily average | \$$(fmt_money "$AVG_7") |
| 30-day daily average | \$$(fmt_money "$AVG_30") |
EOF
}

build_context_section() {
  # 补录场景:显示这一天在历史中的位置
  local rank total_days vs_7d_pct
  rank=$(echo "$ALL_JSON" | jq -r --arg date "$REPORT_DATE" '
    [.daily[] | .date] | sort | index($date) + 1
  ')
  total_days="$DAYS_COUNT"

  # 当日 vs 7 日均值的百分比偏差
  if [[ "$(printf "%.0f" "$(echo "$AVG_7 * 100" | bc -l)")" != "0" ]]; then
    vs_7d_pct=$(echo "scale=1; ($DAY_COST - $AVG_7) * 100 / $AVG_7" | bc -l)
    local sign=""
    [[ "$(echo "$vs_7d_pct >= 0" | bc -l)" == "1" ]] && sign="+"
    vs_7d_pct="${sign}${vs_7d_pct}%"
  else
    vs_7d_pct="N/A"
  fi

  cat <<EOF

### Context

| Metric | Value |
|--------|------:|
| Day position | ${rank} of ${total_days} recorded days |
| 7-day average (most recent) | \$$(fmt_money "$AVG_7") |
| This day vs 7-day average | ${vs_7d_pct} |
EOF
}

build_token_breakdown() {
  cat <<EOF

### Token Breakdown

| Metric | Value |
|--------|------:|
| Input tokens | $(fmt_num "$DAY_INPUT") |
| Output tokens | $(fmt_num "$DAY_OUTPUT") |
| Cache creation tokens | $(fmt_num "$DAY_CACHE_CREATE") |
| Cache read tokens | $(fmt_num "$DAY_CACHE_READ") |
EOF
}

build_footer() {
  cat <<EOF

---
<sub>Generated $(date '+%Y-%m-%d %H:%M:%S %Z'). Costs are API-equivalent pricing even on subscription plans. Each new report supersedes the previous one.</sub>
EOF
}

build_title() {
  if [[ "$IS_BACKFILL" == "1" ]]; then
    echo "Claude cost — ${REPORT_DATE} (\$$(fmt_money "$DAY_COST"), backfilled)"
  else
    echo "Claude cost — ${REPORT_DATE} (\$$(fmt_money "$DAY_COST") today, \$$(fmt_money "$ALL_TOTAL") total)"
  fi
}

build_body() {
  build_header
  echo
  build_model_table

  if [[ "$IS_BACKFILL" == "1" ]]; then
    build_context_section
  else
    build_cumulative_section
  fi

  build_token_breakdown
  build_footer
}

# ============================================================
# 推送或预览
# ============================================================
publish() {
  local title body
  title=$(build_title)
  body=$(build_body)

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "================ DRY RUN ================"
    echo "Title: $title"
    echo "Label: $LABEL"
    echo "Repo:  $(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo '(无法识别)')"
    echo "----------------- Body ------------------"
    echo "$body"
    echo "========================================="
    echo "ℹ️  未推送 issue (--dry-run)"
  else
    local url
    url=$(gh issue create --title "$title" --body "$body" --label "$LABEL")
    echo "✅ 已创建: $url"
  fi
}

# ============================================================
# 主流程
# ============================================================
main() {
  parse_args "$@"
  preflight
  load_data
  check_has_data
  publish
}

main "$@"
