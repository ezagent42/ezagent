<!-- 复制本文件为 scenario-NN-<slug>.md。填法见 guide.md。尖括号占位全部替换。 -->
# 场景 NN(执行记录):<标题>

| 字段 | 值 |
|---|---|
| **状态** | ⬜ pending / 🟩 PASS / ⚠️ PASS-with-gaps / 🟥 FAIL / 🟨 BLOCKED |
| **对应设计场景** | [docs/scenarios/NN-<slug>](../scenarios/NN-<slug>/scenario.zh_cn.md) |
| **验证面** | world LV / admin LV / CLI / 审计 |
| **执行人** | zyli |
| **执行时间** | <YYYY-MM-DD HH:MM> |
| **环境** | 分支 `<branch>` · commit `<hash>` · server `<url>` |
| **前置 scenario** | scenario-<前一条>(需已 PASS) |

## 前置条件(当次实际)

- <实际启动命令 / 登录态 / 用到的凭据 / seed 数据>
- <对应设计场景前置的差异,如有>

## 角色

- **调用方**:<entity://user/...>
- **目标**:<entity://agent/... 或 workspace://... + Behavior/action>

## 执行记录(逐步)

| # | 操作(我做了什么) | 实际观察 | 证据 | 单步判定 |
|---|---|---|---|---|
| 1 | <点了 X / 敲了命令> | <看到 Y> | [s NN-step1](./evidence/scenario-NN/sNN-step1-<slug>.png) | ✅ |
| 2 | | | | |

## 实测结果 vs 预期

| 设计场景预期 | 实测 | 一致? |
|---|---|---|
| <预期 1> | <实测> | ✅ / ❌ |

## 遗留 / bug

- <非阻塞瑕疵或发现的 bug;无则写"无">

## 证据清单

- `evidence/scenario-NN/sNN-step1-<slug>.png` — <说明>

## 交叉引用

- 设计场景:`docs/scenarios/NN-<slug>`
- 相关 PR / SPEC / 已知 gap:<...>
