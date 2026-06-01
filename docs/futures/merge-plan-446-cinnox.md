# 合并执行手册: PR #446 + feat/autoservice-cinnox → 4 条轨道

> **生成**: 2026-06-01, Claude Code session with huangjiajia
> **上下文**: 评估 PR #446 与 `feat/autoservice-cinnox` 的分叉 → 采纳 4 轨合并方案
> **关键决策**:
> - 接管 (A): 走 PR #446 的 `Behavior.Mode`
> - fast/slow 双 agent (B): 走 `feat/autoservice-cinnox`
> - KB MCP sidecar (C): 走 `feat/autoservice-cinnox`

---

## 源分支

| 分支 | 位置 | 基础 commit | 状态 |
|---|---|---|---|
| `origin/poc/phase-2-customer-service` | GitHub remote | main ~`8a8db6a` | PR #446, WIP/draft |
| `feat/autoservice-cinnox` | WSL local (`/home/huangjiajia/ezagent`) | `8a8db6a`, 3 commits | 本地, 未推送 |
| `origin/main` | GitHub | `6013aaac`(当前最新) | 已大幅领先 |

---

## Step 0: 推送 WSL 分支

```bash
# 在 WSL 终端中执行:
cd /home/huangjiajia/ezagent
git push origin feat/autoservice-cinnox
```

---

## Step 1: PR-A — `feat/takeover-mode` (Behavior.Mode + takeover gating)

**依赖**: 无 (独立)
**从**: `origin/poc/phase-2-customer-service`
**文件**: ~600 lines, domain 层

```bash
git checkout origin/main -b feat/takeover-mode

# --- 整文件 checkout (新文件, main 上不存在) ---
git checkout origin/poc/phase-2-customer-service -- \
  apps/ezagent_domain_chat/lib/ezagent/behavior/mode.ex \
  apps/ezagent_domain_chat/test/ezagent/behavior/mode_test.exs

# --- 手动 patch: chat.ex ---
# 打开 apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex
# 需要加的 3 处改动:

# 1. 加 reads_sibling_slices/0 callback (在 actions/0 或 state_slice/0 附近):
#    @impl Ezagent.Behavior
#    def reads_sibling_slices, do: [:mode]

# 2. 在 invoke(:send, ...) 中, store_msg 之后、PubSub.broadcast 之前,
#    加 session_mode 读取 + suppress_customer_visible? 判断:
#    session_mode =
#      ctx
#      |> Map.get(:sibling_slices, %{})
#      |> Map.get(:mode, %{})
#      |> Map.get(:mode, :auto)
#    suppress_customer_visible? = session_mode == :takeover and agent_sender?(msg.sender)

# 3. PubSub.broadcast 包裹在 `unless suppress_customer_visible? do ... end`
#    recipient 分发加 cond: suppress_customer_visible? and user_uri?(recipient) → :ok

# 4. 文件末尾加 agent_sender?/1 (在 user_uri?/1 旁边):
#    defp agent_sender?(%URI{scheme: "entity", host: "agent"}), do: true
#    defp agent_sender?(_), do: false

# --- 手动 patch: session.ex ---
# apps/ezagent_domain_chat/lib/ezagent/entity/session.ex
# behaviors/0 列表加 Ezagent.Behavior.Mode:
#   def behaviors, do: [
#     Ezagent.Behavior.Chat,
#     Ezagent.Behavior.Publisher.SessionImpl,
#     Ezagent.Behavior.ExternalMirror,
#     Ezagent.Behavior.Mode   # ← 加这一行
#   ]

# --- 手动 patch: application.ex ---
# apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex
# start/2 中 (CapabilityRegistry.register 块附近) 加:
#   alias Ezagent.Behavior.Mode, as: ModeB
#   Enum.each(ModeB.actions(), fn action ->
#     :ok = CapabilityRegistry.register(Session, action, ModeB)
#   end)

# --- 更新 session_test.ex ---
# apps/ezagent_domain_chat/test/ezagent/entity/session_test.exs
# behavior 列表断言加 Ezagent.Behavior.Mode

# --- 验收 ---
mix format --check-formatted
mix test apps/ezagent_domain_chat/test/ezagent/behavior/mode_test.exs
mix test apps/ezagent_domain_chat/test/ezagent/entity/session_test.exs
mix test  # 全量
```

**参考源**:
- PR #446 的 `chat.ex` diff: https://github.com/ezagent42/ezagent/pull/446/files#diff-chat_ex
- 整文件: `git show origin/poc/phase-2-customer-service:apps/ezagent_domain_chat/lib/ezagent/behavior/mode.ex`

---

## Step 2: PR-B — `feat/pty-hardening` (PTY env + trust + 64KB guard)

**依赖**: 无 (独立)
**从**: `origin/poc/phase-2-customer-service` (更全面的版本)
**文件**: ~450 lines, domain_pty 层

```bash
git checkout origin/main -b feat/pty-hardening

# --- 测试文件 (新文件, 直接 checkout) ---
git checkout origin/poc/phase-2-customer-service -- \
  apps/ezagent_domain_pty/test/ezagent/domain/pty/server_auto_prompts_test.exs \
  apps/ezagent_domain_pty/test/ezagent/domain/pty/server_command_size_test.exs \
  apps/ezagent_domain_pty/test/ezagent/domain/pty/server_env_test.exs

# --- server.ex 需手动 patch 4 处 ---
# 文件: apps/ezagent_domain_pty/lib/ezagent_domain_pty/server.ex

# 改动 1: default_auto_prompts/0 — 加 :trust_folder_dialog
#   在 dev_channels_dialog 之前加:
#   %{
#     name: :trust_folder_dialog,
#     match: ["Is this a project you", "trust this folder"],
#     send: "1\r",
#     fired?: false
#   }

# 改动 2: default_auto_prompts/0 — dev_channels_dialog match 改为
#   match: ["development channels", "I am using this for local development"],

# 改动 3: default_auto_prompts 从 defp 改成 def (加 @doc false)

# 改动 4: build_env/1 — 从 splatting :os.getenv() 改为 override-only
#   # 删除: base = :os.getenv() |> Enum.map(...)
#   # 改为: base = []  (子进程继承 BEAM 环境, 只传覆盖项)
#   移除 build_env 中对 :os.getenv() 的调用

# 改动 5: spawn_claude_directly/1 — 加 check_command_size guard
#   with :ok <- check_command_size(exec_cmd, env) do ... end

# 改动 6: 加 check_command_size/2 + estimated_command_size/2
#   @packet2_limit 65_535
#   @command_size_headroom 4_096
#   def estimated_command_size(exec_cmd, env), do: ...
#   defp check_command_size(exec_cmd, env), do: ...

# --- 同时 patch ezagent_domain_python/server.ex ---
# 同样把 build_env 从 splatting 改为 override-only
# (参考: git diff origin/poc/phase-2-customer-service -- apps/ezagent_domain_python/)

# --- 验收 ---
mix format --check-formatted
mix test apps/ezagent_domain_pty/test/ezagent/domain/pty/
mix test apps/ezagent_domain_python/test/
mix test  # 全量
```

**参考源**:
- PR #446 的 `server.ex` 完整 diff: https://github.com/ezagent42/ezagent/pull/446/files#diff-server_ex

---

## Step 3: PR-C — `feat/eager-bridge` (EagerBridge.ensure_bound!/2)

**依赖**: 无 (独立)
**从**: `origin/poc/phase-2-customer-service`
**文件**: ~250 lines, cc plugin 层

```bash
git checkout origin/main -b feat/eager-bridge

# --- 整文件 checkout (新文件) ---
git checkout origin/poc/phase-2-customer-service -- \
  apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/eager_bridge.ex \
  apps/ezagent_plugin_cc/test/ezagent/plugin_cc/eager_bridge_test.exs

# --- 验收 ---
mix format --check-formatted
mix test apps/ezagent_plugin_cc/test/ezagent/plugin_cc/eager_bridge_test.exs
mix test  # 全量
```

---

## Step 4: PR-D — `feat/autoservice-plugin` (合并两个源 + 吸收增强)

**依赖**: Step 1(PR-A 合入 main 后, 因为要用 `Behavior.Mode`)
**从**: `feat/autoservice-cinnox`(骨架) + `origin/poc/phase-2-customer-service`(增强)
**文件**: ~3000 lines, 新 plugin

```bash
# 前提: PR-A 已合入 main
git checkout origin/main -b feat/autoservice-plugin

# === 骨架: 从 WSL 分支拿整个 plugin ===
git checkout feat/autoservice-cinnox -- apps/ezagent_plugin_autoservice/

# === 增强: 从 PR #446 吸收功能 ===

# 1. soul_store.ex (soul CR 管理, WSL 分支没有)
#    从 PR #446 提取:
#    git show origin/poc/phase-2-customer-service:apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/soul_store.ex
#    放到: apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/soul_store.ex
#    改 module prefix: EzagentPluginCustomerChat → EzagentPluginAutoservice

# 2. config_live.ex (soul 编辑 LiveView, WSL 分支没有)
#    git show origin/poc/phase-2-customer-service:apps/ezagent_plugin_customer_chat/lib/ezagent_plugin_customer_chat/config_live.ex
#    放到: apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/config_live.ex
#    改 module prefix: EzagentPluginCustomerChat → EzagentPluginAutoservice

# 3. session_view_live.ex (session 详情查看)
#    同上操作, 改 prefix

# 4. theme.ex (主题配置)
#    同上操作, 改 prefix

# 5. components.ex (UI components — 需与现有的 chat_ui.ex 合并)
#    PR #446 的 components.ex 和 WSL 的 chat_ui.ex 功能重叠,
#    取 PR #446 的更完整版本, 改 prefix 后覆盖 chat_ui.ex

# 6. 路由注册 (apps/ezagent_web/lib/ezagent_web/router.ex):
#    scope "/autoservice", EzagentPluginAutoservice do
#      pipe_through [:browser, EzagentWeb.Plugs.RequireEntity]
#      live_session :autoservice, on_mount: {EzagentWeb.LiveAuth, :require_entity} do
#        live "/", CustomerLive
#        live "/operator", OperatorLive
#        live "/sessions/:session_uri", SessionLive   # 来自 PR #446
#        live "/config/:tenant", ConfigLive            # 来自 PR #446
#      end
#    end

# === 适配: operator_live.ex 接 Behavior.Mode ===
# 当前 WSL 的 operator_live.ex "接管"是 operator 以 User member join session —
# PR-A 合入后, 应改为 dispatch mode.set :takeover。
# 在 handle_event("select", ...) 中加:
#   target = URI.new!("#{uri_str}?action=mode.set")
#   Invocation.dispatch(%Invocation{
#     target: target, mode: :call, args: %{mode: :takeover},
#     ctx: %{caller: operator_uri, caps: caps, reply: {:caller_inbox, self()}}
#   })

# === 可能还需要 ===
# - 更新 ezagent_web/mix.exs, 加 :ezagent_plugin_autoservice 依赖
# - 更新 config/*.exs, 如有需要
# - 加 themes priv 文件 (从 PR #446)
#   git checkout origin/poc/phase-2-customer-service -- \
#     apps/ezagent_plugin_customer_chat/priv/customer_chat_themes/
#   → 移到 apps/ezagent_plugin_autoservice/priv/

# --- 验收 ---
mix format --check-formatted
mix test apps/ezagent_plugin_autoservice/test/
mix test  # 全量
# e2e 验证:
mix ecto.drop && mix ecto.create && mix ecto.migrate
export DEEPSEEK_API_KEY=sk-...
mix ezagent.demo.seed_autoservice
# 启动 phx.server, 浏览器访问 /autoservice 和 /autoservice/operator
```

---

## 执行顺序总览

```
Step 0: git push origin feat/autoservice-cinnox
        ↓
Step 1: PR-A  feat/takeover-mode      ─┐
Step 2: PR-B  feat/pty-hardening      ─┤ 平行, 互不依赖
Step 3: PR-C  feat/eager-bridge       ─┘
        ↓  (PR-A 合入 main 后)
Step 4: PR-D  feat/autoservice-plugin
```

---

## 每 PR 的 check gate

```bash
# 每个 PR 合前必须:
mix format --check-formatted          # 格式化检查
mix test <该 PR 涉及的所有 test>       # 相关测试
mix test                              # 全量回归

# 不变式自查 (CLAUDE.md checklist):
grep -rn "PubSub.broadcast" apps/ | grep -v ":events"  # 检查无 inbound 路径 direct broadcast
grep -rn "def init/1" apps/ | grep -v "use Ezagent.Kind"  # 检查无手写 init 跳过宏
```

---

## 记录

| 来源讨论 | 链接 |
|---|---|
| PR #446 | https://github.com/ezagent42/ezagent/pull/446 |
| futures 分析 | `docs/futures/autoservice-on-ezagent-feasibility.zh_cn.md` |
| 本手册所在 commit | (待 PR 创建后填入) |
