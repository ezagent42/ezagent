# kanban 改版分层债 + gap3 平台缺口（#1374/#1376 过渡照现状交，永久修交 Allen 线）

真机 e2e review（2026-07-15）暴露 4 处「够得到所需 API 的层 ≠ 该拥有这逻辑的层」——业务被塞进 infra/UI/transport 层。#1374/#1376 作**过渡**照现状落地；干净修法都要动分层/平台，与 Allen 的永久 Entity 双向-caps 模型（#1394）是一条线。

## ① BoardProvision = kanban 业务在 domain 层
- **现状**：`apps/ezagent_domain_session/lib/ezagent/socialware/board_provision.ex` —— 带 kanban 字面（`board` / `kanban-assistant` role / `[:get_tree,:export_markmap]`），却在 domain_session。
- **为什么**：直调 `Ezagent.Workspace.create_agent`（domain_workspace）+ `Ezagent.Socialware.Mount`（domain_session）等**域 API**；kanban plugin 在域之上够不到，塞进 domain_session 才有访问权。
- **干净修**：kanban plugin 自己拥有建板 glue，**走 dispatch**（P14：dispatch 建-agent + mount 动作），domain_session 只留通用 `Mount`。前置 = **`Mount` 变成可 dispatch 的动作**（现是直调 API）。→ Allen 永久模型。

## ② kanban view 在 world_plugin
- **现状**：`apps/ezagent_plugin_world/lib/ezagent/world/{kanban_data,kanban_actions,conversation_data}.ex` + `assets/src/components/Kanban.tsx` —— kanban UI/数据/动作在 world，不在 kanban plugin（`kanban_render.ex` 在 kanban plugin）。大部分**既有**，本次 T6 顺着扩。
- **为什么**：world_plugin 是 session UI 宿主（React app / Conversation / plugin-page-registry / world:dispatch），托管所有 plugin UI。
- **干净修**：kanban plugin 自包含自己的 view，world 只做 UI 壳/挂载点（需 plugin-UI 注册机制让 plugin 贡献 React 组件 + 数据 reader，而非 world 内置 kanban 细节）。

## ③ share/接收业务在 web controller
- **现状**：`apps/ezagent_web/lib/ezagent_web/controllers/socialware/kanban_share_controller.ex` —— controller 里做了业务（解析接收者 session + `Mount.mount`），不只 transport。
- **为什么**：接收是 web 路由（点链接=HTTP）→ Phoenix controller 合理；但业务塞进了传输层，违反 **P13（Phoenix 是 transport 不是 fullstack）**。
- **干净修**：controller 变**薄** —— verify token 后 **dispatch 一个 kanban plugin 的「receive shared board」动作**，接收者-session 解析 + mount 在 plugin/域做。**这条不动平台就能搬**（controller→薄 dispatch + kanban plugin 加 receive 动作）。

## ④ gap3：cc-headless 没把 recipe-prompt/skill/工具桥送进 cc turn（chat 中心 operate 卡这）
机制全通（助手有 cap 时 dispatch `kanban.get_tree` 成功；cap→dispatch→manager per-node 过滤 都在）。卡在 cc-plugin spawn 接线 3 个 code gap：
- recipe `system_prompt` 没 thread 进 sidecar turn：`apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_agent.ex:268`（取值空）+ `sdk_sidecar.ex:264`（sidecar env 无 `EZAGENT_CC_SDK_SYSTEM_PROMPT`）。
- skill 没加载：`apps/ezagent_plugin_cc/priv/python/ezagent_cc_sdk_worker.py:99-108` `setting_sources=[]`；助手 cwd 无 `scripts/`，相对路径 resolve 不到。
- 助手 cwd `.mcp.json` 桥指向**已删 worktree** `worktrees/sw-kanban/.../ezagent_mcp_bridge.py` → esr-bridge MCP 起不来 → 零看板工具。
- **归属**：cc-plugin（MCP/cc-dispatch 规范化线，Allen/gaga）。非 kanban 业务、非 recipe/skill config（recipe 文本对，没被送进 turn）。

## 共同根因
平台没给 plugin 干净的路（plugin 够不到域 API / world 托管 UI / HTTP 落 controller / cc-headless 不 thread prompt·skill）→ 业务被塞进 infra·UI·transport·cc 层。**③ 不动平台可先搬；①②④要动分层/平台，交永久线。**

## ⑤ 测试发现的功能 bug:装 kanban 后 owner 看不到看板 tab(render cap 没授登录用户)
- **现象**:普通用户(owner,非 admin)建 session 选 kanban → **看不到「看板」tab**;admin 能看(wildcard 绕过 cap)。
- **根因**:看板 tab(`BoardView` SessionView)门控 cap = `cap(:session, Ezagent.ActionSet.KanbanRender, :kanban_render, session_instance, workspace)`(`kanban_render.ex:51 required_caps`)。session 安装时,这个 view render cap **只经 `installation.ex:307 anon_view_caps` 给匿名访客铸**(web_anon_access 的 public 视图),**没给登录的 installer/owner 和成员**。→ owner 无此 cap → tab 隐藏。
- **修法**:session 安装时,给 installer/owner(和成员)也授 declared views 的 render cap(照 `anon_view_caps` 的 `view_render_caps` 逻辑,granter=owner/admin,走 Cap.issue)。归属:socialware 安装的 view-cap 授权(domain_session installation),平台侧。
- **临时**:后台给测试用户手工铸 render cap 让测试继续(非产品修复)。

## ⑥ installer/owner 没拿到 `create_agent` cap → UI 建不了板(与 ⑤ 同类)
- **现象**:owner 在看板 tab 填「新导图名」点「+」→ 无反应、板没建。
- **根因**:UI「建导图」dispatch `kanban.create` → `create_kanban`(kanban_actions.ex)→ `workspace.create_agent`(建 kanban-manager board agent),需 `cap(:workspace, Workspace, :create_agent)`。owner(installer)**没这个 cap**(日志 `create_agent` authz=`denied :unauthorized`)。
- **根因同 ⑤**:session 安装只给 owner session 管理 cap,没给「用 kanban 所需的 cap」(create_agent 建板 + kanban_render 看 tab)。
- **修法**:session 安装时给 installer/owner 授建板所需 cap(scoped `create_agent`,或让 UI 建板走 BoardProvision 用 owner 授权路)。归属:socialware 安装的 owner-cap 授权(domain_session)。

## ⑦ board owner 建不了根节点(建根硬要 admin wildcard,不认 board owner)
- **现象**:board owner 在自己建的板上「建根节点」→「无权限,需 admin」。
- **根因**:`kanban.ex:265` `parent_id == nil and not admin?(ctx) -> {:error, :forbidden}`;`admin?(ctx)`(`kanban/shared.ex:156`)**只认 `%Capability{kind: :any}` wildcard = 全局 admin**,不认 board 的 data_owner。→ board owner(非 admin,只持 board instance-precise operate cap)建不了根。
- **矛盾**:与「owner 可编辑所有节点」模型冲突(用户 2026-07-14 定的规则)。owner 应能建根 + 全编。
- **修法**:建根授权改 `admin?(ctx) or caller == board data_owner`(handler 里 `Kanban.data_owner(instance(self))` 拿 board owner 比对 ctx.caller)。归属:kanban 业务(kanban plugin,我范围)。

## ⑧【真根因·统一 ⑤⑥⑦】owner 建板只拿到 `Manage` cap,没拿到 `Kanban` operate cap → 读/写自己的板全 unauthorized
- **现象**:owner 刷 testboard 看板 tab **一片空**(连后台以 admin 建好的根节点都看不到)。
- **诊断**:owner 在 `entity://system/agent/testboard` 上持的 cap = `%Capability{kind: :agent, behavior: Ezagent.ActionSet.Manage, action: :any}`(agent 生命周期:terminate/destroy)。而 `kanban.get_tree`/`add_node` 要的是 `behavior: Ezagent.ActionSet.Kanban`(required_caps kanban.ex:220,kind `:any` 运行时替 `:agent`)。**behavior 轴对不上**(Manage ≠ Kanban,都非 `:any`)→ owner 的 `get_tree` dispatch = `{:error, :unauthorized}` → UI 读回空树(fail-safe)。
- **统一根因**:`Workspace.create_agent` 给建者铸的是 **Manage**(管 agent),没铸 **Kanban operate cap**(操作看板 = `cap(:agent, Kanban, :any, board)`,正是 #1376 mount cap 的形)。所以 owner 能「管」这个 agent(销毁),却不能「用」这块看板(读/加/改节点)。⑤(看 tab 的 session render cap)/⑥(建板的 workspace create_agent cap)/⑦(建根 admin-gate)+ 本条(板级 operate cap)= 四个各自独立缺失的 cap,统一症状「owner 拿不到用自己 kanban 所需的 cap」。
- **修法**:装 kanban / chat 建板后,给 owner(和 assistant「手」)铸指向该 board 的 Kanban operate cap(走 #1376 `Mount.mount`/`CompositionCaps.mint_cap`,granter=板主人)。这正是 #1374 chat-建板要接的「发钥匙」动作(plan 第 3 件)——当前 UI 建板走的老 `create_kanban` 只 create_agent+Manage,漏了铸 operate cap。归属:kanban 建板业务(#1374)+ mount infra(#1376)。
