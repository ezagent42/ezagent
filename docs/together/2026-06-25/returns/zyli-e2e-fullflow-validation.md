# Return — zyli-developer ② e2e 场景文档(人肉 full-flow validation)

> **Task:** zyli-developer ②（plan.md 行 22 第②项）— 把人肉测试沉淀为 `docs/e2e/`
> **Branch:** `zyli/e2e-fullflow-validation-0625`（off `main` `8b673310`）
> **PR:** [#990](https://github.com/ezagent42/ezagent/pull/990)
> **Dev:** 李震宇（zyli,操作员)+ Claude(记录/取证)
> **returned_at:** 2026-06-25 18:24 +0800
> **deadline:** 2026-06-25 23:59 +0800
> **deadline_status:** on_time

## 做了什么

把今天的人肉全流程 E2E 沉淀成 **`docs/e2e/` 执行记录体系**,并**真实跑完了 12 条黄金路径**(不只是写文档):

- **体系**:`README.md`(索引+黄金路径12条+进度)、`guide.md`(分工/取证规范/判定标准)、`scenario-template.md`、`scenario-00-example.md`、`scenario-01..12-*.md`(12 条执行记录)、`evidence/`(每条 zyli 截图 + headless observer 服务端对照)。
- **协作模式**:zyli 自己浏览器操作 + 截图;主线 Claude 记录 + 派 headless **observer subagent**(自己的 agent-browser,以 admin 登录)查服务端状态截图对照。
- **flavor 矩阵实测**:echo ✅ / curl ✅(真实 DeepSeek)/ codex ✅(真实 Codex)/ **cc 🟥 确认 bug**。

## DoD reconciliation

DoD 来自 plan.md ②:`docs/e2e/`(`scenario-<no>.md` + `guide.md` + evidence example,**agent 拿 agent-browser 能照着自动跑通**)。

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | `docs/e2e/scenario-<no>.md` 存在 | met | 12 条:`docs/e2e/scenario-01..12-*.md`,每条含逐步执行记录+实测vs预期+判定 |
| 2 | `guide.md`(流程/取证规范) | met | `docs/e2e/guide.md`(角色分工/黄金路径图/取证硬规则/判定标准/收尾约定) |
| 3 | evidence example | met | `scenario-00-example.md` + `evidence/README.md`(命名约定)+ 每条真实 evidence(24 文件,zyli 截图 + observer 对照) |
| 4 | **agent 拿 agent-browser 能照着自动跑通** | met-with-note | guide §3 记录了完整 bring-up(server 必须后台启/cc·codex 凭据+代理)+ observer subagent 已实证 agent-browser 自动登录+截图;**但全自动跑 12 条受环境前置约束**(cc 撞 bug、codex 需 `codex login`+seed 凭据),非纯一键。详见 guide §3 + 各 scenario 前置。**开放决策给 lead**:是否要再补一个 `mix ezagent.e2e.run` 式一键 harness(本 return 未做)。 |

**Method friction:** ① 本环境**前台 `mix phx.server` 会被 harness 拦杀(144)**,必须 `run_in_background` —— 这类环境前置不在原 handoff 里,踩了几次才平(已写进 guide + 记忆)。② **CDP 挂操作员真实浏览器在 WSLg 下太不稳**(headed 窗口闪退/多 tab 错乱),改用「操作员自己浏览器 + observer subagent」双证据才稳 —— 取证方式 handoff 未规定,实战定的。③ **cc 我连判三次才对**(误判 template-boot-顺序 → "cc 全坏" → "只是 UI deadline" → 双层 ReadyGate),靠 rebase main + 同事反证 + 临时改动实测 + Allen 才定根因 —— 教训:别凭单点实测/一次推理下结论。

## 附带产出 —— 交 Allen / dev 的真发现(超出 DoD,均带证据)

1. 🟥 **cc 创建 bug(Allen 已确认)** — cc PTY 慢激活(>10s)撞 `create_agent` cascade **两层 5s ReadyGate**(内层 `template_spawn.ex:638`+`invocation.ex:181` 真凶 / 外层 `agent_actions.ex` 无 `deadline_ms`→`invocation.ex:269` 默认 5s 配套)→ `:activate_timeout` 回滚。**修复方法已记 `scenario-05`**;临时改动实测定位后**已还原**(无 tracked .ex 改动),真修留别的分支。
2. ⚠️ **routing divergence** — 新 session 无默认 `always→$session_members` 规则(ROUTING=0),只有 @mention 直接寻址送达(偏离 scenarios/09 设计假设)。见 `scenario-04`。
3. 📌 **P22 zero-match 待裁决** — 零匹配消息(无路由 / @非成员)无 DLQ表 / 无 reject invocation / 无 telemetry(审计 `scenario-12` 查 PG 实证)→ "没人接收时没人知道",是 chat no-op 设计还是 DLQ-on-zero-match 缺口,待 Allen 判。

## branch + gate status

- Branch `zyli/e2e-fullflow-validation-0625`,off `main` `8b673310`(rebase 后,F9/F12 已在 main)。
- **改动纯 docs**(`docs/e2e/` + 本 return);**无 tracked 代码改动**(cc 临时实验已还原,`git diff -- '*.ex' '*.exs'` 空)。
- CI(precommit + check_invariants):PR #990,docs-only 改动(无代码/无测试触及)→ 预期 green;run 状态见 PR checks。
- rebase-base SHA:`8b673310`(= 当前 `origin/main`,push 时 0 behind)。

## 合并请求(merge request)

- 请把 `zyli/e2e-fullflow-validation-0625` 纳入今日 stack。**纯 docs、零代码冲突**,可独立合,顺序不敏感。
- cc bug 的真修不在本 PR(本 PR 只记录方法 + 还原),建议 lead 另开 task / 分支跟进(scenario-05 已含修复方法)。
