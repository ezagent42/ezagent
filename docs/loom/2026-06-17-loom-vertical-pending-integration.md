# Loom Vertical — 预留接入清单（待用户/外部补齐）

> 日期：2026-06-17 ｜ 分支：`feat/loom-vertical`（PR #810）
>
> 7 项剩余功能已全部开发到「此环境能做的极限」：能完整实现+验证的已实现（Stitch 4 sub-worker、
> meta agent、SW-DEV/UPD E2E、AiSpot、knowledge、tool-fetch、Dashboard 后端、user_schema）。
> 下面 4 项依赖**外部资源 / main 架构决策 / 浏览器工具**——已**预留接口/桩 + 标注接入点**，
> 等对应资源到位即可接通。每项标注：现状、需补什么、接入点。

---

## 1. 飞书 ExternalMirror 镜像

- **现状**：预留桩 `EzagentPluginLoom.FeishuMirror`（`configured?`/`bind`/`bound_chat`/`mirror`），
  未配置凭证时 graceful no-op，不影响主链路。51 tests 含桩行为测试。
- **需你补**：
  1. 飞书凭证：`FEISHU_BOT_TOKEN` + 目标群 `chat_id`
  2. 真实投递接通：`FeishuMirror.mirror/2` 的 TODO → 走 main `ezagent_domain_external_mirror`
     的 `ExternalMirror.bind/4` + `ezagent_plugin_feishu` adapter
- **需 main 配合**：`ExternalMirror.bind` 对 caller resolve 飞书 open_id；loom 的 system/anon
  caller 无飞书身份（旧 loom 是绕 facade 直写 BindingRow 的 hack）——需 main 给「系统级 operator
  平面镜像」caller 豁免；customer-visible 镜像还需 main 补 `ExternalMirror` visibility filter（spec §4.3 待做）。
- **接入点**：`apps/ezagent_plugin_loom/lib/ezagent_plugin_loom/feishu_mirror.ex`（moduledoc 待接入 §1-4）

## 2. 前端 SPA / Dashboard operator UI ✅ 已浏览器验证

- **现状**：**后端就绪 + 浏览器内交互 E2E 已通过**。customer SPA（`/loom/app/:ws/:sid`）经真实
  Chrome（agent-browser CLI）验证：发消息 → 真实多 agent LLM 编排 → Turn（`mode:auto` settle）→
  feed 出页面 → SPA `renderNode` 渲成 DOM（page/services/detail/notice/choices 节点正确）。
  截图见 session（headless Chrome 缺 CJK 字体，文字显示为方块，非代码问题）。
- **本 session 修复的 bug**：SPA 从 query 读 `ws/sid`，但 URL 把它们放在 **path**
  （`/loom/app/:ws/:sid`），导致 POST/feed 命中 `/c/null/null/*` → 401。已改为从 `location.pathname`
  正则提取（`customer_spa.ex` / `dashboard_spa.ex`，query 兜底兼容）。
- **可选演进（非阻塞）**：生产可换 socialware `customer_app.js` + `json_render.mjs`（#732），operator
  Dashboard UI 读 `Dashboard.summary/1` 渲 HEEx PageView。当前 loom 自包含 vanilla-JS 壳已端到端可用。
- **dev 工具**：`mix loom.serve`（put_env server:true → seed demo session → 打印 customer URL/token，
  供浏览器 E2E）。

## 3. 真实 agent Kind fan-out（编排 + Stitch）

- **现状**：**务实版功能完整且 live 验证**——编排进程内 `decompose → 并发 worker → compose`、Stitch
  `route → 4-role fan-out → compose`，真实 LLM 端到端通。
- **需 main 架构决策（Allen）**：把编排进程/角色 worker 升级为正规 socialware **agent Kind**
  （`turn.dispatch`→`chat.send`→worker agent→`turn.deliver` 的真实 fan-out）。障碍：socialware agent 框架
  是「LLM 对话 transport」模型（agent.receive → AgentBridge → flavor adapter），loom orchestrator 是
  「编排控制器」，框架内无现成落位——需 Allen 拍「编排控制器型 agent 怎么在 socialware 落位」。
- **接入点**：`orchestrator.ex` / `orchestrator_server.ex` / `stitch_experts.ex`（务实实现，注释已标）。
  功能上无缺口；标准化是架构演进，非功能阻塞。

## 4. cc-flavor PTY（claude 二进制）

- **现状**：LLM 调用走 `EzagentPluginLoom.LLM`（`:httpc` anthropic-兼容端点，`ANTHROPIC_BASE_URL`/
  `ANTHROPIC_API_KEY`，curl-flavor 等价路径），live 验证通。
- **需补（可选，等价替换价值低）**：若要文档原 cc-flavor PTY（claude 二进制长驻进程）——它依赖项 3
  的真实 agent Kind 化（cc-flavor 是 agent flavor）。当前 `ANTHROPIC_BASE_URL` 已可指向任意
  anthropic-兼容后端（含 claude），功能等价；cc-flavor PTY 主要差异是「常驻进程跨轮上下文」
  （loom 当前 stateless per-turn，prompt 按此设计）。
- **接入点**：`llm.ex`（端点可配）；真实 cc-flavor 随项 3 一起。

---

## 汇总

| 项 | 状态 | 阻塞 |
|---|---|---|
| 飞书镜像 | 预留桩 + 测试 | 飞书凭证 + main facade caller 豁免 |
| 前端 / Dashboard UI | ✅ 浏览器 E2E 已通过 | （无；可选换 socialware 渲染器） |
| 真实 agent Kind fan-out | 务实版 live 验证 | Allen 架构决策 |
| cc-flavor PTY | curl 等价已通 | 依赖项 3 + 价值低 |

**功能上**：customer 端到端体验（对话→多 agent 编排→页面→feed→Stitch/AiSpot/intent/team/素材/知识/
增强/工具/发布 fork）全部可工作，前端已在真实浏览器验证。**仍待外部的只剩**：飞书外发（需凭证）、
真实 agent Kind 标准化（Allen 架构决策）、cc-flavor PTY（随 agent 标准化、价值低）。均已预留接入点。
