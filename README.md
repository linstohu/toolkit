# toolkit

A personal collection of dotfiles and utility scripts for everyday development workflows.

## Scripts

### `claude-cost-report.sh`

把 Claude Code 的用量(基于 [`ccusage`](https://github.com/ryoppippi/ccusage))汇总成一份报告,推送到当前 git 仓库的 issue。

```sh
claude-cost-report.sh                 # 今天
claude-cost-report.sh 2026-04-20      # 补录指定日期
claude-cost-report.sh --dry-run       # 预览,不创建 label / 不推 issue
```

依赖:`gh`、`jq`、`bc`、`npx`(运行 `ccusage`)。

#### 指标释义

报告里的几个口径,容易误读的先说清楚:

- **API-equivalent pricing(等效 API 价)** — 所有金额都是按 Anthropic API 标准价折算的"等效成本",**不是你的真实账单**。订阅用户(Pro / Max)看到的数字通常远高于实付,它衡量的是"如果按 API 计费会花多少",用来评估用量规模和优化空间,而非对账。
- **Today / Spent** — 该报告日当天的等效成本。
- **Month-to-date (MTD)** — 当月 1 号至报告日的累计等效成本,以及当月已有数据的天数。用于贴近"本月预算"的视角;取代了过去意义递减的全时段总额。
- **7-day / 30-day daily average** — 最近 7 / 30 个有数据日的每日平均成本(按出现的天数平均,不补零)。
- **Input / Output tokens** — 当日的输入 / 输出 token 数。Output 单价最高,占比偏大通常意味着有压缩空间。
- **Cache created / Cache read tokens** — 提示缓存的写入与命中 token。Cache read 远比重新发送 input 便宜,命中越多越省。
- **Day position / vs 7-day average**(仅补录时显示)— 该日在历史记录中的时间排位,以及当日成本相对 7 日均值的偏差百分比。

所有金额单位为 USD,精确到分;均值保留一位小数。
