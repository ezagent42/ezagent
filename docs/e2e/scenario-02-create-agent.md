# 场景 02(执行记录):创建 agent

| 字段 | 值 |
|---|---|
| **状态** | 🟩 PASS |
| **对应设计场景** | ⚠️ **设计场景缺位** —— `docs/scenarios` 暂无 agent-create 条目(候选待补)。本记录即为补 `docs/scenarios/04-agent-create` 的一手素材 |
| **验证面** | world LV |
| **执行人** | zyli |
| **执行时间** | 2026-06-25 ~16:10 |
| **环境** | 分支 `feat/product-gaps-f9-f12` · commit `913e2ba0` · server `http://world.localhost:10042` |
| **前置 scenario** | scenario-01 ✅ PASS(已登录 admin) |

## 前置条件(当次实际)

- admin 已登录;workspace 选择器 = `workspace://system`
- 本条创建 echo agent `zyli-echo-1`,供 scenario-03 加成员用

## 角色

- **调用方**:admin(`entity://system/user/admin`)
- **目标**:`workspace://system` 下新建 `entity://system/agent/zyli-echo-1`(入口 Identities → New Agent → `PROVISION`)

## 创建表单字段(Identities → New Agent,实测)

| 字段 | 说明 | 本次值 |
|---|---|---|
| **Flavor** | 下拉(echo / cc / codex / curl…) | `echo` |
| **Name** *（必填) | agent 名 | `zyli-echo-1` |
| **project_cwd** | 该 flavor 下可选 | 留空(占位 `/srv/acme/storefront`) |
| **Requested caps** | 请求的能力(逗号分隔);提示"请求 kind.behavior(action 默认 any)→ 系统按 CapBAC 授予" | 留空(占位 `chat.send, workspace.read`) |
| **With PTY** | 复选 | 未勾 |
| URI 预览 | 表单实时显示 | `entity://system/agent/zyli-echo-1` |
| **CONTRACT COVERAGE**(只读) | soul·skills·tools·lifecycle / executor extras → `Pending backend approval`;fork(parent template)→ `Deferred` | 见截图 |

## 执行记录(逐步)

| # | 操作 | 实际观察 | 证据 | 判定 |
|---|---|---|---|---|
| 1 | Identities → New Agent,Flavor=`echo`、Name=`zyli-echo-1`,其余留默认,点 **Create** | 表单 URI 预览 `entity://system/agent/zyli-echo-1`;contract coverage 显示 Pending backend approval / Deferred;点击创建已提交 | [s02-step1-create-form-zyli](./evidence/scenario-02/s02-step1-create-form-zyli.png) | ✅ |
| 2 | (observer)重开 `/identities` 确认新条目 | 服务端列表 8→**9 个**,末尾新增 `zyli-echo-1`(echo),URI `entity://system/agent/zyli-echo-1`,Status/Caps/API Keys 区块正常;无 pending/重复 | [s02-step2-zyli-echo-1-confirmed](./evidence/scenario-02/s02-step2-zyli-echo-1-confirmed.png) | ✅ |

## 实测结果 vs 预期

> 设计场景缺位,以下为本次执行**应当**确认的不变式(已实测):

| 应确认 | 实测 | 一致? |
|---|---|---|
| agent 创建后 world UI 列表可见,URI 正确 | observer 独立确认 `entity://system/agent/zyli-echo-1` 出现,echo flavor | ✅ |
| 写一行 `invocations`(创建动作) | 留待 scenario-12 审计收口核对真实 behavior+action | ⏳ |
| 创建即 ready(结构与其它 echo agent 一致) | 新条目区块渲染正常,无 pending | ✅(待 scenario-03 加成员实证 ready) |

## 遗留 / bug

- **设计 gap**:本流程无 `docs/scenarios` 条目。执行顺利的话,这条记录可作为新增设计场景 `docs/scenarios/04-agent-create` 的素材(交 Allen review)。
- world React 岛 form submit 被吞风险(记忆 `world_react_island_form_submit_swallowed`)——若"点了没反应"按该记忆绕过并标注。

## 证据清单

- `evidence/scenario-02/s02-baseline-agents-observed.png` — 创建前基线(8 agent)
- `evidence/scenario-02/s02-step1-create-form-zyli.png` — zyli 创建表单(字段全貌)
- `evidence/scenario-02/s02-step2-zyli-echo-1-confirmed.png` — observer 确认新增 zyli-echo-1(9 agent)

## 备注(给设计场景补缺的素材)

- **创建入口**:Identities → New Agent(`PROVISION` 区);非 Sessions 页。
- **Requested caps 半成品信号**:CONTRACT COVERAGE 显示 `Pending backend approval`(soul/skills/tools/lifecycle、executor extras)、`Fork=Deferred` —— echo 简单 flavor 可直接创建并 ready,但 cap/契约的 backend 审批链路看起来尚未完全打通,值得在创建复杂 flavor(cc/codex)时重点观察。

## 交叉引用

- 设计场景:**缺位**(候选补 `docs/scenarios/04-agent-create`)
- 相关:`docs/scenarios/30-plugin-author-behavior`(plugin/behavior 作者视角)、旧证据 `scripts/e2e_recordings/04-agent-create.png`
