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

> 2026-07-02 当前 World UI 备注:`project_cwd` 已不是可手写字符串的输入框,而是两张选择卡片。默认卡片为“使用系统默认目录（推荐）”,自定义卡片为“使用自定义项目目录”且当前禁用。新的执行记录见 [`world-scenario-02-create-agent.md`](./world-scenario-02-create-agent.md)。

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

---

## 自动化运行(agent-browser runbook)

<!-- 规范见 guide.md §8。**本节 2026-06-26 由 agent-browser 实地跑通验证**。New Agent 表单是 React 岛:字段无 id/name 靠 placeholder;native-setter 填值 + requestSubmit 提交;结果看 #world-root 的 data-last-dispatch。 -->

**前置(自动化)**:scenario-01 已自动跑(admin 已登录,workspace 选择器 = `workspace://system`)。
**入口 URL**:`http://world.localhost:10042/identities/agents/new`(**直达表单子视图** —— 实地核实:`/identities` 默认不渲染表单,New Agent 是 `link` href=`/identities/agents/new`,导航过去 `#world-root` 的 `data-world-component=agent_new_form`)。
**自建实体**:`e2e-native`(**`native` flavor**)。
> **flavor 实地核实(2026-06-26)**:下拉选项 `[cc, cc-headless, codex, codex-remote, curl, hello_builder, native, np, py]`,**echo 已退役并入 py**(#1011)。**但 `py` 从表单建会 `error:missing_script`**(表单不提供脚本入口);零配置可建的是 `native`/`np`/`hello_builder`。**这些零配置 flavor 不回显聊天**——会回显的是 seeded `py_default`(py+echo.py,逐字)。故本 scenario 建 `e2e-native` 证明创建链路;下游 04 往返用 `py_default`。**「表单建不出可对话 agent」记为产品缺口**(见 `notes/` 或 UI 清单)。

| # | 动作 | 定位 / 方法 | 输入 | 断言 | evidence |
|---|---|---|---|---|---|
| 1 | navigate `/identities/agents/new` | wait `form#world-agent-new-form` + settle | — | `visible form#world-agent-new-form` | `s02-step1-create-form-auto.png` ✅ |
| 2 | select(flavor,native-setter+change) | `form#world-agent-new-form select`(首个) | `native` | — | — |
| 3 | fill(name,native-setter+input) | `form#world-agent-new-form input[placeholder*="storefront-greeter"]` | `e2e-native` | `text~ form#world-agent-new-form "entity://system/agent/e2e-native"`(URI 实时预览,**实地✅**) | `s02-step3-uri-preview-auto.png` ✅ |
| 4 | submit `form.requestSubmit(btn)` | `form#world-agent-new-form button[type=submit]` | — | **`attr #world-root data-last-dispatch=idle`** 且 `url~ /identities/agents/entity%3A`(成功跳转 agent 详情页,**实地✅**) | — |
| 5 | navigate(确认) | `/identities/agents` | — | `attr #world-root data-world-component=agents_table` | — |
| 6 | wait + assert | `#world-root`(agents 列表是 `link`+StaticText URI) | — | `text~ #world-root "entity://system/agent/e2e-native"` | `s02-step6-agent-confirmed-auto.png` |

**断言映射**:
- 「agent 创建后 world UI 列表可见,URI 正确」→ step3 URI 预览 + step4 跳转详情页(`data-last-dispatch=idle`)+ step6 列表含 URI。
- 「创建即 ready」→ step4 跳转成功 = 后端接受;ready 强证据留 scenario-03 加成员见绿点。
- 「写一行 `invocations`(创建动作)」→ 非 UI,留 scenario-12 审计。

**清理**:删除 `e2e-native`(`/identities/agents` → 条目 → delete,或重置 DB 重 seed)。

> **flavor drift(交 lead/Allen)**:人肉记录(2026-06-25)用 `echo` flavor + `echo:` 前缀;当前 main 退役 echo→py,py `echo.py` **逐字回显(无前缀)**。runbook 跟随当前 main,人肉记录保留为历史真相。下游 04/08 回复断言按逐字。
