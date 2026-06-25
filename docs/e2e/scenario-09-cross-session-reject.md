# 场景 09(执行记录):跨 session mention 被拒(负路径)

| 字段 | 值 |
|---|---|
| **状态** | ⚠️ PASS-with-gaps(成员作用域成立;显式拒绝信号 UI 不可见,留审计) |
| **对应设计场景** | [scenarios/11-cross-session-mention-rejected](../scenarios/11-cross-session-mention-rejected/scenario.zh_cn.md) |
| **验证面** | world LV(显式拒绝/DLQ 信号留 scenario-12) |
| **执行人** | zyli |
| **执行时间** | 2026-06-25 ~17:27 |
| **环境** | 分支 `feat/product-gaps-f9-f12`(= main `8b673310`)· server `http://world.localhost:10042` |
| **前置 scenario** | scenario-08 ✅(mention 路由已验证) |

## 前置条件(当次实际)

- session `zyli-test-1` 成员:claude-bot / zyli-curl-1 / zyli-echo-1 / admin
- **非成员** agent(基线存在但未加入本 session):`echo_default`、`e2e-test`
- 注:本场用"非成员"验成员作用域;严格的"跨 session(成员属于另一活跃 session)"未单独构造,但拒绝属性同源(非本 session 成员 → 不路由)

## 角色

- **调用方**:admin · **目标**:@ 一个**不在本 session** 的 agent —— 预期不送达/不回复

## 执行记录(逐步)

| # | 操作 | 实际观察 | 证据 | 判定 |
|---|---|---|---|---|
| 1 | 发 `@echo_default 你在吗`(17:26:27,echo_default 非成员) | 消息上屏,**echo_default 无任何回复** | [s09-step1-nonmember-no-reply-zyli](./evidence/scenario-09/s09-step1-nonmember-no-reply-zyli.png) | ✅ |
| 2 | 发 `@e2e-test 你好`(17:27:12,e2e-test 非成员) | 消息上屏,**e2e-test 无任何回复** | (同上截图) | ✅ |
| 3 | (observer)看 composer `@`autocomplete 候选 | **只列 4 个本 session 成员**(claude-bot/zyli-curl-1/zyli-echo-1/admin);echo_default/e2e-test **不在候选** | [s09-step2-nonmember-confirmed](./evidence/scenario-09/s09-step2-nonmember-confirmed.png) | ✅ |

## 实测结果 vs 预期

| 设计场景预期 | 实测 | 一致? |
|---|---|---|
| 无跨 session/非成员越权投递 | ✅ 两个非成员 agent @ 后均无回复;对照成员 `zyli-echo-1`(同 echo flavor)@ 它会回 → 证明是**成员作用域**而非 flavor | ✅ |
| dispatch 被拒**有显式信号**(非静默) | ⚠️ UI 层看不到 "rejected / unroutable / DLQ" 任何信号 —— 无法区分"显式拒绝"vs"静默丢弃" | ⏳ 留 scenario-12 审计 |

## 发现

- **成员作用域安全属性成立**:@ 非成员 agent 不会把它拉进会话、不投递、不回复。关键对照(同 flavor 的成员 vs 非成员)排除了"flavor 不工作"的混淆。
- **加分:UI 源头防护** —— composer `@`autocomplete **只列本 session 的 4 个成员**,`echo_default`/`e2e-test` 不在候选(zyli 是手打非成员名才发出的)。即正常操作下根本 @ 不到非成员,手打也不投递 → **双重保证成员作用域**。
- **"没人接收要有人知道"(P22 DLQ-on-zero-match)未能在 UI 验证**:跟 scenario-04/08 一样,UI 不暴露拒绝/DLQ/telemetry → 这条 Ezagent 核心不变式的"显式信号"部分必须在 scenario-12 查服务端 `invocations`/DLQ/telemetry 才能定论。

## 遗留 / bug
- ⏳ 显式拒绝信号(vs 静默)留 scenario-12 审计 —— 这是负路径最关键的一条(Ezagent "失败要有人知道" 哲学)。
- autocomplete 是否只列成员:见 observer 回报。

## 证据清单
- `evidence/scenario-09/s09-step1-nonmember-no-reply-zyli.png` — zyli 视角:@echo_default / @e2e-test 均无回复
- `evidence/scenario-09/s09-step2-nonmember-confirmed.png` — observer 服务端对照:两非成员零应答;`@`autocomplete 只列 4 成员、非成员不在候选

## 交叉引用
- 设计场景:`docs/scenarios/11-cross-session-mention-rejected`
