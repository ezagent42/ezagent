# 场景 12(执行记录):dispatch 审计核对(全流程收口)

| 字段 | 值 |
|---|---|
| **状态** | ⚠️ PASS-with-finding(正向全过;零匹配无 DLQ/telemetry 信号 → P22 待 Allen 判定) |
| **对应设计场景** | [scenarios/28-dispatch-audit](../scenarios/28-dispatch-audit/scenario.zh_cn.md) |
| **验证面** | DB(PG `invocations` + `pg_tables`)+ server 日志 |
| **执行人** | zyli(主线 Claude 代查) |
| **执行时间** | 2026-06-25 ~17:30 |
| **环境** | 分支 `feat/product-gaps-f9-f12`(= main `8b673310`)· PG `ezagent_pg_compat_dev` |
| **前置 scenario** | scenario-01~09(收口交叉验证;Feishu 10/11 本轮未跑) |

## 前置条件(当次实际)

- psql 不在 PATH(PG 在 Windows 宿主)→ 用 `mix run --no-start`(仅启 `:ecto_sql`/`:postgrex`/Repo,不 boot 主树)查 PG

## 执行记录(逐步)

| # | 操作 | 实际观察 | 证据 | 判定 |
|---|---|---|---|---|
| 1 | 查 `pg_tables` 含 dlq/dead-letter/telemetry/dispatch/audit 的表 | **零匹配** —— public schema 无任何此类持久化表 | s12-invocations-audit.txt §1 | 📌 |
| 2 | 查 zyli-test-1 相关 `invocations`,逐条对 04/05/07/08/09 | echo/curl 往返均 `send→receive→send` 全 `granted`;mention **单播成立**(只被 @ 的 agent 有 `agent.receive`);非成员 **零投递**(无 `agent.receive`) | s12-invocations-audit.txt §2 | ✅ |
| 3 | 查 unroutable/dlq/reject/zero_match invocations + 日志 telemetry | **零结果** —— DB 无、日志无 | s12-invocations-audit.txt §3 | 📌 |

## 实测结果 vs 预期

| 设计场景预期 | 实测 | 一致? |
|---|---|---|
| 每个 agent 往返各有 invocation 行 | ✅ echo/curl:`session.send`(user)→`agent.receive`(agent)→`send`(agent 回),全 granted、可追溯 | ✅ |
| mention 路由命中=单播 | ✅ `@echo` 仅 echo 有 `agent.receive`、`@curl` 仅 curl 有 → **dispatch 层单播坐实**(回填 scenario-08 缺口) | ✅ |
| 非成员 @ 不越权投递 | ✅ echo_default/e2e-test 无任何 `agent.receive` → **dispatch 层零投递坐实**(回填 scenario-09 缺口) | ✅ |
| 无静默失败(零匹配有 DLQ/telemetry/reject) | ❌ 零匹配(04 无路由 / 09 非成员)**无 DLQ 表、无 reject invocation、无 telemetry 日志** | ❌ **见发现** |
| cc 往返有 invocation | claude-bot 无 `agent.receive`(消息送达但 cc Kind 未处理,印证 scenario-05) | —(已记 05) |

## ⭐ 发现(回填 04/08/09 + 一条新的 P22 线索)

1. **回填 scenario-08**:mention 单播在 **dispatch 层**确认 —— 只有被 @ 的 agent 收到 `agent.receive`,未被 @ 的成员零 receive。不只是"没回",是**真没收到**。
2. **回填 scenario-09**:非成员 @ 在 **dispatch 层**零投递 —— 非成员无任何 `agent.receive`。
3. **新 P22 线索(交 Allen 判定,不擅自定性)**:零匹配的消息(scenario-04 的无路由 "hello echo"、scenario-09 的 @非成员)→ 消息入 `messages` 表 + `session.send` `granted`,但**匹配到 0 个 agent 时,全系统无任何信号**:无 DLQ 表、无 `unroutable`/`reject` invocation、无 telemetry 日志。
   - 对照 Ezagent 哲学(CLAUDE.md §"这条 message 如果没人接收,谁会知道?")+ **P22 DLQ-on-zero-match** → 目前答案是"**没人知道**"。
   - **两种可能,需 Allen 判**:(a) session-chat 的零匹配本就是 no-op 设计(消息只是 post 到 transcript 给人看,不触发 agent = 合理 UX,类似 Slack @ 不存在的人);(b) 真是 DLQ-on-zero-match 的缺口。**不在测试中定性,标 issue。**

## 遗留 / bug
- 📌 上述发现 3 是本轮最有价值的待裁决项,交 Allen / dev-together。
- Feishu(10/11)未跑 → 入站 `chat.send` 的 `ctx.caller`=feishu-resolved 用户 这条留下轮。

## 证据清单
- `evidence/scenario-12/s12-invocations-audit.txt` — 审计查询全文 + 关键 invocation 行 + 结论

## 交叉引用
- 设计场景:`docs/scenarios/28-dispatch-audit`
- 不变式:P14(dispatch 唯一路径)、**P22(DLQ-on-zero-match — 本场触发待裁决)**

## 交叉引用
- 设计场景:`docs/scenarios/28-dispatch-audit`
- 不变式:P14(dispatch 唯一路径)、P22(可靠性原语在 core)
