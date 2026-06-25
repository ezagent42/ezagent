# 2026-06-24 开发周期 — 完整分析（每个 PR，含 out-of-scope）

> @林懿伦 要求："昨天还有好几个 out-of-scope 的任务，review 也都考虑到了吗？给我一个昨天工作的完整分析报告。" 之前的 `review.md` + 审计补遗只覆盖了**有名字的 return**（#931/#938/#918/zyli/#956/#958/官网）。本文覆盖**整个周期** —— ~40 个 PR（#922–#968）—— 用四性质 DoD 视角逐项过，并显式补上 review 漏掉的 out-of-scope 工作。

## 0. 之前 review 的诚实缺口
之前的 review/审计分析了 agent 写的 return + 两个大事故，但**没有**覆盖：out-of-scope 项（**#940 LOGO、#941 CF 容器成本调研、#942 全容器化、#952 gaga 计划**）、lead-track 基建（**#922/#928 resource-type、#925、#947**）、gaga 的 **#945**、zyli 的 UI PR（**#949/#950**）。本文补全。

## 1. 全量清单（按 track + scope）

### A. 周期脚手架（lead，文档/流程）— 合并即验证
`#924` plan · `#926` team.md 名册 · `#929/#930` handoff · `#927` core-bug handoff · `#932/#933/#936/#946` dev-together push/close · `#923` #84 定稿。**完成** —— 都是节奏产物，无代码风险。

### B. Lead-track 代码（Claude）— 合并时都过了 precommit+check_invariants
| PR | 内容 | DoD 视角 |
|---|---|---|
| `#922`/`#928` | 插件自有 `resource://` 类型注册 PR-1（core）+ PR-2（world，raw_home_path 2→1） | ✅ 已闸；arch ratchet 正确下移 |
| `#925` | `EZAGENT_NO_DISTRIBUTION` dev 基建开关 | ✅ 小、已闸 |
| `#937` | Bug B —— resolver 重启时重放插件 resource type | ✅ 回归测试 + codex MED 已修 |
| `#939` | Bug A —— 观测静默的投递前 cast 丢失（#934 promote） | ✅ E2E 已做（zyli 批次）、加了 telemetry |
| `#943` | #93 读 cap-gate 与写对称 | ✅ 已闸 —— **但**见 #966：它漏了 `delete_path` 的预鉴权读（今晚修了） |
| `#947` | workspace-locality gate（分布式 BEAM 预备） | ✅ 已闸；默认 resolver=本地 no-op |
| `#948` | #92 umbrella sandbox owner-exit 竞争 | ✅ 多次跑验证 |
| `#951` | #94 MentionFailedTest flake（唯一 URI） | ✅ 针对性回归 |
| `#954/#955/#957/#960` | #95 LocalRuntime facade + 迁 cc/codex/echo/feishu/advisor + skill 文档 | ✅ 已闸；arch cap 下移 |
| `#959` | #98 F14 路由自环 | ✅ 回归测试 |
**风险注记：** 这些都在 CI 闸（#962）存在**之前**合的，所以是 lead 本地跑 `mix precommit` 把关、而非 CI。#943→#966 这个漏（一个未闸的读路径）说明本地把关仍会漏掉一个测试能抓到的逻辑缺陷 —— 这正是新 DoD/CI 要补的验证轴。

### C. Agent 写的 return（高风险集）
| PR | dev | 结论 | 备注 |
|---|---|---|---|
| `#931` cc-headless SDK sidecar | gaga | ✅ **真完成** | 真 Python `claude-agent-sdk` 子进程，真 Claude turn 有证 |
| `#938` agent-config facade | gaga | ⚠️ **缺陷已修** | `delete_path` 存在性泄漏 → 今晚修（#966）；echo 无 config 没文档化（→#918） |
| `#945` codex-remote roundtrip | gaga | ⚠️ **建议抽查** | 恢复 codex-remote session roundtrip；合并时已闸，但没单独审 —— 建议补一个 live/E2E 证明（和 #931"真路径"同类） |
| `#956`→`#961` hello 官网 | zhaomato→lead | ⚠️ **曾全红、已绿并合** | 6 个红 lead 修了；**前端渲染器仍与后端 shadcn catalog 脱节** → 官网重做任务 |
| `#958` agent-console CRUD | fatnine | ✅ **已合并** | 经 #968（集成到当前 main + CI 闸）合入 main `80ebce2f`（CI 首跑抓到 1 个**无关** flake、复跑绿）；后端扎实；**0 个 UI/路由测试**（延期给 gaga）；fatnine 分支保留、#958 关闭 |
| `#918` echo→Entity.Agent | fatnine | ⛔ **OPEN，陈旧** | 目标完成但落后 main 37、与 #957 LocalRuntime 冲突 → fatnine rebase + LocalRuntime-args 决策 |

### D. zyli（验证 + 产品 UI 修复）
| PR | 内容 | 结论 |
|---|---|---|
| `#944` | 全流程人肉验证 + rebase-batch 验证 | ✅ 有证完成（7 legs；crux 已清） |
| `#949` | logout/切号 UI（F3） | ✅ 小 UI；人肉跑暴露 |
| `#950` | 存 agent API key UI（F10） | ✅ 小 UI；人肉跑暴露 |
| `#953` | F14 文档归因（UI-disable 本就对 → core） | ✅ 文档 |
**暴露但未建（新 backlog）：** F9（Feishu chat→session 绑定 UI）、F12（Feishu `@`→agent mention 解析）。人肉 L3/L4 只能靠 DB 手段验证就是因为这俩缺口。

### E. Out-of-scope 工作（review 漏掉的部分）— 是否合理 + 完成？
| PR | dev | scope 判定 | 合理？ | 完成？ |
|---|---|---|---|---|
| `#940` LOGO.png | lead | out_of_scope | ✅ 微小资产，无害 | ✅ |
| `#941` CF 容器成本/适用性调研 | Claude | out_of_scope | ✅ 喂 #65 CF-Workers/部署决策（本周真实关切） | ✅ docs/notes；决策在你 |
| `#942` 全容器化 Mac stack（PG+mihomo+cloudflared） | Claude | out_of_scope | ⚠️ **scope 存疑** —— 一个完整 docker stack 以 out-of-scope 落地，但本周 disposable stack 已停用（plan 标准规则）。它到底在用还是投机性的，值得确认。 | ✅ docker/docs，但实用性未确认 |
| `#952` protocol-api + sidecar 生命周期计划 | gaga | out_of_scope（研究） | ✅ 喂 #96/#97（你的决策） | ✅ docs；决策待你 |

**Out-of-scope 过程观察：** 一个周期落了 ~4 个 out-of-scope（多是 Claude 写的 #941/#942 + 研究）。单看都还算合理，合起来是 scope drift —— 一个名义上 4 条人类开发 track 的周期，还吸收了基建调研 + 一个 docker stack。新 dev-together plan 有专门的"Off-plan（支持，非人类开发 track）"段就是为这个，但应当**预算化/先声明**、而不是堆积。建议：out-of-scope 工作开做前先在 `plan.md` 的 off-plan 段声明，让周期真实工作量可见。

## 2. 合并后的净未决项
- **#958** ✅ 已合并（#968 → `80ebce2f`）；LiveViewTest 延期给 gaga。
- **#918** fatnine：rebase + LocalRuntime-args 决策（与 #99 共用）。
- **#945** 建议补一个 live-roundtrip 抽查（codex-remote）。
- **#942** 确认 docker stack 真在用（否则记为投机性）。
- **新 backlog：** F9、F12（zyli 产品 UI 缺口）；ExternalMirror Grill-5 测试串扰 flake（#968 CI 暴露）。
- **你的决策：** #96/#97（protocol/sidecar）、`enforce_admins` 翻不翻、#99 放不放行、F9/F12 排期。

## 3. 周期健康度小结
- **量：** ~40 个 PR；吞吐高。
- **质量信号：** 4 个 agent build-return 里，**2 个没达标回来**（#956 全红；#958 缺 UI 测试），**1 个跨层迁移做了一半**（官网前端）。这就是推动 dev-together 大改（#965）+ CI 闸（#962）的模式。
- **验证缺口（现已堵上）：** #962 之前的一切都是 lead 本地把关；#943→#966 那个漏说明为什么需要 CI + 四性质 DoD。
- **Scope 纪律：** out-of-scope/off-plan 工作真实且多数有用，但未预算 —— 已为下个 plan 标注。
