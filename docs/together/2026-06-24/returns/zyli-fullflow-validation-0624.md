# Return: full-flow human validation — @李震宇 (zyli)

> **Date:** 2026-06-24 · **Track:** `zyli-fullflow-validation-0624`(validation-only)
> **Base:** `origin/main` @ `cd0d4067` · **Driver:** @李震宇(人肉 UI/UX)· **Assist:** Claude(环境/日志/命令)
> **Status:** 7 腿全部走完(能跑的跑通、跑不通的根因定位+路由)。**14 findings(F1–F14)+ 2 环境项**,13 个 `fix/*` 占位分支全部路由 owner。
> **证据目录:** `docs/together/2026-06-24/evidence/`(本文 = 汇总;逐条 blocker 见 `evidence/blockers.md`)

## 0. 头条结论
- **06-23 的核心阻塞已修复**:操作员会话 **send no-op + 路由 Add no-op 都不再卡** —— echo agent 在 world UI 会话里**真回了消息**,UI 路由规则 Add **真生效**(F14 过程反证)。
- **能跑通的腿**:L1 登录、L2 建 agent(全 5 flavor)、L5 protocol-api /v1(含 curl→DeepSeek 真回复)、L7 customer 公开视图、L6 接力路由逻辑(deterministic 8 绿)。
- **被环境/产品缺口阻塞的**:L3/L4 飞书闭环最后一跳、L4/L6 的真 cc/codex agent(F5/F7)。**飞书 inbound 管道每段都验证可工作**(靠 DB workaround),缺的是几个把它们串起来的 UI/路由能力。

## 1. 环境(本次拉起)
- Host PG `127.0.0.1:5432/ezagent_pg_compat_dev`:deps.get + migrate + core/world seed。
- `mix phx.server` 活跑 `:10042`(+ vite `:5173`),`world.localhost:10042` 操作台。
- **codex CLI 本次安装**:`npm i -g @openai/codex`(0.142.0)+ 预热 uv 缓存(ENV-2)→ codex 创建链路转绿。
- admin:`admin@ezagent.chat` / `worlddev`。

## 2. 七腿结果

| Leg | 结果 | 关键证据 |
|---|---|---|
| **L1** 注册→登录→world UI | ✅ PASS(经 `world.localhost`)| `L1A-*.png` / `L1c-world-ui.png` |
| **L2** 建 workspace+agent(#905)| ✅ PASS(echo/curl/np/codex 创建成功;cc 空CWD 必填拦截=06-23bug已修;cc+PTY=F5;codex 装好后转绿)| `agent-list.png` / `test-*-agent-detail.png` |
| **L3** 绑 Feishu 群 + inbound 到达 | 🟡 inbound 到达✅ + user 绑定✅ + 群绑定(DB)✅;绑群 UI 缺=F9 | 日志 `Feishu inbound … bound` |
| **L4** cc @提及往返 | 🟡 管道深验到「消息进绑定会话」全通;卡 session→agent 路由(F12);cc=F5 | 日志 `mentions:[] + session.send granted` |
| **L5** codex/curl + protocol-api /v1 | ✅ PASS(echo 活 :10042;**curl→DeepSeek 真回复** `"你好…"`)| `L5-protocol-api-v1-echo.md` |
| **L6** 多 agent 接力(scenario-34)| 🟢 接力路由逻辑 PASS(deterministic 8 绿)+ live echo 单跳(UI 路由+echo 回复)✅;真 cc→codex→curl=F5/F7 | `L6-multiagent-relay-scenario34.md` |
| **L7** world 渲染 + customer 公开视图 | ✅ PASS(world 各页渲染;customer 公开视图无登录 200 渲染,public_view 模板闸门生效)| `L7-world-render-customer-public.md` / `public-socialware.png` |

## 3. Findings + 路由(摘要;详见 `evidence/blockers.md`)

| # | 严重度 | 一句话 | Owner | `fix/` 占位 |
|---|---|---|---|---|
| F1 | minor | 裸 `localhost/login` 登录后跳 `/sessions`→404(路由仅挂 world host)| @林懿伦 | `login-redirect-404-on-bare-host` |
| F2 | low/观察 | 自助注册即 `email_verified:true`、未点链接即可登 | @林懿伦 | `self-register-email-verified-bypass` |
| F3 | medium | world UI 无登出/切号入口 | **@李震宇**(world UI)| `world-ui-no-logout` |
| F4 | minor | agent detail Phase 显示 `unknown`(Flavor 已修)| @戴明/@黄佳佳 | `agent-detail-phase-unknown` |
| F5 | medium | cc 创建 `sandbox_write_path :activate_timeout`(claude 在场)| @黄佳佳/core Sandbox | `cc-create-sandbox-activate-timeout` |
| F6 | high | create_agent 慢启动超 5s → **LiveView 崩溃**(复现 06-23§7)| @林懿伦 | `create-agent-5s-timeout-crashes-liveview` |
| F7 | medium | codex TUI 崩溃(67GB alloc/SIGABRT)+ 需 `codex login` | 上游 codex + env | —(暂不路由 ezagent)|
| F8 | low | 飞书 ack 表情 THUMBSDOWN 被 API 拒(231001)| @林懿伦(feishu)| `feishu-react-thumbsdown-invalid` |
| F9 | high | **无 UI 把飞书 chat 绑到 session** | **@李震宇**(world UI)+@林懿伦 | `no-ui-bind-feishu-chat-to-session` |
| F10 | high | **无 UI 给 agent 加 API key** | **@李震宇**(world UI)+@黄佳佳 | `no-ui-add-agent-api-key` |
| F11 | medium | 重启后 codex agent 重连风暴 `:already_bound` + 孤儿进程增殖 | @黄佳佳/core PtyServer | `codex-rebind-storm-on-restart` |
| F12 | high | 飞书 @提及未路由到 agent(mentions:[] + 会话无路由规则)| @林懿伦/@张宁 | `feishu-mention-route-to-agent` |
| F13 | medium | anon `/socialware/chat` 无 composer(后端 anon 流程已通)| **@李震宇**(socialware 前端)| `anon-chat-composer-missing` |
| F14 | high | `Always` 路由规则**自环** + UI Disable 不停 live 循环 | @林懿伦(循环防护)+@李震宇(UI Disable)| `always-rule-self-loop-and-disable-noop` |

**环境项(非产品 bug)**:ENV-1 codex CLI 未装(已装解决);ENV-2 codex sidecar 依赖经 uv 从 pypi 拉、不走代理(预热缓存绕过)。

## 4. Owner 分布速览
- **@林懿伦**(core/routing/web):F1、F2、F6、F8、F12(共建)、F14(共建)
- **@黄佳佳**(cc/agent-config 后端):F5、F11、F10(共建)、F4(共建)
- **@李震宇 本人**(world/socialware 前端,本人开发):**F3、F9、F10、F13、F14(UI Disable 部分)**
- **@戴明**(console 前端):F4(共建)
- **@张宁**(world 渲染):F12(共建)

## 5. 给各 owner 的复跑提示
- **F5/F7 修好后** → L4 真 cc @提及往返、L6 真 cc→codex→curl 接力 可在全 agent 环境复跑(live tier:`SCENARIO_34_LIVE=1`)。
- **F9+F10+F12 修好后** → 飞书群→agent 回复操作员闭环可端到端走通(本次已用 DB workaround 验证底层每段)。
- **F6/F14 是 high 防御缺口**(慢 spawn 崩 LiveView / Always 自环刷量),建议优先。

## 6. 纪律说明
全程 validation-only:不改任何 `apps/**` 产品代码;仅写 `docs/together/2026-06-24/evidence/` + 开 `fix/*` 占位分支(只带 branch description,无 diff)。为继续测试在**用户授权下**做过几处 DB 写入(配 key / 绑群 / 加规则)+ 2 次重启,均为绕过 UI 缺口验证底层管道,非产品改动。
