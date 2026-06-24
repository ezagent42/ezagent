# 2026-06-24 团队 handoff 索引（全员·可转发）

> **周目标**：① ezagent 团队内跑起来（本周度量） ② 建官网。
> 本周所有 track 在**各自主机**上跑（disposable stack 停用），看别人的运行成果走**内网 tailnet 地址**。
> 本文件只是目录 —— 每条 track 的完整 handoff（任务 / 分支 / DoD / 讨论项）在各自文档里，那是 canonical。

## 各 dev 的 handoff

| Dev | 任务 | 文档 |
|---|---|---|
| @李震宇（zyli） | 人肉跑通全流程 L1–L7（仅验证 + 路由，不改 core） | `handoffs/zyli-fullflow-validation-handoff.md` |
| @黄佳佳（gaga） | 上午 cc-headless 真实现；下午 agent-config 后端 | `handoffs/gaga-cc-headless-and-agent-config-handoff.md` |
| @张宁（zhaomato） | 官网（复用 hello 的 `@json-render` 底座） | `handoffs/zhaomato-official-site-handoff.md` |
| @戴明（fatnine） | #84 Agent Console CRUD 前端 | `handoffs/agent-console-crud-handoff.draft.md` |
| @林懿伦（Allen） | 两个 core bug（session 快照竞争 / resolver 重启） | `handoffs/core-session-create-and-resolver-restart-handoff.md` |

## 今日早会必拍板（@林懿伦）
1. **Bug A session-create 快照竞争**：@林懿伦 **独立复现 + 修**（与 @李震宇 解耦，他本周仅验证）—— 决定 goal① 能否推进，优先级最高。
2. **官网范围**：@张宁 起草内容/栏目/托管(#65 CF Workers?)/路由 → 发群 → **全员排版**。
3. **agent-config 后端↔前端契约**：@黄佳佳 ↔ @戴明 下午开工前对齐。
4. （次要）Bug B 优先级、stale 分支清理提醒。
