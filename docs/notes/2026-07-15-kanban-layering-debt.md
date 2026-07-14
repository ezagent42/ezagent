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
