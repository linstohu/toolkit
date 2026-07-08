#!/usr/bin/env bash
#
# claude-cost-report.sh
#
# 将「当前 git 仓库」的 Claude Code 用量汇总为一条 GitHub issue。报告含:
# 套餐、当日 token 量级与 cache 占比、按模型的成本/单价拆分、近 N 日 token
# 趋势图,以及 token 明细与滚动均值。数据来源为 ccusage(读取本地 Claude
# Code 用量日志);成本为 API 等价估算(订阅制不按 token 计费)。
#
# 用法:
#   claude-cost-report.sh [选项] [YYYY-MM-DD]
#
# 参数:
#   YYYY-MM-DD            指定报告日期(补录);省略则为当天
#
# 选项:
#   -n, --dry-run        预览报告,不创建 label、不推送 issue
#   -h, --help           显示本帮助并退出
#
# 环境变量:
#   CLAUDE_PLAN          套餐说明,如 'Max 5x (subscription, 5× Pro)';未设则省略该行
#   CCUSAGE_PROJECT      指定 ccusage 项目键;默认由仓库根路径自动派生
#   CCUSAGE_VERSION      ccusage 版本(默认 latest;建议复现场景钉到验证过的版本)
#   COST_REPORT_LABEL    issue 标签(默认 cost-report)
#   TREND_DAYS           趋势图天数(默认 14)
#   AVG_DAYS             明细中滚动均值的天数(默认 15)
#
# 依赖:gh(已 auth 登录)、jq、awk、node/npx、git
#
# 退出码:
#   0   成功推送,或当日无用量而跳过
#   1   运行错误(缺少依赖、非 git 仓库、ccusage 失败、找不到项目等)
#   2   用法错误(未知选项、日期非法等)
#
# 备注:日期按 ccusage 自身的分组规则划分。若需指定时区,请在 ccusage 配置
#       (~/.claude/ccusage.json)中设置 timezone,本脚本不处理时区。

set -euo pipefail

# ------------------------------------------------------------
# 配置(均可用环境变量覆盖)
# ------------------------------------------------------------
LABEL="${COST_REPORT_LABEL:-cost-report}"
CCUSAGE_VERSION="${CCUSAGE_VERSION:-latest}"    # `claude` 子命令需较新版本;复现场景可钉到验证过的版本号
PLAN="${CLAUDE_PLAN:-}"
TREND_DAYS="${TREND_DAYS:-14}"
AVG_DAYS="${AVG_DAYS:-15}"
CCUSAGE_PROJECT="${CCUSAGE_PROJECT:-}"          # ccusage 项目键;默认在 preflight 中由路径派生

# token 求和的单一来源:优先用 totalTokens(日行有此字段);缺失(如 modelBreakdowns)则四类相加。
# 各 jq 调用统一 prepend 这段,避免求和逻辑在多处漂移。
readonly JQ_TOKS='def toks(r): (r.totalTokens // ((r.inputTokens//0)+(r.outputTokens//0)+(r.cacheCreationTokens//0)+(r.cacheReadTokens//0)));'

# ------------------------------------------------------------
# 帮助与参数解析
# ------------------------------------------------------------
print_usage() {
  # 打印文件顶部的文档注释块(第 2 行至首个空行),去掉行首的 "# "
  sed -n '2,/^$/p' "$0" | sed 's/^#\( \|$\)//'
}

# 解析命令行参数,设置 DRY_RUN / REPORT_DATE
parse_args() {
  DRY_RUN=0
  local input_date=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run) DRY_RUN=1; shift ;;
      -h|--help)    print_usage; exit 0 ;;
      -*)           echo "错误:未知选项 $1" >&2; exit 2 ;;
      *)
        if [[ -z "$input_date" ]]; then
          input_date="$1"; shift
        else
          echo "错误:多余参数 $1" >&2; exit 2
        fi
        ;;
    esac
  done

  if [[ -n "$input_date" ]]; then
    validate_date "$input_date"
    REPORT_DATE="$input_date"
  else
    REPORT_DATE="$(date +%Y-%m-%d)"
  fi
}

# 校验日期:格式 YYYY-MM-DD 且不晚于今天
validate_date() {
  local d="$1"
  if [[ ! "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "错误:日期格式应为 YYYY-MM-DD" >&2; exit 2
  fi
  if [[ "$d" > "$(date +%Y-%m-%d)" ]]; then
    echo "错误:不能指定未来日期 $d" >&2; exit 2
  fi
}

# ------------------------------------------------------------
# 前置检查
# ------------------------------------------------------------
preflight() {
  local dep
  for dep in gh jq awk npx git; do
    command -v "$dep" >/dev/null || { echo "错误:缺少依赖 $dep" >&2; exit 1; }
  done
  git rev-parse --git-dir >/dev/null 2>&1 || { echo "错误:当前目录不是 git 仓库" >&2; exit 1; }

  ABS_PATH="$(git rev-parse --show-toplevel)"
  REPO_NAME="$(basename "$ABS_PATH")"
  # ccusage 以路径编码名作项目键:绝对路径中的 / . _ 均替换为 -
  if [[ -z "$CCUSAGE_PROJECT" ]]; then
    CCUSAGE_PROJECT="$(printf '%s' "$ABS_PATH" | sed 's#[/._]#-#g')"
  fi

  if [[ -z "$PLAN" ]]; then
    echo "提示:未设置 CLAUDE_PLAN,报告将省略套餐行(可 export CLAUDE_PLAN='Max 20x')" >&2
  fi

  if [[ "$DRY_RUN" -eq 0 ]]; then
    gh label list --json name --jq '.[].name' | grep -qx "$LABEL" || \
      gh label create "$LABEL" --color FBCA04 --description "Claude Code 用量报告"
  fi
}

# ------------------------------------------------------------
# 数据加载
# ------------------------------------------------------------
# 拉取全部项目的每日用量(JSON)。结构:{ projects: { "<键>": [每日行...] }, totals }
run_ccusage() {
  npx -y "ccusage@${CCUSAGE_VERSION}" claude daily --instances --breakdown --json
}

# 加载并校验数据,选出本项目的每日行数组(ROWS_JSON),提取标量到全局变量
load_data() {
  local errf; errf="$(mktemp)"
  if ! ALL_JSON="$(run_ccusage 2>"$errf")"; then
    echo "错误:ccusage 调用失败" >&2
    sed 's/^/  /' "$errf" >&2
    rm -f "$errf"
    exit 1
  fi
  rm -f "$errf"

  # 记录实际解析到的 ccusage 版本(npx 已缓存,此调用很快),用于页脚
  CCUSAGE_RESOLVED="$(npx -y "ccusage@${CCUSAGE_VERSION}" --version 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  [[ -z "$CCUSAGE_RESOLVED" ]] && CCUSAGE_RESOLVED="$CCUSAGE_VERSION"

  echo "$ALL_JSON" | jq -e . >/dev/null 2>&1 || {
    echo "错误:ccusage 未返回合法 JSON" >&2
    echo "$ALL_JSON" | head -5 >&2
    exit 1
  }

  # 选出本项目:先按编码键精确取;取不到再按仓库名后缀唯一匹配兜底
  ROWS_JSON="$(echo "$ALL_JSON" | jq -c --arg k "$CCUSAGE_PROJECT" '.projects[$k] // empty')"
  if [[ -z "$ROWS_JSON" ]]; then
    local enc_base cand count
    enc_base="$(printf '%s' "$REPO_NAME" | sed 's#[/._]#-#g')"
    cand="$(echo "$ALL_JSON" | jq -r --arg b "$enc_base" \
      '.projects | keys[] | select(. == $b or endswith("-" + $b))')"
    count="$(printf '%s\n' "$cand" | grep -c . || true)"
    if [[ "$count" -eq 1 ]]; then
      CCUSAGE_PROJECT="$cand"
      ROWS_JSON="$(echo "$ALL_JSON" | jq -c --arg k "$CCUSAGE_PROJECT" '.projects[$k]')"
    fi
  fi
  if [[ -z "$ROWS_JSON" || "$ROWS_JSON" == "null" || "$(echo "$ROWS_JSON" | jq 'length')" -eq 0 ]]; then
    echo "错误:在 ccusage 中找不到本项目的用量" >&2
    echo "  期望键:$CCUSAGE_PROJECT(仓库:$REPO_NAME)" >&2
    echo "  可用项目键(可 export CCUSAGE_PROJECT=<其一>):" >&2
    echo "$ALL_JSON" | jq -r '.projects | keys[]' | sed 's/^/    - /' >&2
    exit 1
  fi

  # 一次性提取标量(@sh 安全转义)
  eval "$(echo "$ROWS_JSON" | jq -r \
    --arg date "$REPORT_DATE" --argjson avg7d 7 --argjson avgn "$AVG_DAYS" "$JQ_TOKS"'
    def cost(r): (r.totalCost // 0);
    def lastn($n): (sort_by(.date) | (if length > $n then .[length-$n:] else . end));
    def avg($n): (lastn($n) | (map(cost(.)) | add // 0) / ([length, 1] | max));
    . as $all
    | ($date[0:7]) as $month
    | ($all | map(select(.date == $date)) | .[0]) as $t
    | ($all | map(select(.date == $date)) | length) as $has
    | @sh "HAS_DAY=\($has)",
      @sh "DAY_COST=\(if $t then cost($t) else 0 end)",
      @sh "DAY_TOK=\(if $t then toks($t) else 0 end)",
      @sh "DAY_INPUT=\($t.inputTokens // 0)",
      @sh "DAY_OUTPUT=\($t.outputTokens // 0)",
      @sh "DAY_CCREATE=\($t.cacheCreationTokens // 0)",
      @sh "DAY_CREAD=\($t.cacheReadTokens // 0)",
      @sh "MTD_COST=\($all | map(select(.date[0:7] == $month)) | map(cost(.)) | add // 0)",
      @sh "MTD_DAYS=\($all | map(select(.date[0:7] == $month)) | length)",
      @sh "AVG7=\($all | avg($avg7d))",
      @sh "AVGN=\($all | avg($avgn))",
      @sh "RECENT_DATES=\($all | lastn(7) | map(.date) | join(", "))"
  ')"
}

# 当日无用量或成本为 0:属正常情况,提示后正常退出
check_has_data() {
  if [[ "$HAS_DAY" -eq 0 ]]; then
    echo "提示:$REPORT_DATE 在 $REPO_NAME 无用量。最近有数据的日期:$RECENT_DATES"
    exit 0
  fi
  if awk -v c="$DAY_COST" -v t="$DAY_TOK" 'BEGIN { exit !(c == 0 && t == 0) }'; then
    echo "提示:$REPORT_DATE 用量为 0,跳过推送"
    exit 0
  fi
}

# ------------------------------------------------------------
# 格式化辅助
# ------------------------------------------------------------
fmt_money() { printf "%.2f" "$1"; }

# 千分位分组(不依赖 locale):1234567 -> 1,234,567
fmt_int() {
  awk -v n="$1" 'BEGIN {
    s = sprintf("%.0f", n); L = length(s); o = ""
    for (i = 1; i <= L; i++) { o = o substr(s, i, 1); r = L - i; if (r > 0 && r % 3 == 0) o = o "," }
    print o
  }'
}

# token 量级:1234567 -> 1.2M / 1234567890 -> 1.23B / 456000 -> 456.0K
fmt_mag() {
  awk -v n="$1" 'BEGIN {
    if (n >= 1e9)      printf "%.2fB", n / 1e9
    else if (n >= 1e6) printf "%.1fM", n / 1e6
    else if (n >= 1e3) printf "%.1fK", n / 1e3
    else               printf "%d", n
  }'
}

# 模型档位徽标(按模型名映射)
tier_badge() {
  case "$1" in
    *[Oo]pus*|*[Mm]ythos*|*[Ff]able*) echo "🥇 flagship" ;;
    *[Ss]onnet*)                       echo "🥈 mid" ;;
    *[Hh]aiku*)                        echo "🥉 small" ;;
    *)                                 echo "—" ;;
  esac
}

# 有效单价 $/Mtok = cost / tokens × 1e6(会被廉价 cache-read 拉低)
eff_price() {
  awk -v c="$1" -v t="$2" 'BEGIN { if (t > 0) printf "$%.2f", c / t * 1e6; else printf "—" }'
}

# 某成本占当日总成本的百分比
pct_of_day() {
  awk -v x="$1" -v d="$DAY_COST" 'BEGIN { if (d > 0) printf "%.0f%%", x / d * 100; else printf "—" }'
}

# 把天数格式化为可读窗口:7 的整数倍用「周」,否则用「天」(14 -> 2 weeks,30 -> 30 days)
fmt_window() {
  local d="$1"
  if (( d % 7 == 0 )); then
    local w=$(( d / 7 ))
    (( w == 1 )) && echo "1 week" || echo "${w} weeks"
  else
    (( d == 1 )) && echo "1 day" || echo "${d} days"
  fi
}

# ------------------------------------------------------------
# 报告构造
# ------------------------------------------------------------
build_title() {
  echo "Claude · ${REPO_NAME} · ${REPORT_DATE} · $(fmt_mag "$DAY_TOK") tok · \$$(fmt_money "$DAY_COST") (API-eq)"
}

build_snapshot() {
  local cread_pct vs7 sign
  cread_pct="$(awk -v r="$DAY_CREAD" -v t="$DAY_TOK" 'BEGIN { if (t > 0) printf "%.0f%%", r / t * 100; else print "0%" }')"
  if awk -v a="$AVG7" 'BEGIN { exit !(a > 0) }'; then
    vs7="$(awk -v c="$DAY_COST" -v a="$AVG7" 'BEGIN { printf "%.0f", (c - a) / a * 100 }')"
    if [[ "$vs7" == -* ]]; then sign="↓ "; vs7="${vs7#-}"; else sign="↑ +"; fi
    vs7="${sign}${vs7}%"
  else
    vs7="—"
  fi

  echo "## 📌 Today summary"
  echo
  echo "> [!NOTE]"
  echo "> Cost is an API-equivalent estimate. Claude subscription plans are not billed per token."
  echo
  echo "| Metric | Value |"
  echo "|--------|------:|"
  [[ -n "$PLAN" ]] && echo "| Plan | ${PLAN} |"
  echo "| Today tokens | $(fmt_mag "$DAY_TOK") |"
  echo "| Cache read | ${cread_pct} |"
  echo "| API-eq cost | \$$(fmt_money "$DAY_COST") |"
  echo "| vs 7d avg cost | ${vs7} |"
  echo "| Month-to-date cost | \$$(fmt_money "$MTD_COST") |"
}

build_model_table() {
  local rows
  rows="$(echo "$ROWS_JSON" | jq -r --arg date "$REPORT_DATE" "$JQ_TOKS"'
    map(select(.date == $date)) | .[0] // {}
    | (.modelBreakdowns // [])
    | map({ name: (.modelName // "?"), tok: toks(.), cost: (.cost // 0) })
    | sort_by(-.cost)
    | .[] | "\(.name)\t\(.tok)\t\(.cost)"
  ')"

  echo "## ① Cost by model"
  echo
  if [[ -z "$rows" ]]; then
    echo "_No model breakdown available._"
    return
  fi
  # 列序:先成本相关(读者最先关心),有效单价作为解释性指标放最后
  echo "| Model | Tier | Tokens | Cost | Cost share | Effective \$/Mtok |"
  echo "|-------|------|-------:|-----:|-----------:|------------------:|"
  while IFS=$'\t' read -r name tok cost; do
    printf "| %s | %s | %s | \$%s | %s | %s |\n" \
      "$name" "$(tier_badge "$name")" "$(fmt_mag "$tok")" \
      "$(fmt_money "$cost")" "$(pct_of_day "$cost")" "$(eff_price "$cost" "$tok")"
  done <<< "$rows"
  echo
  echo "_Effective price includes cache-read tokens, so it can be far below list pricing._"
}

build_trend() {
  local out have ymax labels vals
  # 以 REPORT_DATE 为终点、往回取 TREND_DAYS 个「连续日历日」;缺失日补 0。
  # 日期运算走 jq(UTC),避免 GNU/BSD `date` 差异。输出 4 行:have / ymax / labels / vals。
  out="$(echo "$ROWS_JSON" | jq -r --arg end "$REPORT_DATE" --argjson n "$TREND_DAYS" "$JQ_TOKS"'
    (map({ key: .date, value: (toks(.) / 1000000 * 100 | floor / 100) }) | from_entries) as $m
    | ($end + "T00:00:00Z" | fromdateiso8601) as $e0
    | [ range(0; $n) | ($e0 - (($n - 1 - .) * 86400)) | gmtime | strftime("%Y-%m-%d") ] as $days
    | ($days | map($m[.] // 0)) as $vals
    | ($days | map(select($m[.] != null)) | length) as $have
    | ($vals | max) as $mx
    | (if (($mx * 1.2 + 0.999) | floor) < 1 then 1 else (($mx * 1.2 + 0.999) | floor) end) as $ymax
    | "\($have)", "\($ymax)",
      "\($days | map(.[5:]) | join(", "))",
      "\($vals | join(", "))"
  ')"
  have="$(sed -n '1p' <<<"$out")"
  ymax="$(sed -n '2p' <<<"$out")"
  labels="$(sed -n '3p' <<<"$out")"
  vals="$(sed -n '4p' <<<"$out")"

  echo "## ② Tokens by day"
  echo
  # 窗口内有用量的天数 < 2 时,单点折线画不出趋势,退化为一行说明
  if [[ "$have" -lt 2 ]]; then
    echo "_Not enough data to plot (need ≥2 days with usage in the last $(fmt_window "$TREND_DAYS"))._"
    return
  fi
  echo "_Last $(fmt_window "$TREND_DAYS") · missing days shown as 0._"
  cat <<EOF
\`\`\`mermaid
xychart-beta
  title "Daily tokens (Mtok)"
  x-axis [${labels}]
  y-axis "Mtok" 0 --> ${ymax}
  line [${vals}]
\`\`\`
EOF
}

build_raw_numbers() {
  cat <<EOF
## ③ Raw numbers

<details><summary><strong>Token breakdown and rolling cost</strong></summary>

**Token breakdown (${REPORT_DATE})**

| Type | Tokens | Compact |
|------|-------:|--------:|
| Input | $(fmt_int "$DAY_INPUT") | $(fmt_mag "$DAY_INPUT") |
| Output | $(fmt_int "$DAY_OUTPUT") | $(fmt_mag "$DAY_OUTPUT") |
| Cache create | $(fmt_int "$DAY_CCREATE") | $(fmt_mag "$DAY_CCREATE") |
| Cache read | $(fmt_int "$DAY_CREAD") | $(fmt_mag "$DAY_CREAD") |

**Rolling cost**

| Metric | API-eq cost |
|--------|------------:|
| Month-to-date (${REPORT_DATE:0:7}, ${MTD_DAYS}d) | \$$(fmt_money "$MTD_COST") |
| ${AVG_DAYS}-day daily average | \$$(fmt_money "$AVGN")/day |
| 7-day daily average | \$$(fmt_money "$AVG7")/day |

</details>
EOF
}

build_footer() {
  local cc_ver
  cc_ver="$(claude --version 2>/dev/null | head -1 || echo 'unknown')"
  cat <<EOF
<sub>generated $(date '+%Y-%m-%d %H:%M %Z') · ccusage ${CCUSAGE_RESOLVED} · ${cc_ver}</sub>
EOF
}

build_body() {
  build_snapshot
  printf '\n'
  build_model_table
  printf '\n'
  build_trend
  printf '\n'
  build_raw_numbers
  printf '\n'
  build_footer
}

# ------------------------------------------------------------
# 推送 / 预览
# ------------------------------------------------------------
publish() {
  local title body tmp url
  title="$(build_title)"
  body="$(build_body)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    cat <<EOF
================ DRY RUN ================
Repo:    ${REPO_NAME}
Project: ${CCUSAGE_PROJECT}
Title:   ${title}
Label:   ${LABEL}
----------------- Body ------------------
${body}
=========================================
(未推送:--dry-run)
EOF
    return
  fi

  tmp="$(mktemp)"; trap 'rm -f "$tmp"' RETURN
  printf '%s\n' "$body" > "$tmp"
  url="$(gh issue create --title "$title" --body-file "$tmp" --label "$LABEL")"
  echo "已创建:$url"
}

# ------------------------------------------------------------
# 入口
# ------------------------------------------------------------
main() {
  parse_args "$@"
  preflight
  load_data
  check_has_data
  publish
}

main "$@"
