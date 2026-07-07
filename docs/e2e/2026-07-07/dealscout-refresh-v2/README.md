# dealscout "爬完→页面自动刷新" v2 复验（2026-07-07）— ALT caller-dispatch 式闭环打通（LLM 段 seam 代跑，如实标注）

> 精简注记：页面前后对比保留 03a(前) vs 03c(后,外部渲染)一对；03b/03d 为同一事实的重复角度已删。

**结论一句话**：分支 `feat/sw-dealscout`（ALT v2 commit `9b36d3b`）上，冷起独立库 → 装 dealscout（3 成员）→ 真爬 HN Algolia 20 条落库 → crawl 完成**自动 dispatch `refresh_page`**（`:call`、authz granted、invocations 审计三行实锤）→ ALT handler 真跑（日志）→ 生成入口被调 → **真 TurnDriver turn-1 settle → Surface approved → 真浏览器渲出重建页面**（`/socialware/external`）。v1 卡死的 bridge 断点（gap ⑧）被 v2 caller-dispatch 腿**绕过成功**；但撞出一个**新平台 gap ⑬**（socialware role-slot 模板 spawn 不把 recipe `behaviors` 捕进 agent `:kind_base`，首次 dispatch `{:unknown_action}` fail-loud），本轮用 **sanctioned core 公开 API `Ezagent.Kind.mount/3`**（RF-2/RF-3 运行时 mount，持久化）操作员侧补挂后闭环；LLM 生成段因 env 无 key（gap ⑨ 原样）用**已有 app-env seam 注入 fake generator 代跑**，页面内容里明写代跑事实。**本轮零代码改动**（纯复验 + 证据 + 两个操作员脚本）。

## v2 vs v1 对照（任务三问）

| 问 | 答 |
|---|---|
| **bridge 断点（gap ⑧）绕过了吗** | **绕过了**。chat 信号腿到 native page 成员依旧在 bridge 丢（本轮日志同款 `AgentBridge deliver dropped ... :no_sandbox_respawn_state`，平台现状没变）；但 v2 的直接 dispatch 腿按 action 在实例行为集解析直接跑 handler、**不经 bridge**，本轮实测 handler 真跑到（`[E2E-SEAM-FAKE-GENERATOR] invoked` 日志 + `refresh_page` invocations 审计 `granted`） |
| **闭环到哪一格** | **全链最后一格（浏览器渲出重建页面）**，仅 LLM 生成段是 seam 替身：真出网爬取 ✅ → 20 条线索真落库 ✅ → crawl 完成自动 dispatch `refresh_page` ✅ → ALT handler 真跑 ✅ → 生成入口被调 ✅ → 真 TurnDriver（turn.open→compose→settle，turn-1）✅ → Surface approved version ✅ → 真浏览器 `/socialware/external` 渲出页面 ✅。**LLM 生成段用 seam 代跑（如实标注），等 key/A①(b) 后真渲** |
| **剩余 gap** | 新 **⑬**（本轮发现，见下）+ 原 ⑨（LLM key）+ ⑧ 的 chat 信号腿半边（ALT v2 只是绕过，A① 裁决仍是目标态）+ 承袭 ⑥⑦⑩⑪⑫（本轮未触碰或复现同现象） |

## 环境（复跑指引）

```bash
# 1. 独立冷库
POSTGRES_DB=ezagent_dealscout_e2e_v2 mise exec elixir@1.18.4-otp-27 erlang@27.3.4.13 -- \
  mix do ecto.drop, ecto.create, ecto.migrate
# 2. server（PORT=10042，named node + cookie，供 erpc 操作员脚本用）
POSTGRES_DB=ezagent_dealscout_e2e_v2 EZAGENT_ADMIN_PASSWORD=worlddev PORT=10042 \
  mise exec elixir@1.18.4-otp-27 erlang@27.3.4.13 -- \
  elixir --name ezagent_runtime@127.0.0.1 --cookie $(cat ~/.ezagent/default/runtime/cookie) -S mix phx.server
# 3. assets 已建（本 worktree 上轮跑过 assets.setup/build；fresh worktree 见 v1 README 前置）
# 4. 登录 world.localhost:10042（admin@ezagent.chat / worlddev）→ 新建会话 dealscout-v2
#    → 应用选 DealScout → discover 槽 Flavor 手改 native（gap ⑥ 原样）→ JS click 创建
# 5.（gap ⑨）注入 fake generator：fake_generator_inject.exs（见下"seam 说明"）
# 6.（gap ⑬）操作员补挂 ALT 行为到 page agent：mount_alt_behavior.exs <page_agent_uri>
# 7. operator 触发爬取：dealscout_dispatch.exs（v1 同款，token 走 env）
# 清理：kill $(cat /tmp/dealscout-e2e-v2/server.pid)；vite 孤儿；agent-browser close
```

## 步骤与判定（各步真跑程度逐条如实）

| 步 | 判定 | 证据 |
|---|---|---|
| 1 冷起+装 dealscout（session `dealscout-v2`，discover 槽手改 native） | ✅ 3 成员=Admin+discover(7751551c)+page(2ceaf36b)；`__dealscout_update__` routing rule（`$role:cGFnZQ`）随 install 落库（换名避 gap ⑦ 的 install pointer，同 v1 教训） | `01-session-created-members3.png`，routing_rules 表 2 行（rule_set=dealscout-update） |
| 2 真爬 | ✅ 纯公开腿真 `:httpc` 出网（HN Algolia front_page）`{:ok, %{injected: 20}}`；线索 + 信号真落 messages；chat 流可见 | `02-crawl-leads-and-signal-in-chat.png`、`02-crawl-dispatch-result.txt` |
| 3a **首次自动 dispatch —— 撞出新 gap ⑬** | 🟥→实锤 fail-loud：crawl 完成后直接腿真发出，`{:error, {:unknown_action, :refresh_page}}`（invocations 审计 exception 行 + `[:dealscout, :page_refresh, :error]` warning，**没有静默**）。根因：page agent `:kind_base` 捕获 `behaviors: nil`（erpc 探针实锤）——socialware install 的 role-slot 模板 spawn（`template_team.ex` → `spawn_from_template_content`）**不带 recipe 的 `behaviors`**；对照 kanban 板 agent 走 workspace `agent_create --role` 路（`role_step.ex` → `Recipe.Compose` 才捕）。install 时 cap **有** grant（审计 2 行 `cap_granted` refresh_page），缺的只是行为集捕获 | `04-gap-unknown-action-evidence.txt` |
| 3b 操作员补挂（sanctioned） | ✅ `Ezagent.Kind.mount(page_uri, DealScoutPageRefreshAlt, %{})` → `:ok`，`kind_base` 捕获列表含 ALT（持久化、冷重启幸存——core RF-2/RF-3 设计原话）。与 kanban T6/T7"显式 grant caps"同风格显式操作员步骤，零平台代码改动 | `04b-mount-result.txt`、`mount_alt_behavior.exs` |
| 3c **主证：再爬 → 全链自动闭环** | ✅ `crawl_now` `{:ok, %{injected: 20}}` → 直接腿 dispatch `refresh_page`（audit `granted`，无 exception）→ **ALT handler 真跑**（`[E2E-SEAM-FAKE-GENERATOR] invoked: session=...dealscout-v2 text="新线索 20 条（crawl）"`）→ 生成入口被调 → 真 `TurnDriver.drive` **turn-1 settle**（`{:ok, "...#turn-1"}` 日志）→ `ExternalFeed.snapshot` 返回 approved Card（erpc 实锤）| `05-refresh-chain-log.txt` |
| 4 页面前后对比 | ✅ 前：`还没有页面`（03a，`/socialware/chat` 的页面占位）；后：`/socialware/external` 真浏览器渲出重建页 "DealScout 线索页（seam 代跑生成）/ 爬取→自动刷新触发成功 / 触发指令：新线索 20 条（crawl）"（03c/03d）。页面内容自带 seam 说明（如实标注进页面本身） | `03a-page-before-crawl.png`、`03b-page-after-refresh.png`（chat 面）、`03c-page-after-rendered-external.png`、`03d-page-after-full.png` |
| 5 清理 | ✅ server 按 PID kill、vite 孤儿清、agent-browser close，10042/5173 双 clear、beam 0 残留 | — |

## seam 说明（如实标注，纪律条款）

**主链 0 stub**：爬取真出网、两次 dispatch 都真跑（第一次 fail-loud 也是真跑的证据）、TurnDriver/Surface/浏览器渲染全真。**只 seam 了 LLM 生成段**（gap ⑨：env 无 `HELLO_LLM_API_KEY`/`DEEPSEEK_KEY`，未借其它分支 key——权限裁定沿 v1）：用 ALT **已有的** app-env seam `:page_refresh_fun`（默认 `&EzagentPluginHello.Generator.start/2`）经 erpc 注入 fake generator（`fake_generator_inject.exs`）。替身与真 `Generator.start/2` 同构——spawn supervised Task（`EzagentPluginHello.TaskSupervisor`）→ catalog 合法 spec（`Spec.validate` 过）→ **真** `TurnDriver.drive`。被代跑的只有"LLM 产 spec"一步；**等 key 或 A①(b) 后把这一步换回真渲**。页面正文里也写明了代跑事实（截图可见），不冒充 AI 生成。

## 新 gap ⑬（本轮最重要发现，等 Allen 裁决）

| # | gap | 层 | 现象/根因 | 建议 |
|---|---|---|---|---|
| ⑬ | **socialware role-slot 的 recipe `behaviors` 不落 agent 实例** | domain | session-create 的 role 槽 spawn 路（`template_team.ex:ensure_legacy_member_present` → `RecipeMaterializer.spawn_from_template_content` → `TemplateSpawn`）全程不携带 recipe 的 `behaviors` → agent `:kind_base` 捕获 `nil` → per-instance action 解析 `{:unknown_action}`；而 caps 却已按 recipe grant（审计实锤）——**cap 有、行为无**的不对称。对照：workspace `agent_create --role` 路（`role_step.ex:96` `Recipe.Compose.materialize` → spawn `:behaviors`）会捕，kanban 板 agent 因此能收 caller-dispatch。core 的运行时 mount（`Ezagent.Kind.mount/3`，RF-2/RF-3）已存在且好用——本轮就是拿它操作员侧补挂闭环的 | 两条候选等裁决：(a) install 的 role-slot 模板物化把 recipe `behaviors` 穿进 spawn args（对齐 `role_step` 的 Compose 语义）；(b) install 完成后对 role 槽 agent 逐个 `Kind.mount`（等价于把本轮的操作员步骤搬进 install 流程）。落地任一后，dealscout ALT v2 **无需任何手工步骤**即全自动闭环 |

其余承袭 gap：⑥（cc-headless 槽物化崩，本轮继续手改 native）、⑨（LLM key）、⑩⑪（未触碰）、⑫（world "Page" tab 点击不切换，本轮复现同现象——page 内容在 `/socialware/external` 可见）。gap ⑧ 的 chat 信号腿半边照旧（本轮日志同款 bridge drop），A① 裁决仍是 ALT 的删除条件。

## ALT 删除条件（沿 v2 commit 注释）

A①（hello 暴露 dispatchable rebuild action）落地后本 ALT 整删、page 槽回切 `hello.builder`；在那之前 gap ⑬ 的裁决路径落地即可让 v2 全自动闭环（不再需要操作员 mount）。

## 证据文件

截图 `01`/`02`/`03a-03d` + `02-crawl-dispatch-result.txt`（dispatch 返回）+ `04-gap-unknown-action-evidence.txt`（新 gap 实锤）+ `04b-mount-result.txt`（mount 前后 kind_base）+ `05-refresh-chain-log.txt`（主证日志链 + refresh_page 审计三行）+ 三个操作员脚本（`dealscout_dispatch.exs` v1 同款 / `fake_generator_inject.exs` / `mount_alt_behavior.exs`，token 全走 env 不进提交物）。
