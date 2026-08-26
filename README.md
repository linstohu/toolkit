# toolkit

个人 dotfiles 与开发常用脚本集合。

## Scripts

### `claude-cost-report.sh`

将**当前 git 仓库**的 Claude Code 用量汇总为一条 GitHub issue。数据来自 [`ccusage`](https://github.com/ccusage/ccusage)(读取本地用量日志),按仓库路径自动匹配对应项目。

报告包含:当日概览(套餐、token 量级、cache 命中占比、等效成本、相对 7 日均值的偏差、当月累计)、按模型的成本与有效单价拆分、近 N 日 token 趋势图,以及可折叠的 token 明细与滚动均值。

> 成本为 **API 等效估算**——按 Anthropic API 标准价折算,**非真实账单**。订阅用户(Pro / Max)不按 token 计费,该数字用于衡量用量规模与优化空间,而非对账。

```sh
claude-cost-report.sh                 # 今天
claude-cost-report.sh 2026-04-20      # 补录指定日期
claude-cost-report.sh --dry-run       # 预览报告,不创建 label、不推送 issue
```

**选项**

| | |
|---|---|
| `-n`, `--dry-run` | 预览报告,不创建 label、不推送 issue |
| `-h`, `--help` | 显示帮助 |

**环境变量**(均可选)

| 变量 | 默认 | 说明 |
|---|---|---|
| `CLAUDE_PLAN` | 空 | 套餐说明,如 `Max 5x`;未设则省略套餐行 |
| `CCUSAGE_PROJECT` | 由仓库根路径派生 | 手动指定 ccusage 项目键 |
| `CCUSAGE_VERSION` | `latest` | ccusage 版本,复现场景可钉到指定版本 |
| `COST_REPORT_LABEL` | `cost-report` | issue 标签 |
| `TREND_DAYS` | `14` | 趋势图天数 |
| `AVG_DAYS` | `15` | 明细中滚动均值的天数 |

**依赖**:`gh`(已登录)、`jq`、`awk`、`node`/`npx`、`git`。

当日无用量或成本为 0 时,脚本提示后正常退出,不推送。

### `dev-clean.sh`

交互式扫描并清理 macOS 上可重建的开发缓存。默认先展示清理项和空间估算，用户多选并确认后才执行；Docker 项另有一次确认。

```sh
brew install gum
scripts/dev-clean.sh             # 交互选择并确认
scripts/dev-clean.sh --dry-run   # 仅预览，不删除
```

覆盖 Xcode DerivedData、SwiftPM、不可用的 Simulator 设备记录、Homebrew、常见语言包管理器、Gradle、Go、VS Code、JetBrains，以及 Docker 构建缓存、悬空镜像和已停止容器。脚本不使用 `sudo`，也不删除可用的 Simulator、项目依赖目录、源码、Xcode Archives、Docker volumes、运行中的容器、非悬空镜像、配置或用户文档。

唯一必需的非系统运行时依赖是 `gum`；各开发工具 CLI 均为可选项，脚本会自动检测并仅在可用时提供相应清理项。
