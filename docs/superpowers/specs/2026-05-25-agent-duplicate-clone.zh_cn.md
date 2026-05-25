# SPEC — Agent 复制/克隆原语 (Behavior.Agent `:duplicate`)

**状态:** DRAFT rev 1 · 2026-05-25
**层级:** `apps/ezagent_domain_chat/` (新 `Behavior.Agent` + action) + `apps/ezagent_core/` (BehaviorRegistry 插槽) + `apps/ezagent_domain_workspace/` (mix task 薄包装)
**触发:** Allen 2026-05-24（memory `feedback_agent_clone_not_via_template`）—— "agent 创建的 template 如果不走正常的 template 创建和 fork 流程，可能导致开发 drift，但如果走标准流程，又可能导致 Template Registry 里面大量临时创建后再也不用的 template"。Clone 必须作为 domain.agent primitive 存在，**绝不**走 Template Registry。
**前置:**
- `docs/superpowers/specs/2026-05-25-agent-create-cli-gui-parity.md` —— `Behavior.Workspace.:create_agent` 是复用的 spawn facade
- PR #289 (`2c66903`) —— per-agent config_dir + Kind.Template 扩展回调
- PR #288 —— `Ezagent.Behavior.Sandbox`（持有 `config_dir_path` + `template_class` 的 slice）
- PR #330 (`8277d08`) —— `Ezagent.Workspace.create_agent/3` facade (CLI/LV parity)
- `feedback_let_it_crash_no_workarounds` —— 不要 `:warning + degrade`、不要 shim
- `feedback_uuid_is_canonical_identifier` —— agent URI 为权威标识；username 仅用于显示
- `feedback_fork_is_generic_template_concern` —— Template 级 fork（PR1 #287 的 `Behavior.Template.:fork`）和本 SPEC 的 Agent 级 clone 是两件事
**英文对照:** `2026-05-25-agent-duplicate-clone.md`

---

## 0. 设计决策（Allen `wake-but-don't-stop` 已预设默认值）

三个开放问题由 Allen 自主模式默认值回答；本 SPEC 采纳。供 SPEC review 时人工复核；只在实现 PR 发现根本性阻塞时再通过飞书升级。

| # | 问题                              | 默认                                   | 理由                                                                                                            |
|---|-----------------------------------|----------------------------------------|-----------------------------------------------------------------------------------------------------------------|
| 1 | 转移所有权 **还是** 复制？        | **复制**                               | 源 agent 保持存活并由源用户所有；目标是 `target_owner_uri` 所有的新实例。回退更干净。                            |
| 2 | 复制对话历史？                    | **无（fresh）**                        | Agent Kind 自身不携带聊天历史 slice（那是 Session 的概念）。Identity caps 重置。需要历史就继续用源 agent。       |
| 3 | `config_dir` 语义？               | **深拷贝**（`File.cp_r/2`）            | 文件系统状态独立；agent 间不共享可变状态。与 `create_agent_config_dir/2` 对新建 spawn 的处理一致。              |

这些是 SPEC 默认值。如果 review 想要不同语义，在 PR review 中提出，**在**实现 PR 打开之前。

---

## 1. 目标

**新增一个可 dispatch 的 Behavior action —— `Ezagent.Behavior.Agent.:duplicate` —— 把一个已存在的 agent 克隆到一个新的 agent URI，可选地放在不同的 workspace、由不同的用户所有。** 不走 Template Registry 中转；不走 `save_as_template + fork + spawn` 三跳；无 Template Class drift 风险。

本 SPEC 的实现 PR 落地后：
- `mix ezagent.agent.duplicate <source_uri> <target_uri> --owner <owner_uri>` 产生一个全新的存活 agent，位于 `target_uri`，拥有自己的 config_dir（FS 与源独立）、新鲜的 Identity caps（默认 grant 由 `target_owner_uri` 合成）、与源**无**聊天历史耦合。
- 克隆原语住在 **Agent Kind** 上，不在 Template Registry 上。Template Class 元数据被**引用**（target agent 保持相同 flavor + template_class），但不**注册**新 Template Class。
- 支持跨 workspace 和跨用户克隆（caller 需对**目标** workspace 持有 workspace-admin cap；源端需要源所有权或源 ws admin）。
- 一个回归底线 invariant test 断言克隆出的 `config_dir` 在结构上独立于源：动源目录的文件**不影响**目标目录。

---

## 2. 范围

In-scope:
- 新模块 `Ezagent.Behavior.Agent`（apps/ezagent_domain_chat/lib/ezagent/behavior/agent.ex）—— Agent Kind 目前自己**没有** Behavior 文件（`Ezagent.Entity.Agent.behaviors/0` 列了 `Chat + Identity + Sandbox`，没有 `Agent` Behavior）。新模块以 `:duplicate` 为首个 action。slice 为空（Agent 的域状态住在兄弟 Behavior 中）；新 Behavior 存在的目的是承载**主语是 agent 本身**的 action。
- 该 Behavior 上的新 action `:duplicate`。参数 `%{source_uri: URI.t(), target_uri: URI.t(), target_owner_uri: URI.t()}`。模式 `:call`。
- Cap subject `{Behavior.Agent, :duplicate}` —— `data_owner/1` 返回源 agent 的 `Identity` 所有者（源的所属 user，通过 Identity slice 解析）。目标 workspace 的 workspace-admin 也可克隆（依 `caps-data-ownership-v2.md` §5.2 admin 分支）。
- Action body 5 步（详 §3.2）。
- Mix task `Mix.Tasks.Ezagent.Agent.Duplicate`（`mix ezagent.agent.duplicate`）—— 薄薄的 construct-args + dispatch 包装（镜像 `agent.create`）。
- ExUnit 验收测试（在实现 PR 中）覆盖 happy path + cap 拒绝 + 冲突 + 源缺失 + 跨 workspace。
- Invariant test `apps/ezagent_core/test/invariants/agent_duplicate_isolation_invariant_test.exs` —— 克隆后改动源 `config_dir`，断言目标不变。

Out-of-scope:
- 克隆的 LV admin UI。V1 仅 CLI；admin LV 在原语稳定后单独 PR（按 `docs/futures/todo.md` 推后；§10 标记）。
- "Save as template" 语义。需要可复用蓝图就走 `Behavior.Template.:fork` 路径（PR1 #287），那条路径是受治理的；克隆是为一次性实例拷贝，不是 template。
- 任何现有数据的迁移。Clone 是只向前的新操作；当前系统没有需要升级的东西。
- `:duplicate` 的 MCP 工具暴露。任何持有相应 cap 的 caller 都能 dispatch 到它，但本 PR 不做 MCP wrapper。
- 聊天历史转移。按 §0 决策 2 —— 按设计排除。

---

## 3. 设计

### 3.1 Behavior 模块 —— `Ezagent.Behavior.Agent`

新文件 `apps/ezagent_domain_chat/lib/ezagent/behavior/agent.ex`。Agent 所属域是 chat 域（Agent 住在 chat 的 AgentSupervisor 下，依 `Ezagent.Entity.Agent.supervisor/0`）。

```elixir
defmodule Ezagent.Behavior.Agent do
  @moduledoc """
  Agent Behavior —— 主语是 agent 自身的 action（不归 Chat /
  Identity / Sandbox 管的 agent-domain 操作）。

  ## 为何存在

  在此 Behavior 之前，`Ezagent.Entity.Agent` 有三个兄弟 ——
  `Chat`（Session 范围消息）、`Identity`（caps）、`Sandbox`
  （per-agent config_dir）。没有一个负责 "agent-as-a-thing"
  操作：clone、archive、rename 等。

  这个 Behavior 是天然的家。它的 slice 故意为空 —— agent 的
  *状态*住在兄弟 slice 中；这个 Behavior 是为*对 agent 作为
  实体的动作*存在。

  ## Actions

  - `:duplicate` (`:call`) —— 克隆源 agent 到 `target_uri` 的
    新 agent，由 `target_owner_uri` 所有。详见 SPEC
    `docs/superpowers/specs/2026-05-25-agent-duplicate-clone.md`.

  未来 actions（V1 范围外）: `:rename`, `:archive`, `:restore`.
  """

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:duplicate]

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:duplicate,
       "克隆该 agent 到 <target_uri> 的新 agent，由 <target_owner_uri> 所有。" <>
         "深拷贝 config_dir (cc flavor); 新鲜 Identity caps; 无聊天历史。源不变。"}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :agent

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{}

  @impl Ezagent.Behavior
  def invoke(:duplicate, slice, args, ctx), do: # ... 详 §3.2

  @impl Ezagent.Behavior
  def interface, do: # ... 详 §3.3

  # 源 agent 的所有者是 data_owner —— 源 agent（通过 Identity behavior）
  # 所属的 user。目标 workspace 的 workspace-admin 也能 grant
  # （依 §5.2 admin 分支）。
  @impl Ezagent.Behavior
  def data_owner(%URI{} = source_agent_uri), do: source_agent_uri
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end
```

并修改 `Ezagent.Entity.Agent.behaviors/0`（`apps/ezagent_domain_chat/lib/ezagent/entity/agent.ex` 67-68 行）：

```elixir
def behaviors,
  do: [Ezagent.Behavior.Chat, Ezagent.Behavior.Identity,
       Ezagent.Behavior.Sandbox, Ezagent.Behavior.Agent]
```

### 3.2 Action body —— `:duplicate`

在**源 agent** 的 Kind GenServer 中运行（`ctx.self_uri` 是源 agent URI；dispatch target 是 `entity://agent/<src_ws>/<src_name>?action=agent.duplicate`）。

```elixir
def invoke(:duplicate, _slice, args, ctx) do
  source_uri        = Map.fetch!(ctx, :self_uri)
  target_uri        = Map.fetch!(args, :target_uri)
  target_owner_uri  = Map.fetch!(args, :target_owner_uri)
  caller            = Map.fetch!(ctx, :caller)
  caps              = Map.fetch!(ctx, :caps)

  with {:ok, target_uri}     <- validate_target_uri(target_uri),
       :ok                   <- refuse_if_target_exists(target_uri),
       {:ok, source_meta}    <- read_source_metadata(source_uri),
       {:ok, target_ws_uri}  <- workspace_uri_from_agent(target_uri),
       {:ok, create_args}    <- build_create_args(source_meta, target_uri),
       {:ok, target_owner_ctx} <- impersonate_target_owner_ctx(target_owner_uri, caller, caps),
       {:ok, result}         <- spawn_target_via_workspace(target_ws_uri, create_args, target_owner_ctx),
       :ok                   <- deep_copy_config_dir(source_meta, result.agent_uri, source_uri) do
    {:ok, %{}, %{
      source_uri: source_uri,
      target_uri: result.agent_uri,
      template_name: result.template_name,
      owner_uri: target_owner_uri
    }}
  end
end
```

5 个概念步骤（对应 memory `feedback_agent_clone_not_via_template`）：

1. **验证 target_uri 不存在** —— `Ezagent.KindRegistry.lookup(target_uri)` 返回 `:error` → 继续；`{:ok, _pid}` → `{:error, {:already_exists, target_uri}}`。
2. **读取源的相关 slice** —— dispatch `sandbox.read` 到源，取 `config_dir_path` + `template_class`。Chat slice 不带 per-agent 状态（那是 Session 的事；agent 的 `:chat` slice 为空）。**故意不读** Identity slice —— target 通过 Identity 的 `init_slice/1` 合成默认 caps（按 §0.2 决策）。源 flavor 从源 URI 的 `<flavor>_<name>` 前缀推导（PR-2 v3 §3 形状）。
3. **通过 Workspace.create_agent spawn target** —— 调用 `Ezagent.Workspace.create_agent(target_ws_uri, create_args, target_owner_ctx)`（SPEC #330 facade）。`create_args` 携带 `flavor`、`name`、`cwd`（继承自源 PtyServer 记录的 cwd，或当 cwd 是 workspace 相对路径时重新对 target workspace 根目录解析 —— TBD 见 §10）。这条路径：
   - 验证 flavor + name + cwd
   - 组装 target agent URI（必须等于 caller 的 `target_uri`）
   - 注册 workspace-scoped template（cc/echo）或直接 spawn（curl/np）
   - 调用 `Loader.invoke_template` → cc plugin 的 `instantiate/3` → `ensure_agent_kind` + `create_agent_config_dir` + `ensure_pty_server`
   - 此时 target 拥有一个**从 template 引用目录**复制的 FRESH config_dir（不是源的）。第 5 步用源覆盖它。
4. **Target 的 Identity caps** —— **故意**使用 `target_owner_ctx`，让 spawn 的 `default_grants_from_data_owner/2` 合成新所有者的默认 caps。**不**从源 grant。Caller **不需要**提供 caps —— 它们由新所有权推导。
5. **深拷贝 config_dir** —— cc flavor:
   - `source_dir = source_meta.config_dir_path`（第 2 步读取）
   - `target_dir = source_meta.template_class.agent_config_dir(target_uri)`
   - 原子地擦除 target 刚刚由引用目录派生出的 dir（`File.rm_rf!(target_dir)`）
   - `File.cp_r!(source_dir, target_dir)`（深拷贝包含 `.claude/plugins/*` 扩展 + 若存在的 `.credentials.json`）
   - 重新 chmod（`0o700` dir, `0o600` credentials）—— 与 `cc_agent.ex:977-988` 的 `do_atomic_copy/3` 同样的加固
   - 重写 `.ezagent-config-complete` marker，让未来 spawn 的幂等性检测 "已完成"
   - dispatch `sandbox.write_path` 到 target 用新路径 + template_class 更新它的 slice（幂等 —— 第 3 步已用 template 引用路径填好；这里重写以保 slice 一致）

非 cc flavor (echo / curl / np)，第 5 步 no-op（源 `config_dir_path: nil` 意味着无可拷；源插件 Template Class 没管 dir）。

**失败处理（let-it-crash，无 shim）:**
- 第 5 步失败（例 `File.cp_r` 复制中失败）：caller 看到 `{:error, {:config_dir_copy_failed, reason}}`。刚 spawn 的 target agent **存活**—— 它的 sandbox slice 指向半复制的 dir。约定是：第 5 步失败时，duplicate 操作上报错误，期望 operator 对 target_uri 调用 `sandbox.destroy` 清理。我们**不**自动回滚 target spawn —— 部分状态+明确错误优于静默回滚失败。
  - 这与 `feedback_let_it_crash_no_workarounds` 一致：这里**不**防御性 `try/rescue`；`File.cp_r!` 若抛出，dispatch 的 action 返回 `{:error, %File.CopyError{}}`，caller 决定。
  - 理由：回滚本身是一个 destroy 操作，有自己的失败模式；destroy + destroy-of-destroy 链式正是我们要避的 "shim"。单一锋利边：target 存在，dir 部分，operator destroy 它。

### 3.3 Interface schema

```elixir
def interface do
  %{
    duplicate: %{
      description:
        "克隆源 agent 到 target_uri 的新 agent，由 target_owner_uri 所有。" <>
          "深拷贝 config_dir; 新鲜 Identity caps; 无聊天历史。",
      args: %{
        target_uri: :uri,
        target_owner_uri: :uri
      },
      returns: %{
        source_uri: :uri,
        target_uri: :uri,
        template_name: {:option, :string},
        owner_uri: :uri
      },
      modes: [:call]
    }
  }
end
```

（`source_uri` **不**在 `args` —— 它就是 `ctx.self_uri`，dispatch target；dispatch URI 自身命名了源。）

### 3.4 Mix task —— `mix ezagent.agent.duplicate`

新文件 `apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.agent.duplicate.ex`（放在 workspace 里靠近 `agent.create`；若未来抽出 `ezagent_domain_agent` 可迁移）。

```bash
mix ezagent.agent.duplicate <source_uri> <target_uri> --owner <owner_uri>
```

例：

```bash
mix ezagent.agent.duplicate \
    entity://agent/system/cc_linyilun-default \
    entity://agent/system/cc_linyilun-clone \
    --owner entity://user/system/allen
```

Body 是 `agent.create.ex` 用的标准 `parse_uri` + `decompose` + `Invocation.dispatch` 形状（见 `apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.agent.create.ex:121-148`）。

---

## 4. Cap-bAC

### 4.1 Cap subject

`{Behavior.Agent, :duplicate}` —— 通过 `Ezagent.BehaviorRegistry` 启动时注册（若 `Ezagent.Entity.Agent.behaviors/0` 包含新 Behavior 即免费）。

### 4.2 解析

- `Behavior.Agent.data_owner(source_uri)` 返回 `source_uri`。Identity 的 `data_owner_of/2` 再解析到拥有源 agent 的 user（依 Identity behavior 的 lineage / 所有权记录）。
- `default_grants_from_data_owner/2`（在 CapabilityRegistry 中，依 SPEC `caps-data-ownership-v2.md` §3.3）合成：源 agent 的所有者默认在源上持有 `{Behavior.Agent, :duplicate}`。
- §5.2 admin 分支：**目标** workspace 的 workspace admin 也满足检查 —— caller 可把 agent 从自己不拥有的 workspace 移到自己拥有的。

### 4.3 Caller 场景

| Caller                              | 源 ws admin? | 目标 ws admin? | 源所有者? | 允许? |
|-------------------------------------|--------------|----------------|-----------|-------|
| 源所有者（克隆自己的 agent）         | n/a          | n/a            | 是        | 是（owner 默认 grant）|
| **目标** ws 的 workspace admin       | n/a          | 是             | n/a       | 是（§5.2 admin 分支在目标）|
| **源** ws 的 workspace admin         | 是           | 否             | 否        | 否（admin grant 是 target-scoped）|
| 随机 user                            | 否           | 否             | 否        | 否（拒绝）|

`caps-data-ownership-v2.md` §5.2 admin 分支前例（workspace admin grant Workspace caps）自然延伸：克隆**到**一个 workspace 是对**目标**的 workspace-admin 行为，不是对源的。

---

## 5. Audit

Dispatch 链已记录调用（每个 `Invocation.dispatch/1` 都被 audit，依 Phase 5 invocation envelope）。Audit 记录将包含：

- `caller` —— 谁发起
- `target` —— `<source_uri>?action=agent.duplicate`
- `args` —— `%{target_uri:, target_owner_uri:}`
- `result` —— `{:ok, %{source_uri, target_uri, template_name, owner_uri}}` 或 `{:error, _}`

无需额外 telemetry；现有 audit envelope 完整捕获 clone 操作。Operator 可 grep audit log 找 `?action=agent.duplicate` 枚举每一次克隆。

---

## 6. 迁移

**无。** 无 DB schema 变更，对现存活 agent 无新增 behavior（新 Behavior 的 slice 为空；`init_slice/1` 返回 `%{}`；无 snapshot 迁移）。本 PR 之前启动的 agent 在下次 supervisor 重启后得到新 Behavior；它们的 slice 为 `%{}`，无 rehydration 担忧。

原任务描述中考虑的 `parent_template_uri` 字段**不需要** —— Template lineage 已在 PR1 (#287) 通过 `Behavior.Template.:fork` 发布。Agent clone 是实例对实例；它不产生新 template，所以**不**创建 template lineage 行。

---

## 7. 验收测试

在实现 PR 中（不在本 SPEC）。列在这里让实现 PR 知道底线。

1. **Happy path (cc, 同 workspace, 同 owner)**: 克隆一个刚 spawn 的 cc agent → 新 agent 在磁盘上有独立 config_dir；sandbox slice 包含新 dir 路径；新 agent 的 Identity caps 是源所有者的默认；源 agent 仍存活并不变。
2. **Happy path (跨 workspace)**: caller 仅在 `target_ws` 持有 workspace admin；克隆成功；target 通过 WorkspaceRegistry 绑定到 `target_ws`。
3. **Cap 拒绝 —— 随机 user**: caller 既不是源所有者也不是 target-ws-admin → `{:error, :unauthorized}`（或 Identity action body 对 cap-check 失败返回的任何值）。
4. **Target URI 冲突**: `target_uri` 已在 KindRegistry 中存活 → `{:error, {:already_exists, target_uri}}`。源不变。
5. **源缺失**: 对不存在的 `source_uri` dispatch → 标准 dispatch-时错误 `{:error, {:no_such_kind, source_uri}}`。
6. **深拷贝隔离**: 克隆后修改源 `config_dir` 中一个文件；target 的 `config_dir` 同相对路径的文件不变。**（这就是 invariant；见 §8。）**
7. **非 cc flavor (echo)**: 克隆一个 echo agent → 无 config_dir 操作；spawn 成功；target 的 sandbox slice `config_dir_path: nil`（echo 不管 dir）。第 5 步幂等 / no-op。
8. **Target spawn 的幂等**: 用同 target_uri dispatch `:duplicate` 两次 → 第二次撞上冲突守卫，干净返回 `{:error, {:already_exists, target_uri}}`。第一次的 target 不受影响。

---

## 8. Invariant test（依 `feedback_completion_requires_invariant_test`）

`apps/ezagent_core/test/invariants/agent_duplicate_isolation_invariant_test.exs`:

```elixir
test "cloned agent's config_dir is FS-independent of source" do
  # 1. spawn 源 cc agent
  # 2. 在源 config_dir 写一个 canary 文件
  # 3. dispatch :duplicate → target agent
  # 4. 从源读 canary 文件 —— 仍在
  # 5. 从 target 读 canary 文件 —— 在（深拷贝带过来了）
  # 6. 改源中 canary 文件
  # 7. 读 target 中 canary 文件 —— **未变**（证明无 symlink / 共享 inode）
  # 8. 删源整个 config_dir
  # 9. target 的 config_dir 仍完整且可用
end
```

若此测试在某架构下会**失败**（例某人用 `File.ln_s` 而非 `File.cp_r`），无论单元测试如何通过，PR 都不完成。

---

## 9. CLAUDE.md / 文档

无需 CLAUDE.md 改动。Mix task `--help` 自动从 `@moduledoc` 渲染。Operator 面向文档放在实现 PR 的 `docs/operations/agent-duplicate.md`（一页，双语依 `feedback_bilingual_docs_convention`）。

---

## 10. 待办（推后 —— 按 `feedback_dont_defer_what_is_solvable_now` 标记）

- **跨 workspace 克隆的 cwd 语义。** 当源的 PTY cwd 是 operator 主机的绝对路径时，target 的 cwd 应是什么？V1 默认：同绝对路径（operator 通常在同机克隆做测试）。跨主机 federation 的 cwd 解析是 Phase-10 关心的。
- **克隆的 LV admin UI。** `/admin/agents/<uri>/clone` 表单让 admin LV 用户无需进 CLI 就能克隆。按 §2 推后；记入 `docs/futures/todo.md`，原语稳定后再做。
- **MCP 工具面。** 原语 + invariant test 落地后，把 `:duplicate` 暴露为 MCP 工具以供 in-session agent 自克隆，是 10 行包装。推后避免本 SPEC 范围蔓延。
- **批量克隆。** "克隆 N 份" —— 压测有用。是原语的微小包装。V1 外。

---

## 11. Codex 对抗 review（依 `feedback_spec_codex_adversarial_review`）

本 SPEC 合并到分支后，在开实现 PR **之前**对本文件 dispatch 一个 `/codex:adversarial-review` 子 agent。捕获 "错路径"，不只是缺陷。

---

## 12. User-assist steps（依 `feedback_flag_user_assist_steps`）

本 SPEC **无** user-assist 步骤。实现 PR 完全跑 CI + 本地 mix 测试。端到端手动验证（建议 `mix ezagent.agent.duplicate` 跑 `linyilun-default`）是**建议**而非门控。
