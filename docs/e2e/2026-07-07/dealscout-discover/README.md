# dealscout 发现腿真浏览器 e2e（2026-07-07 凌晨）— 真爬通了，ALT 闭环在 bridge 断点如实卡住

> **注（2026-07-07 收口）**：本轮(v1)的常规流程截图已被 `../dealscout-refresh-v2/`（ALT v2 闭环终轮）取代删除；本目录保留的是 **gap 取证链**——02a（cc-headless 物化崩，#1201 ⑨）、04/04a/04b（bridge 丢弃断点，#1201 ②）、05*（D⑦ 组合会话零响应 + owner 禁言，#1201 ⑦）、06（匿名公开面，撮合面证据）。

**结论一句话**：分支 `feat/sw-dealscout` 上，冷起 → boot 自动发布 dealscout（下拉可见）→ world 装 dealscout 建 session → operator dispatch `crawl_now` **真 `:httpc` 出网抓 HN front-page，20 条真线索 + 1 条 `__dealscout_update__` 信号全部落库**，信号经 Definition routing 规则命中 `page` 槽 agent（authz granted、read_marker delivered）——但在 **AgentBridge 投递层被丢**（`native` flavor 无 adapter，`:no_sandbox_respawn_state`），ALT 的 `handle_receive` 在 live 运行时**根本没有可达路径** → 页面自动重建未发生。本轮把 5 个"单测 stub 掩盖的 live 断点"修在插件自身内（每个都先真跑撞到再修，61/61 绿），并把 4 个平台级断点如实记成 gap（零私改 hello/core/domain）。

## 环境（复跑指引）

```bash
# 1. 独立冷库（drop/create/migrate，零 seed）
POSTGRES_DB=ezagent_dealscout_e2e mise exec elixir@1.18.4-otp-27 erlang@27.3.4.13 -- \
  mix do ecto.drop, ecto.create, ecto.migrate
# 2. server（PORT=10042；admin 由 boot EZAGENT_ADMIN_PASSWORD=worlddev 供给）
#    ⚠ 要看到页面重建，必须先 export HELLO_LLM_API_KEY 或 DEEPSEEK_KEY（gap ⑨）
POSTGRES_DB=ezagent_dealscout_e2e EZAGENT_ADMIN_PASSWORD=worlddev PORT=10042 \
  mise exec elixir@1.18.4-otp-27 erlang@27.3.4.13 -- \
  elixir --name ezagent_runtime@127.0.0.1 --cookie $(cat ~/.ezagent/default/runtime/cookie) -S mix phx.server
# 3. 前置一次性：apps/ezagent_web 下 mix assets.setup && mix assets.build
#    （fresh worktree 无 node_modules → world SPA 卡 "Loading world"，app.js 404）
# 4. 登录 http://world.localhost:10042/（admin@ezagent.chat / worlddev）
# 5. 建会话：新建会话 → 应用选 DealScout → discover 槽 Flavor 手改 native（gap ⑥）→ JS click 创建（r2 gap ⑥ 同款，原生 click 不触发）
# 6. operator 触发爬取（同目录 dealscout_dispatch.exs，身份走 Entity.authenticate，CapBAC 不绕过）：
EZAGENT_USER_TOKEN=worlddev EZAGENT_ENTITY_URI="entity://system/user/admin" \
  mise exec ... -- elixir --name probe@127.0.0.1 --cookie $(cat ~/.ezagent/default/runtime/cookie) \
  dealscout_dispatch.exs "session://system/socialware-install-dealscout/<name>" "dealscout_crawl.crawl_now" '{}'
# 清理：kill $(cat /tmp/dealscout-e2e/server.pid)；pkill vite 孤儿；agent-browser close
```

工具链 mise 显式 pin `elixir@1.18.4-otp-27 erlang@27.3.4.13`；浏览器 agent-browser 真 Chrome。

## 步骤与判定（各步真跑程度逐条如实）

| 步 | 判定 | 证据 |
|---|---|---|
| 1 冷起+登录+boot 自动发布 | ✅ 冷库 0 会话；应用下拉可见 "DealScout"（boot `Demo.publish` 真 governance，`{:ok,:upgraded}` 于本轮 manifest 修正后） | `01-login-dealscout-in-dropdown.png` |
| 2 装 dealscout 建 session | ✅（**flavor 手改后**）3 成员=admin+discover+page，page 槽物化出 ALT native agent（成员面板 2 个"智能体"）；**stock cc-headless 建会话崩**（gap ⑥，`02a` 截图）；首次失败的同名重建会丢 routing rule（gap ⑦，第二个会话换名才装上规则） | `02-session-created-members3.png`、`02a-stock-ccheadless-configdir-gap.png` |
| 3 真爬 | ✅ **不配 source、纯公开腿、真 `:httpc` 出网**（HN Algolia front_page）：`{:ok, %{injected: 20}}`；DB messages 21 行（20 条真实 HN 线索 + 1 条 `__dealscout_update__ 新线索 20 条（crawl）`）；chat 流可见 | `03-crawl-dispatch-result.txt`、`03-crawl-leads-in-chat.png`、`03b-update-signal-in-chat.png` |
| 4 ALT 闭环 | 🟥 **链路走到 bridge 断点**：信号 routed_at 非空 → `dealscout-update` 规则（`$role:cGFnZQ`=page）命中 → page agent `agent.receive` **authz granted** + read_marker `delivered` —— 但 `AgentBridge deliver dropped ... :no_sandbox_respawn_state`（native 无 adapter，gap ⑧）→ ALT `handle_receive` 未运行 → 页面未重建（`04a`/`04b` 前后一致="还没有页面"）。**未硬闯**（可选 hack 都要动 domain/hello） | `04-routing-evidence.txt`、`04a-page-before-crawl.png`、`04b-page-after-crawl-unchanged.png` |
| 5 D⑦ 探针 | 🟥 **不通（对 dealscout 组合会话）**：owner 发零 mention 消息 → 落库+已路由，但 invocations 审计只有 send+snapshot、**零 agent.receive**，40s+ 无任何响应。公开面对已登录 owner 也禁言（`05a`）。详见 `05-d7-probe.txt` | `05-d7-no-mention-no-responder.png`、`05-d7-probe.txt`、`05a-public-face-owner-cannot-participate.png` |
| 6 撮合面初验 | ✅ 清 cookie 匿名访客开公开页（`/socialware/chat?session_uri=…`）**可见全部真爬线索流**（web_anon_access: true 生效）；无 cookie curl 200 | `06-anon-public-page.png` |
| 7 清理 | ✅ server 按 PID kill、vite 孤儿清（10042/5173 双 clear）、agent-browser close、beam 0 残留 | — |

## 本轮修在插件内的 5 个 live 断点（全部是"单测 stub 掩盖、真跑才炸"，先撞到再修，TDD 补测）

1. **默认公开源形状错**：原 `topstories.json` 返回**整数 id 数组**，真出网 `Fetch.to_item/2` FunctionClauseError 把 Poller 30s 崩一次（boot 日志实锤）。改指 HN Algolia front_page（真实条目对象），`parse_items/2` 支持 `{"hits":[...]}` envelope + 非 map 条目丢弃 + null url 回落讨论页（`fetch.ex`）。
2. **`crawl_now` 无 live 宿主**：handler 读 `ctx.session_uri`（仅 session:// 目标派生）+ session config slice → 宿主必须是 session 本体，但 manifest shape 没带 `DealScoutCrawl` → 真 dispatch `{:unknown_action}`（发现腿 recipe 的 `requested_caps` 只管 caller 持权，不装 handler）。shape 补 `DealScoutCrawl`（`demo.ex`，boot `:upgraded` 重发布）。
3. **dispatch 函数用错**：构造的是 `%Ezagent.Invocation{}` 却打给只收 `%Cmd{}` 的 `Ezagent.Router.dispatch/1` → FunctionClauseError。改 P14 legacy 路 `Ezagent.Invocation.dispatch/1`（hello `TurnDriver` 同款）。
4. **内层 send 掉身份**：`ctx: %{reply: :ignore}` 无 caller/caps → 20 条注入全部 fire-and-forget `:unauthorized`（只有日志能看见，injected 计数还是 20——cast 接受即计数的语义注意）。改为透传外层触发者 caller/caps（CapBAC 不绕过：触发者没 send cap 照样被拒）。
5. **send args 契约错**：`%{body: text}` 被 validate_args 拒（`session.send` 要 `%{message: %Ezagent.Message{}}`）。改 `Ezagent.Message.new(sender, %{text:, attachments: []})`，sender=触发者、无身份回落 session 本体。

修后 per-app 套件 **61 tests, 0 failures**（新增：Algolia envelope/id 数组两测、caller/caps 透传测、demo shape 含 DealScoutCrawl 断言）。

## gap 清单——还有什么断的（平台级，本轮零私改，等认领）

| # | gap | 层 | 现象/根因 | 建议 |
|---|---|---|---|---|
| ⑥ | **cc-headless 角色槽物化必崩** | core | `FsResolver.Registry` 的 config-dir 目录 catalog 只注册 `["cc","codex","codex-remote","py"]`（`fs_resolver/registry.ex:386`），而 `Ezagent.Template.CcHeadlessAgent.config_dir_namespace/0`="cc-headless" → `resolve` `:none` → 建会话 `config-dir resolution failed ... :none`（`02a` 截图）。stock dealscout（discover=cc-headless）**装不出来**，本轮建会话时把槽 Flavor 手改 native 才通 | catalog 补 "cc-headless"（或从 AgentFlavorRegistry 派生），加 cc-headless×role 物化回归测 |
| ⑦ | **建会话失败的 rollback 不对称** | domain | 首次(cc-headless)失败回滚删了 routing_rules（created_by=session）但**留下 install config pointer** → 同名重建判"已装"跳过规则安装 → `__dealscout_update__` 规则静默缺失（第一个会话 `dealscout-e2e` 实锤：库里 0 条 dealscout-update 规则）。换名 `dealscout-e2e-r2` 走全新 install 才有规则 | rollback 一并清 install pointer/object，或重建时按 content_hash 重放规则 |
| ⑧ | **ALT 闭环的真正断点：native flavor 收不到 chat**（本 e2e 最重要发现） | 架构 | `Agent.Receive` 是 `{Agent,:receive}` 的 canonical 注册（RF-1 registry-first，recipe 行为**永远不能** shadow），它把 chat 交给 per-flavor AgentBridge adapter；`native` 无 adapter → `deliver dropped :no_sandbox_respawn_state`（hello `BridgeAdapter` moduledoc 原话明说此事）。所以 **ALT（`dealscout-page-alt`×native）的 `handle_receive` 在 live 没有可达路径**——前一步的 ALT 设计前提被 live 打破（其单测直调 handler 掩盖）。且 **A①（hello builder `from_user?` 门放行）单独落地也不够**：`hello.builder` 槽同样是 native，同样收不到 fan-out——hello 自己的 builder 是靠 `"hello"` flavor 的 orchestrator 收 chat 后命令式驱动的，不走路由投递。插件自注册 flavor 也堵死：`sync_result_action/1` 硬编码 cc-headless/py/hello，其余落到 curl 全局认领的 `:sync_result` | 两条路等 Allen 裁决：(a) 信号 receiver 槽改挂有 adapter 的 flavor（如 `"hello"`，orchestrator 收信号 → intent → builder 生成——LLM 依赖）；(b) 给"native 角色 agent 的 per-instance 行为 :receive"开一条 core/domain 通路（或 `sync_result_action` 改为 flavor 注册制），ALT 才能按原设计工作 |
| ⑨ | **hello 生成需要 LLM key** | 环境 | `Generator` 只认 env `HELLO_LLM_API_KEY`/`DEEPSEEK_KEY`（`generator.ex:820`），本 run server env 没有（项目文档 world-ui-polish-1149.md 已注明该前置）→ 即使 ⑧ 打通，页面重建也会 `:no_api_key`。**未借用其它分支 .env 的 key**（权限裁定不属于本用途，尊重） | 复跑前 operator 显式提供 key；或 key 进 `system://credentials`（generator.ex 注 "follow-up"） |
| ⑩ | 公开面对已登录 owner 禁言 | web | `/socialware/chat` 对已登录 admin 仍显示禁用的"登录后参与"，点登录回跳后依旧（`05a`）——owner 无法从公开面参与，撮合面"登录自助 join+发言"这半边不通 | ChatFeedAuth/AnonIngress 对 signed-in member 的 principal 恢复排查 |
| ⑪ | D⑦：dealscout 会话 owner 普通聊天零响应 | 产品/配置 | dealscout Definition 刻意只带信号规则（不带 hello 的 always→chat，红线正确），但 hello 的 orch_<name> 只给 hello 自己的 app 会话命令式 ensure → dealscout 组合会话里 owner 的普通消息没有任何 agent 接（`05-d7-probe.txt` 全量审计证据）。Stage F 撮合腿的 concierge 回帖前提不存在 | dealscout manifest 增补 concierge/orchestrator 槽（挂有 adapter 的 flavor），或 create_session 流对 `uses: hello` 的组合会话补 ensure |
| ⑫ | 观察项 | web | world 会话内 "Page" tab 点击后内容区不切换（仍对话流，kanban r2 gap ⑦ 同款）；`injected` 计数=cast 接受数而非落库确认数（第一轮 20 条全 :unauthorized 但仍返回 20，靠 fail-loud 日志兜底） | 顺手项，低优先 |

## ALT 说明与删除条件（更新）

`Ezagent.ActionSet.DealScoutPageRefreshAlt` + recipe `dealscout-page-alt` + Demo page 槽指向，仍为**显式临时 ALT**。原删除条件"A①（#1201 ③）落地后整体删除、槽回切 `hello.builder`"经本轮 live 验证**不充分**：A① 只放行 `from_user?` 门，而 gap ⑧ 证明 native 角色 agent 的 `:receive` 从 bridge 层就到不了任何 recipe 行为（HelloBuilder 同病）。**新删除条件：gap ⑧ 的裁决路径落地（受体槽换有 adapter 的 flavor 或 core 开 native-receive 通路）后，随裁决一并删除/替换本 ALT**。ALT 模块本身逻辑（标记门/摘要提取/`page_refresh_fun` seam）单测 5/5 仍绿，问题不在模块在通路。

## 证据文件

`01`…`06` 截图 + `03-crawl-dispatch-result.txt`（dispatch 返回）+ `04-routing-evidence.txt`（规则行/delivered 标记/bridge drop 日志）+ `05-d7-probe.txt`（D⑦ 全量审计）+ `dealscout_dispatch.exs`（operator 代面脚本，kanban r2 同机制，token 走环境变量不进提交物）。
