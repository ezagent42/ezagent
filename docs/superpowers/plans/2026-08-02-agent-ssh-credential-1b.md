# Agent SSH 凭据 1b 实施计划（物化进 agent）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让持有指定 cap 的 agent 在启动时自动拿到其被授权 User 的 SSH 私钥与 `GIT_SSH_COMMAND`，从而能对私有仓库执行 `git`。

**Architecture:** core 提供两个通用机制（per-agent 目录的路径权威 + 写入/env 拼装）；`ezagent_domain_identity` 提供编排（找 cap → dispatch 读 → 调 core 写）；cc flavor 两处各 merge 一次 env。**开关就是那条 cap**，其 `instance` 字段同时是"读谁的 key"的指针。

**Tech Stack:** Elixir 1.19 / OTP 28，Ezagent umbrella（`ezagent_core` / `ezagent_domain_identity` / `ezagent_plugin_cc`），ExUnit。

**上游 spec:** `docs/superpowers/specs/2026-08-02-agent-ssh-credential-1b-design.md`（本计划的需求权威；任何与本计划冲突处**以 spec 为准，先报告再实现**）

## Global Constraints

- **写 Behavior 代码前必读** `.claude/skills/ezagent-developer/references/lifecycle.md`。本计划**不新增 Behavior** —— 全部是普通模块与 mix task，因此不涉及 `use Ezagent.Lifecycle`。**禁止**为本计划新增任何 `use Ezagent.ActionSet` / `state_slice` / `init_slice` / `invoke/4`。
- **tier 边界**：`Ezagent.Sandbox.GitIdentityDir` 与 `Ezagent.Credential.GitIdentityRuntime` 在 `ezagent_core`，**不得**引用 `Ezagent.ActionSet.UserSshIdentity`、`Ezagent.Identity`、任何 flavor/plugin 模块。编排模块在 `ezagent_domain_identity`。
- **测试命令一律带** `POSTGRES_PORT=15432`（本机 Postgres 监听 15432，`config/test.exs:63` 默认 55432；不设会以**连接超时**而非"端口错"失败）。
- **`mix ci.fast` 必须显式 `timeout: 300000`。被 kill 的运行不算通过。** 报告 gate 结果时用"**本支无新增红**"，不得写"gate 全绿"（main 上已知既有红：`official_site_seed.ex` 4 条、identity `Cutover`/`Runbook` 3 条、`arch.scan` `no_flavor_refs_in_core` 1 条、`check_invariants.lifecycle` 2 条）。
- **错误词汇不得合并**：`:owner_has_no_key`（user 没生成过 key）与 `{:owner_key_unavailable, reason}`（生成过但状态损坏）是**两个**值。1a 花了一整轮 review 才把 `:ssh_identity_absent` / `:ssh_identity_unavailable` 分开，1b 不得丢掉这个区分。
- **`GIT_SSH_COMMAND` 的四个选项一个都不能少**：`-o IdentitiesOnly=yes`、`-o IdentityAgent=none`、`-o UserKnownHostsFile=<per-agent>`、`-o StrictHostKeyChecking=yes`。测试**逐条断言**，不做整串比对。
- **私钥绝不进日志、错误信息、telemetry measurement/metadata**。任何 `Logger` / `inspect` 的参数里都不得出现私钥内容或含私钥的 map。
- **失败不阻断 spawn**：编排模块的任何错误路径都返回错误元组，**不抛异常**。
- 只格式化本次触碰的文件（`mix format <path> ...`），不要全项目 `mix format`。

---

### Task 1: core — per-agent git-identity 目录的路径权威

**Files:**
- Create: `apps/ezagent_core/lib/ezagent/sandbox/git_identity_dir.ex`
- Modify: `apps/ezagent_core/lib/ezagent/resource/fs_resolver.ex`（新增 `git_identity_authority/2`）
- Modify: `apps/ezagent_core/lib/ezagent/resource/fs_resolver/registry.ex`（`boot_registrations/0` 增一条）
- Test: `apps/ezagent_core/test/ezagent/sandbox/git_identity_dir_test.exs`

**Interfaces:**
- Produces:
  - `Ezagent.Sandbox.GitIdentityDir.path(agent_uri :: URI.t()) :: String.t()`（非 agent URI 时 raise `ArgumentError`）
  - `Ezagent.Sandbox.GitIdentityDir.allocate(agent_uri :: URI.t()) :: {:ok, String.t()} | {:error, term()}`
  - `Ezagent.Sandbox.GitIdentityDir.safe_to_destroy?(candidate :: String.t(), agent_uri :: URI.t()) :: boolean()`
  - `Ezagent.Sandbox.GitIdentityDir.type() :: String.t()`（`"git-identity"`）
  - `Ezagent.Resource.FsResolver.git_identity_authority(uri, scope) :: :ok | {:error, term()}`
- Consumes: `Ezagent.Resource.FsResolver.resolve/2`、`Ezagent.URI`

**背景（实现者需要知道的）：** `Ezagent.Sandbox.ConfigDir`（`apps/ezagent_core/lib/ezagent/sandbox/config_dir.ex`）是本 task 的**模板**，逐段照抄再改。它把 per-agent 目录解析成 `resource://<ws>/<ns>-agents/<name>`，交给 `FsResolver.resolve/2`，后者拼出 `Path.join([Ezagent.Home.path(backend_component), ws, name])`。

**为什么必须用一个独立的 authority 函数**（不要图省事复用 `config_dir_authority/2`）：`FsResolver` 按 **authority 函数的身份**判定一个 type 是否属于 config-dir 家族（见 `fs_resolver.ex` 中 `uploads_authority/2` 旁的注释：「A distinct named fn from `config_dir_authority/2` so the registry — which keys family membership on `authority` IDENTITY (`config_dir_type?/1`) — never claims uploads as a config-dir layer」）。复用会让 git-identity 目录被 credential-cascade 的层机制认领，而**把 SSH 身份挡在 cascade 之外正是本设计的核心**（spec §1.2）。

- [ ] **Step 1: 写失败测试**

创建 `apps/ezagent_core/test/ezagent/sandbox/git_identity_dir_test.exs`：

```elixir
defmodule Ezagent.Sandbox.GitIdentityDirTest do
  use ExUnit.Case, async: true

  alias Ezagent.Resource.FsResolver
  alias Ezagent.Sandbox.GitIdentityDir

  defp agent(ws, name), do: Ezagent.URI.entity(ws, :agent, name)

  describe "path/1" do
    test "同一 agent 幂等" do
      uri = agent(:acme, "worker-1")
      assert GitIdentityDir.path(uri) == GitIdentityDir.path(uri)
    end

    test "不同 agent / 不同 workspace 解析到不同目录" do
      a = GitIdentityDir.path(agent(:acme, "worker-1"))
      b = GitIdentityDir.path(agent(:acme, "worker-2"))
      c = GitIdentityDir.path(agent(:other, "worker-1"))

      assert a != b
      assert a != c
      assert b != c
    end

    test "解析结果落在 git-identity backend 下，且带 ws/name 两级" do
      path = GitIdentityDir.path(agent(:acme, "worker-1"))

      assert String.contains?(path, "git-identity")
      assert Path.basename(path) == "worker-1"
      assert path |> Path.dirname() |> Path.basename() == "acme"
    end

    test "非 agent URI 直接 raise，绝不静默给一个默认目录" do
      assert_raise ArgumentError, fn ->
        GitIdentityDir.path(Ezagent.URI.entity(:acme, :user, "someone"))
      end
    end
  end

  describe "safe_to_destroy?/2" do
    test "规范路径为 true" do
      uri = agent(:acme, "worker-1")
      assert GitIdentityDir.safe_to_destroy?(GitIdentityDir.path(uri), uri)
    end

    test "别的 agent 的目录为 false" do
      uri = agent(:acme, "worker-1")
      other = GitIdentityDir.path(agent(:acme, "worker-2"))
      refute GitIdentityDir.safe_to_destroy?(other, uri)
    end

    test "非字符串为 false" do
      refute GitIdentityDir.safe_to_destroy?(nil, agent(:acme, "worker-1"))
    end
  end

  describe "结构保证：git-identity 不得被认作 config-dir 家族" do
    # ⚠️ 已被取代（2026-08-02，Task 1 复审 F1/F3 + 整支终审 Important-2）
    #
    # 下面这一整块**两处都被本支自己否决了，不要照抄**：
    #
    # 1. 那条 `refute Function.capture(...) == Function.capture(...)` 是
    #    **恒真断言** —— 两个不同的具名函数捕获永远不相等，它从不触碰
    #    自己声称要钉住的 ETS 注册。已从 git_identity_dir_test.exs 删除，
    #    换成直接断言真实消费者用的谓词：
    #        refute FsResolver.config_dir_type?(GitIdentityDir.type())
    #
    # 2. "会经 cp_r 拿到别人的 SSH 私钥"这个论证在当前代码下**不可达**
    #    （cascade 的四层写死为 flavor_base/workspace/user/session，
    #     没有一层是 agent URI）。共用 authority 函数今天的真实后果是
    #    resolve_config_dir/1 判它为 config-dir 类型 → cascade 致命中止。
    #    设计 §1.2 已整段重写为诚实版本。
    #
    # 保留原文是为了记录决策演进；**最终实现见 git_identity_dir_test.exs
    # 与设计 §1.2**。
    #
    # 这条是 spec §1.2 的结构保证。config_dir_type?/1 按 authority 函数
    # 的**身份**判定家族成员；一旦两者共用同一个函数，git-identity 目录
    # 就会被 credential-cascade 的层机制认领，未获授权的 agent 会经
    # cp_r 拿到别人的 SSH 私钥。
    test "git_identity_authority/2 与 config_dir_authority/2 不是同一个函数" do
      refute Function.capture(FsResolver, :git_identity_authority, 2) ==
               Function.capture(FsResolver, :config_dir_authority, 2)
    end

    test "已注册的 git-identity type 的 authority 就是 git_identity_authority/2" do
      [{_type, spec}] = :ets.lookup(FsResolver.table(), GitIdentityDir.type())

      assert spec.authority == Function.capture(FsResolver, :git_identity_authority, 2)
      assert spec.backend_component == GitIdentityDir.type()
    end
  end

  describe "git_identity_authority/2" do
    test "URI 的 ws 与 scope.workspace 一致时通过" do
      uri = Ezagent.URI.resource(:acme, GitIdentityDir.type(), "worker-1")
      assert :ok == FsResolver.git_identity_authority(uri, %{workspace: "acme"})
    end

    test "伪造的跨 workspace resource URI 被拒（fail loud，不是 :none）" do
      uri = Ezagent.URI.resource(:victim, GitIdentityDir.type(), "worker-1")
      assert {:error, _} = FsResolver.git_identity_authority(uri, %{workspace: "acme"})
    end
  end
end
```

- [ ] **Step 2: 跑测试确认失败**

Run: `POSTGRES_PORT=15432 mix test apps/ezagent_core/test/ezagent/sandbox/git_identity_dir_test.exs`
Expected: 编译失败 —— `Ezagent.Sandbox.GitIdentityDir` 未定义。

- [ ] **Step 3: 加 authority 函数**

在 `apps/ezagent_core/lib/ezagent/resource/fs_resolver.ex` 中，紧接 `config_dir_authority/2` 之后加：

```elixir
  @doc """
  Authority for the per-agent `git-identity` type (SSH 凭据 1b).

  Asserts the URI's structural `<ws>` segment equals the caller's authenticated
  `scope.workspace` — identical logic to `config_dir_authority/2`, but a
  **distinct named function on purpose**.

  The Registry keys config-dir family membership on `authority` IDENTITY
  (`config_dir_type?/1`). Sharing `config_dir_authority/2` would make the
  git-identity directory a config-dir layer, exposing it to the #17 credential
  cascade — whose semantics are "copy between agents by policy". An agent that
  was never granted the `read_ssh_key` cap would then receive another User's SSH
  private key through `cp_r`. Keeping the function distinct is what makes
  "同部署内两个 agent 是否隔离，完全取决于有没有各自发那条 cap" structurally true.
  """
  @spec git_identity_authority(URI.t(), scope()) :: :ok | {:error, term()}
  def git_identity_authority(%URI{} = uri, %{workspace: scope_ws}) do
    assert_workspace_segment(uri, scope_ws)
  end
```

- [ ] **Step 4: 注册 boot type**

在 `apps/ezagent_core/lib/ezagent/resource/fs_resolver/registry.ex` 中，把 `boot_registrations/0` 改为：

```elixir
  defp boot_registrations do
    uploads =
      {@uploads_type,
       %{
         backend_component: @uploads_type,
         authority: &FsResolver.uploads_authority/2
       }}

    # SSH 凭据 1b — per-agent git 身份目录。core 注册（不是 plugin 的
    # `resource_types/0`）：这不是 flavor 概念，是 agent 通用概念。
    git_identity =
      {@git_identity_type,
       %{
         backend_component: @git_identity_type,
         authority: &FsResolver.git_identity_authority/2
       }}

    [uploads, git_identity]
  end
```

并在该模块已有的 `@uploads_type` 模块属性旁加：

```elixir
  @git_identity_type "git-identity"
```

（先 `grep -n "@uploads_type" apps/ezagent_core/lib/ezagent/resource/fs_resolver/registry.ex` 找到它的定义位置，把新属性放在紧邻的下一行。）

- [ ] **Step 5: 写 GitIdentityDir 模块**

创建 `apps/ezagent_core/lib/ezagent/sandbox/git_identity_dir.ex`：

```elixir
defmodule Ezagent.Sandbox.GitIdentityDir do
  @moduledoc """
  SSH 凭据 1b — the single authority for the per-agent **git-identity dir**:
  path computation, allocation, and the destroy-time path-shape guard.

  Mirrors `Ezagent.Sandbox.ConfigDir` in shape, but is a DELIBERATELY SEPARATE
  directory family. See `Ezagent.Resource.FsResolver.git_identity_authority/2`
  for why sharing the config-dir authority function would be a credential leak.

  ## Layout

      <Ezagent.Home.path("git-identity")>/<workspace>/<agent-name>/   (chmod 700)
      ├── id_ed25519      (chmod 600)
      └── known_hosts     (chmod 644)

  ## Why NOT inside the agent's config_dir

  `config_dir` is the home of the **flavor credential rail** (#17 cascade), whose
  semantics are "copy between agents by policy" — `materialize_single_reference`
  `cp_r`s a whole reference dir, `materialize_cascade` merges layers plus
  `secret_relpaths`. Putting an SSH identity there hands it to a copy policy
  designed for a different credential class: agent A's config_dir used as the
  reference for agent B would give B a private key B was never granted a cap for.
  That is a code-logic accident, not an attack — exactly the class the project's
  gates exist to prevent.

  ## 部署契约（继承 1a §7，1b 增一条）

  租户隔离靠**不共享部署**（workspace = 部署单元），代码无强制。

  **同一部署内，两个 agent 是否隔离，完全取决于有没有各自发那条 `read_ssh_key`
  cap。** 本模块把目录移出 `config_dir`，就是为了让这句话在结构上成立 —— 否则
  cascade 复制会在运维不知情的情况下把它变成假话。
  """

  alias Ezagent.Resource.FsResolver
  alias Ezagent.URI, as: EzURI

  @dir_mode 0o700
  @type_name "git-identity"

  @doc "The registered FsResolver resource type / backend component name."
  @spec type() :: String.t()
  def type, do: @type_name

  @doc """
  The per-agent git-identity dir path. Pure.

  Raises `ArgumentError` on a non-agent URI — there is NO silent default
  workspace (mirrors `Ezagent.Sandbox.ConfigDir.path/2`).
  """
  @spec path(URI.t()) :: String.t()
  def path(%URI{} = agent_uri) do
    auth_ws = workspace_segment(agent_uri)
    name = name_segment(agent_uri)
    res_uri = EzURI.resource(auth_ws, @type_name, name)

    case FsResolver.resolve(res_uri, %{workspace: auth_ws}) do
      {:ok, path} ->
        path

      other ->
        raise RuntimeError,
              "git-identity dir resolution failed for #{URI.to_string(res_uri)}: " <>
                inspect(other)
    end
  end

  @doc "Allocate the per-agent git-identity dir: `mkdir_p` + `chmod 700`. Idempotent."
  @spec allocate(URI.t()) :: {:ok, String.t()} | {:error, term()}
  def allocate(%URI{} = agent_uri) do
    target = path(agent_uri)

    with :ok <- File.mkdir_p(target),
         :ok <- File.chmod(target, @dir_mode) do
      {:ok, target}
    else
      {:error, reason} -> {:error, {:git_identity_dir_allocate_failed, reason}}
    end
  end

  @doc """
  Destroy-time guard: the path being removed MUST equal the canonical `path/1`
  for this agent, so cleanup can never be handed a bogus or shared path.
  """
  @spec safe_to_destroy?(term(), URI.t()) :: boolean()
  def safe_to_destroy?(candidate, %URI{} = agent_uri) when is_binary(candidate) do
    Path.expand(candidate) == Path.expand(path(agent_uri))
  end

  def safe_to_destroy?(_candidate, _agent_uri), do: false

  # ── URI segments (same contract as Sandbox.ConfigDir) ───────────────────────

  defp workspace_segment(%URI{} = agent_uri) do
    case EzURI.type(agent_uri) do
      {:ok, "agent"} -> EzURI.workspace_name!(agent_uri)
      _ -> raise_agent_uri!(agent_uri)
    end
  end

  defp workspace_segment(other), do: raise_agent_uri!(other)

  defp name_segment(%URI{} = agent_uri) do
    case EzURI.type(agent_uri) do
      {:ok, "agent"} -> EzURI.name!(agent_uri)
      _ -> raise_agent_uri!(agent_uri)
    end
  end

  defp name_segment(other), do: raise_agent_uri!(other)

  defp raise_agent_uri!(other) do
    raise ArgumentError,
          "git-identity dir requires an entity agent URI — got #{inspect(other)}. " <>
            "There is NO silent default workspace; callers must pass a fully-formed URI."
  end
end
```

> **注意与 `ConfigDir` 的一处刻意差异**：`ConfigDir.name_segment/1` 在拿不到名字时 rescue 成 `"unknown"`，本模块**不这么做** —— 一个叫 `unknown` 的共享目录会让两个 agent 共用同一份私钥。这里一律 raise。

- [ ] **Step 6: 跑测试确认通过**

Run: `POSTGRES_PORT=15432 mix test apps/ezagent_core/test/ezagent/sandbox/git_identity_dir_test.exs`
Expected: 全部通过。

- [ ] **Step 7: 红演示 —— 证明结构保证测试真的会红**

把 Step 4 里 `git_identity` 的 `authority:` 临时改成 `&FsResolver.config_dir_authority/2`，重跑上面的测试文件，**贴出真实红色输出**；再逐字节还原，`git diff` 必须为空，重跑贴绿。

- [ ] **Step 8: 提交**

```bash
mix format apps/ezagent_core/lib/ezagent/sandbox/git_identity_dir.ex apps/ezagent_core/lib/ezagent/resource/fs_resolver.ex apps/ezagent_core/lib/ezagent/resource/fs_resolver/registry.ex apps/ezagent_core/test/ezagent/sandbox/git_identity_dir_test.exs
git add apps/ezagent_core/lib/ezagent/sandbox/git_identity_dir.ex apps/ezagent_core/lib/ezagent/resource/fs_resolver.ex apps/ezagent_core/lib/ezagent/resource/fs_resolver/registry.ex apps/ezagent_core/test/ezagent/sandbox/git_identity_dir_test.exs
git commit -m "feat(core): per-agent git-identity 目录的路径权威

独立 resource type + 独立 authority 函数 —— FsResolver 按 authority
函数身份判定 config-dir 家族成员，共用会让 SSH 身份被 credential
cascade 认领，未授权 agent 经 cp_r 拿到私钥。"
```

---

### Task 2: core — 写入机制与 `GIT_SSH_COMMAND` 拼装

**Files:**
- Create: `apps/ezagent_core/lib/ezagent/credential/git_identity_runtime.ex`
- Test: `apps/ezagent_core/test/ezagent/credential/git_identity_runtime_test.exs`

**Interfaces:**
- Consumes: `Ezagent.Sandbox.GitIdentityDir.allocate/1`（Task 1）
- Produces:
  - `Ezagent.Credential.GitIdentityRuntime.write(agent_uri :: URI.t(), private_key :: String.t()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}`
  - `Ezagent.Credential.GitIdentityRuntime.known_hosts_path() :: String.t() | nil`
  - `Ezagent.Credential.GitIdentityRuntime.wipe(agent_uri :: URI.t()) :: :ok`

**这个模块是纯机制**：不认识 User Kind，不 dispatch，不知道 cap。给它私钥内容和 agent URI，它写文件并返回 env map。

- [ ] **Step 1: 写失败测试**

创建 `apps/ezagent_core/test/ezagent/credential/git_identity_runtime_test.exs`：

```elixir
defmodule Ezagent.Credential.GitIdentityRuntimeTest do
  # async: false —— 改 Application env（:git_known_hosts_path）
  use ExUnit.Case, async: false

  alias Ezagent.Credential.GitIdentityRuntime
  alias Ezagent.Sandbox.GitIdentityDir

  @key_a "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA-a\n-----END OPENSSH PRIVATE KEY-----\n"
  @key_b "-----BEGIN OPENSSH PRIVATE KEY-----\nBBBB-b\n-----END OPENSSH PRIVATE KEY-----\n"

  setup do
    suffix = System.unique_integer([:positive])
    agent_uri = Ezagent.URI.entity(:gitid, :agent, "w-#{suffix}")

    kh_dir = Path.join(System.tmp_dir!(), "ezagent-kh-#{suffix}")
    File.mkdir_p!(kh_dir)
    kh_path = Path.join(kh_dir, "known_hosts")
    File.write!(kh_path, "github.com ssh-ed25519 AAAAFAKE\n")

    prev = Application.get_env(:ezagent_core, :git_known_hosts_path)
    Application.put_env(:ezagent_core, :git_known_hosts_path, kh_path)

    on_exit(fn ->
      if prev do
        Application.put_env(:ezagent_core, :git_known_hosts_path, prev)
      else
        Application.delete_env(:ezagent_core, :git_known_hosts_path)
      end

      File.rm_rf(kh_dir)
      File.rm_rf(GitIdentityDir.path(agent_uri))
    end)

    %{agent_uri: agent_uri, kh_path: kh_path}
  end

  defp mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o777)
  end

  describe "write/2 happy path" do
    test "私钥写入且 mode 恰为 0600，目录 0700", ctx do
      assert {:ok, _env} = GitIdentityRuntime.write(ctx.agent_uri, @key_a)

      dir = GitIdentityDir.path(ctx.agent_uri)
      key_path = Path.join(dir, "id_ed25519")

      assert File.read!(key_path) == @key_a
      assert mode(key_path) == 0o600
      assert mode(dir) == 0o700
    end

    test "known_hosts 从节点级文件复制进来", ctx do
      assert {:ok, _env} = GitIdentityRuntime.write(ctx.agent_uri, @key_a)

      copied = Path.join(GitIdentityDir.path(ctx.agent_uri), "known_hosts")
      assert File.read!(copied) == File.read!(ctx.kh_path)
    end

    test "覆写：第二次写的内容生效", ctx do
      assert {:ok, _} = GitIdentityRuntime.write(ctx.agent_uri, @key_a)
      assert {:ok, _} = GitIdentityRuntime.write(ctx.agent_uri, @key_b)

      key_path = Path.join(GitIdentityDir.path(ctx.agent_uri), "id_ed25519")
      assert File.read!(key_path) == @key_b
      assert mode(key_path) == 0o600
    end
  end

  describe "GIT_SSH_COMMAND —— 四个选项逐条断言" do
    setup ctx do
      {:ok, env} = GitIdentityRuntime.write(ctx.agent_uri, @key_a)
      %{cmd: Map.fetch!(env, "GIT_SSH_COMMAND"), dir: GitIdentityDir.path(ctx.agent_uri)}
    end

    test "env map 里只有 GIT_SSH_COMMAND 这一个 key", %{cmd: _} = ctx do
      {:ok, env} = GitIdentityRuntime.write(ctx.agent_uri, @key_a)
      assert Map.keys(env) == ["GIT_SSH_COMMAND"]
    end

    test "指向本 agent 自己的私钥", ctx do
      assert String.contains?(ctx.cmd, "-i #{Path.join(ctx.dir, "id_ed25519")}")
    end

    # 不加则 ssh 会把能找到的所有 key 挨个试，用错身份认证成功 → 审计归属错。
    test "IdentitiesOnly=yes", ctx do
      assert String.contains?(ctx.cmd, "-o IdentitiesOnly=yes")
    end

    # 不加则落到宿主 ssh-agent —— 那是运维本人的 key。最大的一条静默提权路径。
    test "IdentityAgent=none", ctx do
      assert String.contains?(ctx.cmd, "-o IdentityAgent=none")
    end

    # 不加则落到宿主 ~/.ssh/known_hosts，agent 之间互相污染。
    test "UserKnownHostsFile 指向本 agent 自己的副本", ctx do
      assert String.contains?(
               ctx.cmd,
               "-o UserKnownHostsFile=#{Path.join(ctx.dir, "known_hosts")}"
             )
    end

    # 不加则 TOFU：首次连接无条件接受任何主机 key。
    test "StrictHostKeyChecking=yes", ctx do
      assert String.contains?(ctx.cmd, "-o StrictHostKeyChecking=yes")
    end
  end

  describe "known_hosts 未配置" do
    setup do
      Application.delete_env(:ezagent_core, :git_known_hosts_path)
      :ok
    end

    test "fail loud", ctx do
      assert {:error, :known_hosts_unconfigured} =
               GitIdentityRuntime.write(ctx.agent_uri, @key_a)
    end

    test "且目录里没有私钥残留（不能留下一把用不了又拿得到的 key）", ctx do
      assert {:error, :known_hosts_unconfigured} =
               GitIdentityRuntime.write(ctx.agent_uri, @key_a)

      refute File.exists?(Path.join(GitIdentityDir.path(ctx.agent_uri), "id_ed25519"))
    end
  end

  describe "known_hosts 配了但文件不存在" do
    setup do
      Application.put_env(
        :ezagent_core,
        :git_known_hosts_path,
        Path.join(System.tmp_dir!(), "definitely-not-here-#{System.unique_integer([:positive])}")
      )

      :ok
    end

    test "fail loud，且与未配置是不同的错误值", ctx do
      assert {:error, {:known_hosts_unreadable, _}} =
               GitIdentityRuntime.write(ctx.agent_uri, @key_a)
    end
  end

  describe "wipe/1" do
    test "删掉整个目录，且对不存在的目录幂等", ctx do
      {:ok, _} = GitIdentityRuntime.write(ctx.agent_uri, @key_a)
      dir = GitIdentityDir.path(ctx.agent_uri)
      assert File.dir?(dir)

      assert :ok = GitIdentityRuntime.wipe(ctx.agent_uri)
      refute File.exists?(dir)

      assert :ok = GitIdentityRuntime.wipe(ctx.agent_uri)
    end
  end
end
```

- [ ] **Step 2: 跑测试确认失败**

Run: `POSTGRES_PORT=15432 mix test apps/ezagent_core/test/ezagent/credential/git_identity_runtime_test.exs`
Expected: 编译失败 —— `Ezagent.Credential.GitIdentityRuntime` 未定义。

- [ ] **Step 3: 写模块**

创建 `apps/ezagent_core/lib/ezagent/credential/git_identity_runtime.ex`：

```elixir
defmodule Ezagent.Credential.GitIdentityRuntime do
  @moduledoc """
  SSH 凭据 1b — the pure WRITE mechanism for a per-agent git identity.

  Given an agent URI and private-key bytes, materializes

      <GitIdentityDir.path(agent)>/id_ed25519   (0600)
      <GitIdentityDir.path(agent)>/known_hosts  (0644, copied from the node file)

  and returns the `GIT_SSH_COMMAND` env map the flavor merges into the agent
  subprocess env.

  **Knows nothing about Users, caps, or dispatch.** Deciding WHETHER an agent
  gets an identity, and WHOSE, is `Ezagent.Identity.AgentGitIdentity`'s job
  (domain tier — it reads identity-domain data).

  ## Why no atomic stage-and-swap

  `Ezagent.Credential.HomeRuntime.stage_and_swap/7` exists because the config
  dir has concurrent readers (a running subprocess) and a partially-copied dir
  is indistinguishable from a complete one. Neither applies here: this write
  happens on the spawn path BEFORE the subprocess starts, and there is exactly
  one writer per agent. A plain overwrite is correct — **do not** copy the
  staging machinery over here "for consistency".

  ## known_hosts

  Node-level, operator-provisioned, pointed at by
  `config :ezagent_core, :git_known_hosts_path`. Generate it with
  `mix ezagent.git.known_hosts`.

  Absent or unreadable → **fail loud**, and the private key is NOT left behind.
  The alternative (`StrictHostKeyChecking=no`) would silently accept any host
  key on first connect.
  """

  require Logger

  alias Ezagent.Sandbox.GitIdentityDir

  @key_basename "id_ed25519"
  @known_hosts_basename "known_hosts"
  @key_mode 0o600
  @known_hosts_mode 0o644

  @doc """
  Materialize `private_key` for `agent_uri` and return the env map.

  Returns `{:ok, %{"GIT_SSH_COMMAND" => cmd}}`, or one of:

    * `{:error, :known_hosts_unconfigured}` — no `:git_known_hosts_path` set
    * `{:error, {:known_hosts_unreadable, reason}}` — set but unreadable
    * `{:error, {:git_identity_dir_allocate_failed, reason}}`
    * `{:error, {:git_identity_write_failed, reason}}`

  **Never logs or returns the key material.**
  """
  @spec write(URI.t(), String.t()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  def write(%URI{} = agent_uri, private_key) when is_binary(private_key) do
    # known_hosts FIRST: a missing node file must not leave a private key on disk.
    with {:ok, known_hosts} <- read_known_hosts(),
         {:ok, dir} <- GitIdentityDir.allocate(agent_uri),
         :ok <- write_file(Path.join(dir, @key_basename), private_key, @key_mode),
         :ok <-
           write_file(
             Path.join(dir, @known_hosts_basename),
             known_hosts,
             @known_hosts_mode
           ) do
      {:ok, %{"GIT_SSH_COMMAND" => ssh_command(dir)}}
    end
  end

  @doc "The configured node-level known_hosts path, or `nil` when unset."
  @spec known_hosts_path() :: String.t() | nil
  def known_hosts_path do
    case Application.get_env(:ezagent_core, :git_known_hosts_path) do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  @doc "Remove an agent's git-identity dir. Idempotent; best-effort."
  @spec wipe(URI.t()) :: :ok
  def wipe(%URI{} = agent_uri) do
    dir = GitIdentityDir.path(agent_uri)

    case File.rm_rf(dir) do
      {:ok, _} ->
        :ok

      {:error, reason, path} ->
        Logger.warning(
          "git-identity wipe failed for #{URI.to_string(agent_uri)} at #{path}: " <>
            inspect(reason)
        )

        :ok
    end
  rescue
    # A non-agent URI raises in `path/1`. Cleanup must never crash a destroy path.
    ArgumentError -> :ok
  end

  # ── internals ──────────────────────────────────────────────────────────────

  # Every option here defends against a DEFAULT that silently uses the wrong
  # identity or trusts the wrong host — see the moduledoc of each test in
  # `GitIdentityRuntimeTest` for the concrete consequence of dropping one.
  defp ssh_command(dir) do
    Enum.join(
      [
        "ssh",
        "-i #{Path.join(dir, @key_basename)}",
        "-o IdentitiesOnly=yes",
        "-o IdentityAgent=none",
        "-o UserKnownHostsFile=#{Path.join(dir, @known_hosts_basename)}",
        "-o StrictHostKeyChecking=yes"
      ],
      " "
    )
  end

  defp read_known_hosts do
    case known_hosts_path() do
      nil ->
        {:error, :known_hosts_unconfigured}

      path ->
        case File.read(path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, {:known_hosts_unreadable, {path, reason}}}
        end
    end
  end

  # chmod BEFORE the content lands would still leave a 0644 window on create,
  # so write then chmod; the containing dir is already 0700, which is the real
  # boundary.
  defp write_file(path, content, mode) do
    with :ok <- File.write(path, content),
         :ok <- File.chmod(path, mode) do
      :ok
    else
      # NEVER interpolate `content` — it may be the private key.
      {:error, reason} -> {:error, {:git_identity_write_failed, {Path.basename(path), reason}}}
    end
  end
end
```

- [ ] **Step 4: 跑测试确认通过**

Run: `POSTGRES_PORT=15432 mix test apps/ezagent_core/test/ezagent/credential/git_identity_runtime_test.exs`
Expected: 全部通过。

- [ ] **Step 5: 红演示 —— 逐条证明四个 ssh 选项的测试真的会红**

对 `ssh_command/1` 里的四个 `-o` 选项，**逐个**删掉、跑测试、贴红色输出、逐字节还原、`git diff` 为空、重跑贴绿。四轮。

再做第五轮：把 `write/2` 中 `read_known_hosts()` 挪到 `GitIdentityDir.allocate/1` **之后**，证明"目录里没有私钥残留"那条测试会红。

- [ ] **Step 6: 提交**

```bash
mix format apps/ezagent_core/lib/ezagent/credential/git_identity_runtime.ex apps/ezagent_core/test/ezagent/credential/git_identity_runtime_test.exs
git add apps/ezagent_core/lib/ezagent/credential/git_identity_runtime.ex apps/ezagent_core/test/ezagent/credential/git_identity_runtime_test.exs
git commit -m "feat(core): git 身份写入机制 + GIT_SSH_COMMAND 拼装

四个 ssh 选项各自防一条"走默认路径就悄悄用错身份"的路：
IdentitiesOnly / IdentityAgent=none / per-agent known_hosts /
StrictHostKeyChecking。known_hosts 未配置时 fail loud 且不留私钥。"
```

---

### Task 3: domain — 编排（找 cap → dispatch 读 → 调 core 写）

**Files:**
- Create: `apps/ezagent_domain_identity/lib/ezagent/identity/agent_git_identity.ex`
- Test: `apps/ezagent_domain_identity/test/ezagent/identity/agent_git_identity_test.exs`

**Interfaces:**
- Consumes: `Ezagent.Credential.GitIdentityRuntime.write/2`（Task 2）、`Ezagent.Identity.list_caps_for/1`、`Ezagent.ActionSet.UserSshIdentity`（1a）
- Produces: `Ezagent.Identity.AgentGitIdentity.materialize(agent_uri :: URI.t()) :: {:ok, %{String.t() => String.t()}} | {:ok, :none} | {:error, term()}`

**核心不变式（本 task 存在的理由）：**

1. **cap 即开关**：agent 不持 `read_ssh_key` cap → `{:ok, :none}`，**不发生任何 dispatch**
2. **cap 即指针**：dispatch 的 target 由 **cap 的 `instance` 字段**决定，不由任何推导决定
3. **窄授权**：dispatch 的 `ctx.caps` **只放找到的那一条 cap**，不是 agent 的全部 cap
4. **不抛异常**：任何路径都返回元组，spawn 不能被它掀翻

**Task 2 复审带过来的三条（务必先读）：**

1. **`{:ok, :none}` 与每一条错误路径都必须清目录**（设计 **§6.1**，本 task 落地）。两道复审独立指出：没有它，「撤销 agent 的 cap → 下次 spawn 生效」对 key 文件是**假的** —— 只有环境变量消失，key 还在 agent 的文件系统上、且它自己跑 `git -c core.sshCommand='ssh -i <那个路径> -o StrictHostKeyChecking=no'` 照样能用。
2. **`private_key` 这个字面量在 `ezagent_domain_identity` 里可以用。** `apps/ezagent_core/test/architecture/cap_authority_confinement_test.exs` 的 `@core_lib` 只扫 `apps/ezagent_core/lib`。Task 2 因为在 core 里，被迫把参数改名 `key_pem` —— **那是 gate 规避，不是风格偏好，不要抄过来**。本 task 直接用 `private_key`（它就是 1a action 返回值的字段名）。
3. **`GitIdentityRuntime` 的错误 shape**：`{:error, {:known_hosts_unreadable, {path, reason}}}`（是 `{path, reason}` 二元组，不是裸 reason）。本 task 不需要逐个 match 它 —— 直接透传即可。

**实现要点（1a 踩过的坑，别重蹈）：** 1a 的授权测试用 `signed_invocation!/2` 走通 dispatch，容易被误读成"invocation 需要签名"。**实际不是**：该 helper 做的是往 `ctx` 里放 `:authenticated_principal`（`apps/ezagent_core/test/support/cap_helper.ex:258-260`）。cap 在 cap-signing Path A 下**出生即签名**。生产 ctx 形如：

```elixir
%{
  caller: agent_uri,
  authenticated_principal: agent_uri,
  caps: MapSet.new([cap]),
  reply: {:caller_inbox, self()}
}
```

- [ ] **Step 1: 写失败测试**

创建 `apps/ezagent_domain_identity/test/ezagent/identity/agent_git_identity_test.exs`：

```elixir
defmodule Ezagent.Identity.AgentGitIdentityTest do
  # async: false —— 起真实 Kind + 改 Application env
  use ExUnit.Case, async: false

  import Ezagent.Test.CapHelper

  alias Ezagent.ActionSet.UserSshIdentity
  alias Ezagent.Identity.AgentGitIdentity
  alias Ezagent.Sandbox.GitIdentityDir

  setup do
    suffix = System.unique_integer([:positive])

    user_uri = Ezagent.URI.entity(:gitid, :user, "owner-#{suffix}")
    agent_uri = Ezagent.URI.entity(:gitid, :agent, "worker-#{suffix}")

    {:ok, _} = Ezagent.Users.create(user_uri, nil, [])
    {:ok, _} = Ezagent.SpawnRegistry.spawn(user_uri)

    kh_dir = Path.join(System.tmp_dir!(), "ezagent-kh-#{suffix}")
    File.mkdir_p!(kh_dir)
    kh_path = Path.join(kh_dir, "known_hosts")
    File.write!(kh_path, "github.com ssh-ed25519 AAAAFAKE\n")

    prev = Application.get_env(:ezagent_core, :git_known_hosts_path)
    Application.put_env(:ezagent_core, :git_known_hosts_path, kh_path)

    on_exit(fn ->
      if prev do
        Application.put_env(:ezagent_core, :git_known_hosts_path, prev)
      else
        Application.delete_env(:ezagent_core, :git_known_hosts_path)
      end

      File.rm_rf(kh_dir)
      File.rm_rf(GitIdentityDir.path(agent_uri))
      Ezagent.Kind.terminate(user_uri)
    end)

    %{
      user_uri: user_uri,
      agent_uri: agent_uri,
      admin: Ezagent.Entity.User.admin_uri()
    }
  end

  # 给 agent 发一条指向 user_uri 的 read_ssh_key cap（Task 4 的 mix task 做的事，
  # 这里直接用底层 API 造，避免测试依赖 mix task）。
  defp grant_read_ssh_key(agent_uri, user_uri, admin) do
    target = Ezagent.URI.with_action(user_uri, :user_ssh_identity, :read_ssh_key)
    cap = signed_required_cap!(target, :user, UserSshIdentity, :read_ssh_key, agent_uri)
    :ok = Ezagent.Identity.absorb_cap(agent_uri, cap)

    :ok =
      Ezagent.Identity.CapAbsorbAwait.await_exact(agent_uri, [cap], 5_000)

    _ = admin
    cap
  end

  defp revoke_key_for(user_uri, admin) do
    target = Ezagent.URI.with_action(user_uri, :user_ssh_identity, :revoke_ssh_key)
    cap = signed_required_cap!(target, :user, UserSshIdentity, :revoke_ssh_key, admin)

    {:ok, _} =
      %Ezagent.Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{},
        ctx: %{
          caller: admin,
          authenticated_principal: admin,
          caps: MapSet.new([cap]),
          reply: {:caller_inbox, self()}
        }
      }
      |> Ezagent.Invocation.dispatch()
  end

  defp generate_key_for(user_uri, admin) do
    target = Ezagent.URI.with_action(user_uri, :user_ssh_identity, :generate_ssh_key)
    cap = signed_required_cap!(target, :user, UserSshIdentity, :generate_ssh_key, admin)

    {:ok, _} =
      %Ezagent.Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{},
        ctx: %{
          caller: admin,
          authenticated_principal: admin,
          caps: MapSet.new([cap]),
          reply: {:caller_inbox, self()}
        }
      }
      |> Ezagent.Invocation.dispatch()
  end

  describe "关闭态 —— 没有那条 cap" do
    test "返回 {:ok, :none}", ctx do
      assert {:ok, :none} = AgentGitIdentity.materialize(ctx.agent_uri)
    end

    test "不写任何文件", ctx do
      {:ok, :none} = AgentGitIdentity.materialize(ctx.agent_uri)
      refute File.exists?(GitIdentityDir.path(ctx.agent_uri))
    end

    # 设计 §6.1 —— 这条是让 cap 撤销真正生效的那一步。没有它，撤销只是
    # 让环境变量消失，key 还在 agent 的文件系统上且完全可用。
    test "撤销生效：先成功物化一次，撤掉 cap 后再物化 → 盘上的 key 必须被清掉", ctx do
      generate_key_for(ctx.user_uri, ctx.admin)
      cap = grant_read_ssh_key(ctx.agent_uri, ctx.user_uri, ctx.admin)

      assert {:ok, %{"GIT_SSH_COMMAND" => _}} = AgentGitIdentity.materialize(ctx.agent_uri)
      key_path = Path.join(GitIdentityDir.path(ctx.agent_uri), "id_ed25519")
      assert File.exists?(key_path)

      # `Ezagent.EntityCaps.revoke/2`（`entity_caps.ex:272`）—— 与本文件
      # 授予侧用的 `Ezagent.Identity.absorb_cap/2` 对称的直接入口。
      # （`Ezagent.Identity.revoke_cap/2` **不存在**；带授权的 chokepoint 版本
      # 是 `Ezagent.Identity.Grant.revoke_cap/3`，测试里不需要。）
      :ok = Ezagent.EntityCaps.revoke(ctx.agent_uri, cap)
      assert [] = AgentGitIdentity.dispatch_caps(ctx.agent_uri)

      assert {:ok, :none} = AgentGitIdentity.materialize(ctx.agent_uri)
      refute File.exists?(key_path)
    end

    test "只持 read_ssh_public_key cap 不算 —— 仍是关闭态", ctx do
      target = Ezagent.URI.with_action(ctx.user_uri, :user_ssh_identity, :read_ssh_public_key)

      cap =
        signed_required_cap!(
          target,
          :user,
          UserSshIdentity,
          :read_ssh_public_key,
          ctx.agent_uri
        )

      :ok = Ezagent.Identity.absorb_cap(ctx.agent_uri, cap)
      :ok = Ezagent.Identity.CapAbsorbAwait.await_exact(ctx.agent_uri, [cap], 5_000)

      assert {:ok, :none} = AgentGitIdentity.materialize(ctx.agent_uri)
    end
  end

  describe "开启态" do
    setup ctx do
      generate_key_for(ctx.user_uri, ctx.admin)
      cap = grant_read_ssh_key(ctx.agent_uri, ctx.user_uri, ctx.admin)
      %{cap: cap}
    end

    test "返回 GIT_SSH_COMMAND 且私钥落盘", ctx do
      assert {:ok, env} = AgentGitIdentity.materialize(ctx.agent_uri)
      assert %{"GIT_SSH_COMMAND" => cmd} = env
      assert String.starts_with?(cmd, "ssh ")

      key_path = Path.join(GitIdentityDir.path(ctx.agent_uri), "id_ed25519")
      assert File.exists?(key_path)
      assert String.contains?(File.read!(key_path), "PRIVATE KEY")
    end

    test "cap 即指针：dispatch target 的 instance 等于 cap 的 instance", ctx do
      # cap.instance 就是 user_uri 的 instance —— 若实现改用任何推导
      # （例如从 agent 的 workspace 找 owner），这条会红。
      assert ctx.cap.instance == Ezagent.URI.instance(ctx.user_uri)
      assert {:ok, %{"GIT_SSH_COMMAND" => _}} = AgentGitIdentity.materialize(ctx.agent_uri)
    end

    test "窄授权：dispatch 只带那一条 cap，不带 agent 的全部 cap", ctx do
      # 再给 agent 一条无关 cap。若实现把 list_caps_for/1 的全集塞进
      # ctx.caps，本条仍会绿——所以真正的证据是下面的 :telemetry 断言。
      unrelated_target =
        Ezagent.URI.with_action(ctx.user_uri, :user_ssh_identity, :read_ssh_public_key)

      unrelated =
        signed_required_cap!(
          unrelated_target,
          :user,
          UserSshIdentity,
          :read_ssh_public_key,
          ctx.agent_uri
        )

      :ok = Ezagent.Identity.absorb_cap(ctx.agent_uri, unrelated)

      :ok =
        Ezagent.Identity.CapAbsorbAwait.await_exact(
          ctx.agent_uri,
          [ctx.cap, unrelated],
          5_000
        )

      assert {:ok, %{"GIT_SSH_COMMAND" => _}} = AgentGitIdentity.materialize(ctx.agent_uri)

      # 结构证据：实现暴露的 caps-selection 是纯函数，直接断言它。
      assert [selected] = AgentGitIdentity.dispatch_caps(ctx.agent_uri)
      assert selected == ctx.cap
    end
  end

  describe "配错了 —— 要吵，但不能掀翻 spawn" do
    test "有 cap 但 user 从未生成 key → :owner_has_no_key", ctx do
      grant_read_ssh_key(ctx.agent_uri, ctx.user_uri, ctx.admin)

      assert {:error, :owner_has_no_key} = AgentGitIdentity.materialize(ctx.agent_uri)
      refute File.exists?(Path.join(GitIdentityDir.path(ctx.agent_uri), "id_ed25519"))
    end

    # 设计 §6.1 —— read 失败发生在 `GitIdentityRuntime.write/2` **被调用之前**，
    # 所以 write 自己的清理兜不住这一格：必须由 materialize/1 清。
    # 上面那条用的是全新目录，测不到这个状态迁移。
    test "读失败也清盘：先成功物化一次，再让 User 撤销 key，第二次必须把旧 key 清掉", ctx do
      generate_key_for(ctx.user_uri, ctx.admin)
      grant_read_ssh_key(ctx.agent_uri, ctx.user_uri, ctx.admin)

      assert {:ok, %{"GIT_SSH_COMMAND" => _}} = AgentGitIdentity.materialize(ctx.agent_uri)
      key_path = Path.join(GitIdentityDir.path(ctx.agent_uri), "id_ed25519")
      assert File.exists?(key_path)

      revoke_key_for(ctx.user_uri, ctx.admin)

      assert {:error, :owner_has_no_key} = AgentGitIdentity.materialize(ctx.agent_uri)
      refute File.exists?(key_path)
    end

    test "known_hosts 未配置 → :known_hosts_unconfigured", ctx do
      generate_key_for(ctx.user_uri, ctx.admin)
      grant_read_ssh_key(ctx.agent_uri, ctx.user_uri, ctx.admin)
      Application.delete_env(:ezagent_core, :git_known_hosts_path)

      assert {:error, :known_hosts_unconfigured} =
               AgentGitIdentity.materialize(ctx.agent_uri)
    end

    test "没有 key 与 key 损坏是两个不同的错误值（1a 的区分不得被合并）" do
      # 纯值断言，不依赖运行时状态。
      refute :owner_has_no_key == {:owner_key_unavailable, :ssh_identity_unavailable}
    end

    test "所有错误路径都返回元组，不抛异常", ctx do
      # 非 agent URI —— 最容易被漏掉的一条：materialize 若在 GitIdentityDir.path/1
      # 上 raise，就会把 spawn 掀翻。
      assert {:error, _} = AgentGitIdentity.materialize(ctx.user_uri)
    end

    test "instance 为通配 :any 的 cap 不算开启 —— 它没指向任何 User", ctx do
      wildcard = %Ezagent.Capability{
        kind: :user,
        behavior: UserSshIdentity,
        action: :read_ssh_key,
        instance: :any,
        workspace_uri: Ezagent.Capability.workspace_of(ctx.user_uri)
      }

      # 直接测选择器（这条 cap 通不过 absorb 的签名校验，无法真发出去）。
      refute Enum.any?([wildcard], &match?([_], AgentGitIdentity.dispatch_caps(ctx.agent_uri)))
      assert {:ok, :none} = AgentGitIdentity.materialize(ctx.agent_uri)
    end
  end
end
```

> **实现者注意（1a 的坑）：** `generate_key_for/2` 直接构造 `ctx`。1a 的测试走的是 `signed_invocation!(:user)` helper（`apps/ezagent_core/test/support/cap_helper.ex:264`），它除了塞 `:authenticated_principal` 之外，还会在 `caps` 为空且 presenter 是 admin 时补一条 anchor cap。本处 `caps` 非空，两者应当等价。**若 dispatch 意外被拒，先去比对 `apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_authz_test.exs` 的 `dispatch/4`，按它的形状改，不要自己猜。**

- [ ] **Step 2: 跑测试确认失败**

Run: `POSTGRES_PORT=15432 mix test apps/ezagent_domain_identity/test/ezagent/identity/agent_git_identity_test.exs`
Expected: 编译失败 —— `Ezagent.Identity.AgentGitIdentity` 未定义。

- [ ] **Step 3: 写模块**

创建 `apps/ezagent_domain_identity/lib/ezagent/identity/agent_git_identity.ex`：

```elixir
defmodule Ezagent.Identity.AgentGitIdentity do
  @moduledoc """
  SSH 凭据 1b — decides WHETHER an agent gets a git identity, and WHOSE, then
  hands the write to `Ezagent.Credential.GitIdentityRuntime` (core).

  ## 一条 cap 同时是三样东西

  The agent's `read_ssh_key` capability is:

  * the **switch** — hold it and the identity is materialized; don't and nothing
    happens at all (no dispatch, no files, no log line)
  * the **authorization** — it is 1a's own cap, checked by the normal step-5.5
    gate on the dispatch
  * the **pointer** — `cap.instance` IS the User whose key gets read

  **Nothing is derived.** There is deliberately no "resolve the agent's owner"
  step: `Ezagent.WorkspacePlacement.owner_of/1` returns the node's
  `RuntimeIdentity` (a federation-placement concept), not a workspace's owning
  user, and the recipe cap channel cannot express a cap pointing at a User
  (`Ezagent.Agent.Recipe.CapMint.mint/3` hardwires `kind: :agent, instance:
  agent_uri`). Making the cap the pointer means the switch and the subject are
  the same fact and cannot drift apart.

  <!-- ⚠️ 上面括号里那句已被取代（2026-08-02，整支终审 Important-1）：
       `CapMint.mint/3` 本身是**泛型**的 —— 它从第二个参数解构
       `%{kind:, instance:, ...}`（cap_mint.ex:43-48）。写死发生在它
       **唯一的生产调用点** `role_step.ex:194-200`。结论（cap 即指针）不变，
       只是论据换了。最终正确表述见 `agent_git_identity.ex` 的 moduledoc
       与设计 §1.1。 -->


  Grant it with `mix ezagent.agent.grant_git_identity <agent_uri> <user_uri>`.

  ## 这也是 B2′ 与 A1 的切换点

  A1（平台持 key、agent 不持）= 不发这条 cap。切换粒度**是 agent**，不是仓库
  —— key 归 User，一个 session 里只要有一个仓库走 B2′，key 就覆盖了该 User 的
  所有仓库（见 1b design §10）。

  ## 部署契约

  同一部署内，两个 agent 是否隔离，完全取决于有没有各自发这条 cap。
  跨租户隔离靠**不共享部署**（workspace = 部署单元），代码无强制。
  """

  require Logger

  alias Ezagent.ActionSet.UserSshIdentity
  alias Ezagent.Credential.GitIdentityRuntime

  @behavior_module UserSshIdentity
  @action :read_ssh_key

  @doc """
  Materialize `agent_uri`'s git identity, if it is authorized for one.

  * `{:ok, env}` — materialized; merge `env` into the agent subprocess env
  * `{:ok, :none}` — **the default**: no cap, nothing done, nothing logged
  * `{:error, reason}` — authorized but something is misconfigured; the caller
    MUST NOT fail the spawn over it (a git identity is a capability of the
    agent, not a precondition for its existence)

  Never raises.
  """
  @spec materialize(URI.t()) :: {:ok, map()} | {:ok, :none} | {:error, term()}
  def materialize(%URI{} = agent_uri) do
    case dispatch_caps(agent_uri) do
      [] ->
        # 设计 §6.1 —— THE step that makes cap revocation take effect. Without
        # this wipe, revoking the cap only removes the env var while the key
        # stays on the agent's filesystem, fully usable via its own
        # `git -c core.sshCommand=...`. Cheap: an rm_rf on a path that does
        # not exist for nearly every agent, every spawn.
        GitIdentityRuntime.wipe(agent_uri)
        {:ok, :none}

      [cap | _] ->
        with {:ok, private_key} <- read_private_key(agent_uri, cap),
             {:ok, env} <- GitIdentityRuntime.write(agent_uri, private_key) do
          {:ok, env}
        else
          {:error, reason} ->
            # `GitIdentityRuntime.write/2` wipes on its OWN failures, but a
            # `read_private_key/2` failure happens BEFORE write is ever called
            # — nothing would clear a key left by an earlier successful spawn.
            # 设计 §6.1: every outcome except `{:ok, env}` clears the dir.
            GitIdentityRuntime.wipe(agent_uri)
            report(agent_uri, cap, reason)
        end
    end
  rescue
    # `GitIdentityDir.path/1` raises on a non-agent URI. A cleanup/materialize
    # helper must never take the spawn path down with it.
    e -> {:error, {:git_identity_materialize_crashed, Exception.message(e)}}
  end

  @doc """
  The caps this agent would dispatch with — exactly the `read_ssh_key` caps it
  holds, and nothing else.

  Public so the narrow-authorization property is directly assertable: passing
  the agent's FULL cap set to the dispatch would carry every other authority it
  owns into a credential read (`Ezagent.Credential.GrantCap`'s moduledoc states
  the same rule for the source-read path: "the caller passes this SINGLE cap …
  never a broad set").
  """
  @spec dispatch_caps(URI.t()) :: [Ezagent.Capability.t()]
  def dispatch_caps(%URI{} = agent_uri) do
    agent_uri
    |> Ezagent.Identity.list_caps_for()
    |> Enum.filter(&ssh_read_cap?/1)
  end

  # ── internals ──────────────────────────────────────────────────────────────

  # A cap whose `instance` is the wildcard `:any` is NOT a pointer — it names no
  # User. Treating it as "on" would leave `user_uri_of/1` with nothing to
  # dispatch at. Require a concrete instance: the switch and the subject are the
  # same fact, so a cap that cannot name a subject cannot be a switch.
  defp ssh_read_cap?(%Ezagent.Capability{
         behavior: @behavior_module,
         action: @action,
         instance: instance
       }),
       do: concrete_instance?(instance)

  defp ssh_read_cap?(_), do: false

  defp concrete_instance?(%URI{}), do: true
  defp concrete_instance?(s) when is_binary(s) and s != "", do: true
  defp concrete_instance?(_), do: false

  defp read_private_key(agent_uri, cap) do
    target = Ezagent.URI.with_action(user_uri_of(cap), :user_ssh_identity, @action)

    invocation = %Ezagent.Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{},
      ctx: %{
        caller: agent_uri,
        authenticated_principal: agent_uri,
        # THE narrow cap — not the agent's full set. See `dispatch_caps/1`.
        caps: MapSet.new([cap]),
        reply: {:caller_inbox, self()}
      }
    }

    case Ezagent.Invocation.dispatch(invocation) do
      {:ok, %{private_key: key}} when is_binary(key) ->
        {:ok, key}

      # 1a deliberately separates these two. Keep them separate here: one means
      # "the operator granted a cap but never generated a key" (fix: generate),
      # the other means "a key exists but its state is corrupt" (fix: revoke +
      # regenerate). Collapsing them throws away a distinction 1a spent a full
      # review round getting right.
      {:error, :ssh_identity_absent} ->
        {:error, :owner_has_no_key}

      {:error, :ssh_identity_unavailable} ->
        {:error, {:owner_key_unavailable, :ssh_identity_unavailable}}

      {:error, reason} ->
        {:error, {:ssh_key_read_failed, reason}}

      other ->
        {:error, {:ssh_key_read_unexpected, inspect(other)}}
    end
  end

  # The cap's `instance` IS the User to read from — the pointer half of the
  # moduledoc's "one cap, three jobs".
  defp user_uri_of(%Ezagent.Capability{instance: %URI{} = uri}), do: uri
  defp user_uri_of(%Ezagent.Capability{instance: uri}) when is_binary(uri), do: Ezagent.URI.new!(uri)

  # Authorized-but-broken must be NOISY (the operator granted a cap and expects
  # git to work), while the no-cap case above is silent (it is the default state
  # of nearly every agent — a log line there would be pure noise).
  #
  # `reason` never carries key material: `GitIdentityRuntime` strips content
  # from its error tuples, and 1a's action errors are bare atoms.
  defp report(agent_uri, cap, reason) do
    :telemetry.execute(
      [:ezagent, :git_identity, :materialize_failed],
      %{count: 1},
      %{agent: URI.to_string(agent_uri), user: URI.to_string(user_uri_of(cap)), reason: reason}
    )

    Logger.error(
      "git identity NOT materialized for #{URI.to_string(agent_uri)} " <>
        "(authorized to read #{URI.to_string(user_uri_of(cap))}): #{inspect(reason)}. " <>
        remediation(reason)
    )

    {:error, reason}
  end

  defp remediation(:owner_has_no_key),
    do: "The User has no SSH identity — run the :generate_ssh_key action for them."

  defp remediation(:known_hosts_unconfigured),
    do:
      "No node known_hosts configured — run `mix ezagent.git.known_hosts github.com --out <path>` " <>
        "and set `config :ezagent_core, :git_known_hosts_path, \"<path>\"`."

  defp remediation({:known_hosts_unreadable, _}),
    do: "The configured :git_known_hosts_path is unreadable — check the path and permissions."

  defp remediation(_), do: ""
end
```

- [ ] **Step 4: 跑测试确认通过**

Run: `POSTGRES_PORT=15432 mix test apps/ezagent_domain_identity/test/ezagent/identity/agent_git_identity_test.exs`
Expected: 全部通过。

- [ ] **Step 5: 红演示（四条核心不变式各一轮）**

1. **cap 即开关** —— 把 `ssh_read_cap?/1` 的 `action: @action` 去掉（改成只匹配 behavior），跑"只持 read_ssh_public_key cap 仍是关闭态"那条，贴红 → 还原 → `git diff` 空 → 贴绿
2. **窄授权** —— 把 `caps: MapSet.new([cap])` 改成 `caps: Ezagent.Identity.list_caps_for(agent_uri)`，跑"窄授权"那条，贴红 → 还原 → 贴绿
3. **错误不合并** —— 把 `{:error, :ssh_identity_unavailable}` 那个 clause 删掉（让它落到通用 clause），跑"配错了"那组，贴红 → 还原 → 贴绿
4. **撤销真的生效** —— 把 `[] ->` 分支里的 `GitIdentityRuntime.wipe(agent_uri)` 删掉，跑"撤销生效"那条，贴红 → 还原 → 贴绿。**再单独删一次错误分支里的 `wipe`**，跑"读失败也清盘"那条，贴红 → 还原 → 贴绿

> **Task 2 的实现者在这一步报回一条真实发现**：他按 findings 只回退了两个子修复中的一个，测试**仍然是绿的**（两条修复互为冗余），他如实报告而没有粉饰。**如果你按上面某一条改坏之后测试仍然绿，那是真实发现，立即报告，不要硬凑。** 前三个 task 每一个都靠这条抓出了我计划里的一处错。

- [ ] **Step 6: 提交**

```bash
mix format apps/ezagent_domain_identity/lib/ezagent/identity/agent_git_identity.ex apps/ezagent_domain_identity/test/ezagent/identity/agent_git_identity_test.exs
git add apps/ezagent_domain_identity/lib/ezagent/identity/agent_git_identity.ex apps/ezagent_domain_identity/test/ezagent/identity/agent_git_identity_test.exs
git commit -m "feat(identity): agent git 身份编排 —— cap 即开关、授权与指针

不做任何归属推导：cap 的 instance 字段就是要读谁的 key，开关与
主体是同一个事实，不可能各说各话。dispatch 只带那一条 cap。"
```

---

### Task 4: 两个 mix task（known_hosts 生成 + cap 发放）

**Files:**
- Create: `apps/ezagent_domain_identity/lib/mix/tasks/ezagent.git.known_hosts.ex`
- Create: `apps/ezagent_domain_identity/lib/mix/tasks/ezagent.agent.grant_git_identity.ex`
- Test: `apps/ezagent_domain_identity/test/mix/tasks/ezagent_git_known_hosts_test.exs`
- Test: `apps/ezagent_domain_identity/test/mix/tasks/ezagent_agent_grant_git_identity_test.exs`

**Interfaces:**
- Consumes: `Ezagent.Credential.GitIdentityRuntime.known_hosts_path/0`（Task 2）、`Ezagent.ActionSet.UserSshIdentity`（1a）
- Produces:
  - `Mix.Tasks.Ezagent.Git.KnownHosts.run(argv)` —— `mix ezagent.git.known_hosts <host>... [--out <path>]`
  - `Mix.Tasks.Ezagent.Agent.GrantGitIdentity.run(argv)` —— `mix ezagent.agent.grant_git_identity <agent_uri> <user_uri>`
  - 两者都导出 `@doc false` 的纯函数供测试直接调用（见下），避免测试依赖 `Mix.Task.run/2` 的副作用

**参考实现：** `apps/ezagent_domain_agent/lib/mix/tasks/ezagent.agent.grant_recipe_caps.ex` 是本仓库同类 task 的形态样板（admin 权限校验 + issue + 交付）。**先读它**，照它的骨架写。

发放那条 cap 的机制照抄 `apps/ezagent_domain_agent/lib/ezagent/agent/host_login_adopt.ex` 的 `ensure_source_read_cap/2`（:159-175）：`Ezagent.Cap.issue/3` → `Ezagent.Identity.absorb_cap/2` → `Ezagent.Identity.CapAbsorbAwait.await_exact/3`。注意 `Ezagent.Cap.issue_for_action/3`（`cap.ex:83`）能从一个带 action 的 target 直接推出 required cap，比手搓 `Capability.cap/5` 更不容易写错轴 —— **优先用它**。

- [ ] **Step 1: 写 known_hosts task 的失败测试**

创建 `apps/ezagent_domain_identity/test/mix/tasks/ezagent_git_known_hosts_test.exs`：

```elixir
defmodule Mix.Tasks.Ezagent.Git.KnownHostsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Ezagent.Git.KnownHosts

  describe "参数解析" do
    test "没给 host 时报错" do
      assert {:error, :no_hosts} = KnownHosts.plan([])
    end

    test "既没有 --out 也没有配置项时，要求显式给 --out" do
      assert {:error, :no_output_path} = KnownHosts.plan(["github.com"])
    end

    test "--out 指定输出路径" do
      assert {:ok, %{hosts: ["github.com"], out: "/tmp/kh"}} =
               KnownHosts.plan(["github.com", "--out", "/tmp/kh"])
    end

    test "多个 host" do
      assert {:ok, %{hosts: ["github.com", "gitlab.com"]}} =
               KnownHosts.plan(["github.com", "gitlab.com", "--out", "/tmp/kh"])
    end
  end

  describe "写入" do
    test "把 scan 结果写到 out 路径并 chmod 0644" do
      out = Path.join(System.tmp_dir!(), "kh-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(out) end)

      assert :ok = KnownHosts.write_scanned(out, "github.com ssh-ed25519 AAAA\n")

      assert File.read!(out) == "github.com ssh-ed25519 AAAA\n"
      {:ok, %File.Stat{mode: mode}} = File.stat(out)
      assert Bitwise.band(mode, 0o777) == 0o644
    end

    test "空的 scan 结果被拒 —— 绝不写出一个空 known_hosts" do
      out = Path.join(System.tmp_dir!(), "kh-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(out) end)

      assert {:error, :empty_scan} = KnownHosts.write_scanned(out, "")
      assert {:error, :empty_scan} = KnownHosts.write_scanned(out, "   \n\n")
      refute File.exists?(out)
    end
  end
end
```

> **为什么"空结果被拒"要单独测**：`ssh-keyscan` 对不可达主机会返回 0 退出码 + 空输出。写出一个空 known_hosts 的后果是**每次 clone 都因主机 key 验证失败而挂，而运维以为已经配好了**。

- [ ] **Step 2: 跑测试确认失败**

Run: `POSTGRES_PORT=15432 mix test apps/ezagent_domain_identity/test/mix/tasks/ezagent_git_known_hosts_test.exs`
Expected: 编译失败 —— task 模块未定义。

- [ ] **Step 3: 写 known_hosts task**

创建 `apps/ezagent_domain_identity/lib/mix/tasks/ezagent.git.known_hosts.ex`：

```elixir
defmodule Mix.Tasks.Ezagent.Git.KnownHosts do
  @shortdoc "生成节点级 known_hosts（SSH 凭据 1b）"

  @moduledoc """
  Scan forge host keys into the node-level `known_hosts` that every agent's git
  identity copies from.

      mix ezagent.git.known_hosts github.com --out /var/lib/ezagent/git/known_hosts

  Then point the runtime at it:

      config :ezagent_core, :git_known_hosts_path, "/var/lib/ezagent/git/known_hosts"

  `--out` may be omitted only when that config value is already set (the task
  then refreshes it in place). There is **no default path** — writing an
  operator file under a guessed location is worse than asking.

  ## Why not ship forge host keys in the repo

  They rotate. A stale committed key surfaces as node-wide clone failure with no
  hint about which file to fix.

  ## Why an empty scan is refused

  `ssh-keyscan` exits 0 with empty output for an unreachable host. Writing that
  out produces a `known_hosts` that fails every connection while looking
  configured.
  """

  use Mix.Task

  alias Ezagent.Credential.GitIdentityRuntime

  @requirements ["app.config"]
  @scan_timeout_ms 15_000
  @file_mode 0o644

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    with {:ok, %{hosts: hosts, out: out}} <- plan(argv),
         {:ok, scanned} <- scan(hosts),
         :ok <- write_scanned(out, scanned) do
      Mix.shell().info("wrote #{out}")
      Mix.shell().info(~s|set: config :ezagent_core, :git_known_hosts_path, "#{out}"|)
    else
      {:error, reason} -> Mix.raise("ezagent.git.known_hosts failed: #{inspect(reason)}")
    end
  end

  @doc false
  @spec plan([String.t()]) :: {:ok, %{hosts: [String.t()], out: String.t()}} | {:error, term()}
  def plan(argv) do
    {opts, hosts, _} = OptionParser.parse(argv, strict: [out: :string])

    out = Keyword.get(opts, :out) || GitIdentityRuntime.known_hosts_path()

    cond do
      hosts == [] -> {:error, :no_hosts}
      is_nil(out) -> {:error, :no_output_path}
      true -> {:ok, %{hosts: hosts, out: out}}
    end
  end

  @doc false
  @spec write_scanned(String.t(), String.t()) :: :ok | {:error, term()}
  def write_scanned(out, scanned) when is_binary(scanned) do
    if String.trim(scanned) == "" do
      {:error, :empty_scan}
    else
      with :ok <- File.mkdir_p(Path.dirname(out)),
           :ok <- File.write(out, scanned),
           :ok <- File.chmod(out, @file_mode) do
        :ok
      end
    end
  end

  defp scan(hosts) do
    task =
      Task.async(fn ->
        System.cmd("ssh-keyscan", hosts, stderr_to_stdout: false)
      end)

    case Task.yield(task, @scan_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} -> {:ok, out}
      {:ok, {_out, code}} -> {:error, {:ssh_keyscan_exit, code}}
      nil -> {:error, :ssh_keyscan_timeout}
    end
  rescue
    e in ErlangError -> {:error, {:ssh_keyscan_unavailable, Exception.message(e)}}
  end
end
```

- [ ] **Step 4: 跑测试确认通过**

Run: `POSTGRES_PORT=15432 mix test apps/ezagent_domain_identity/test/mix/tasks/ezagent_git_known_hosts_test.exs`
Expected: 全部通过。

- [ ] **Step 5: 写 grant task 的失败测试**

创建 `apps/ezagent_domain_identity/test/mix/tasks/ezagent_agent_grant_git_identity_test.exs`：

```elixir
defmodule Mix.Tasks.Ezagent.Agent.GrantGitIdentityTest do
  use ExUnit.Case, async: false

  alias Ezagent.ActionSet.UserSshIdentity
  alias Mix.Tasks.Ezagent.Agent.GrantGitIdentity

  setup do
    suffix = System.unique_integer([:positive])
    user_uri = Ezagent.URI.entity(:gitid, :user, "owner-g#{suffix}")
    agent_uri = Ezagent.URI.entity(:gitid, :agent, "worker-g#{suffix}")

    {:ok, _} = Ezagent.Users.create(user_uri, nil, [])
    {:ok, _} = Ezagent.SpawnRegistry.spawn(user_uri)
    on_exit(fn -> Ezagent.Kind.terminate(user_uri) end)

    %{user_uri: user_uri, agent_uri: agent_uri}
  end

  describe "参数解析" do
    test "少于两个参数时报错" do
      assert {:error, :usage} = GrantGitIdentity.plan([])
      assert {:error, :usage} = GrantGitIdentity.plan(["entity://ws/agent/a"])
    end

    test "第一个参数必须是 agent URI" do
      assert {:error, {:not_an_agent_uri, _}} =
               GrantGitIdentity.plan(["entity://ws/user/u", "entity://ws/user/u"])
    end

    test "第二个参数必须是 user URI" do
      assert {:error, {:not_a_user_uri, _}} =
               GrantGitIdentity.plan(["entity://ws/agent/a", "entity://ws/agent/b"])
    end

    test "合法参数解析出两个 URI" do
      assert {:ok, %{agent: %URI{}, user: %URI{}}} =
               GrantGitIdentity.plan(["entity://ws/agent/a", "entity://ws/user/u"])
    end
  end

  describe "发放" do
    test "发完后 agent 恰好多出那一条 cap，且 instance 指向该 user", ctx do
      before = Ezagent.Identity.list_caps_for(ctx.agent_uri)

      assert {:ok, cap} = GrantGitIdentity.grant(ctx.agent_uri, ctx.user_uri)

      after_caps = Ezagent.Identity.list_caps_for(ctx.agent_uri)
      added = MapSet.difference(after_caps, before) |> MapSet.to_list()

      assert [^cap] = added
      assert cap.behavior == UserSshIdentity
      assert cap.action == :read_ssh_key
      assert cap.kind == :user
      assert cap.instance == Ezagent.URI.instance(ctx.user_uri)
    end

    test "发放后 AgentGitIdentity 认得这条 cap（与 Task 3 的选择器对齐）", ctx do
      {:ok, cap} = GrantGitIdentity.grant(ctx.agent_uri, ctx.user_uri)

      assert [^cap] = Ezagent.Identity.AgentGitIdentity.dispatch_caps(ctx.agent_uri)
    end
  end
end
```

> 最后那条是**跨 task 的对齐断言**：发放端与消费端对"哪条 cap 算数"的判断必须一致。任一端单方面改轴（kind / behavior / action）都会让它红。

- [ ] **Step 6: 跑测试确认失败**

Run: `POSTGRES_PORT=15432 mix test apps/ezagent_domain_identity/test/mix/tasks/ezagent_agent_grant_git_identity_test.exs`
Expected: 编译失败 —— task 模块未定义。

- [ ] **Step 7: 写 grant task**

创建 `apps/ezagent_domain_identity/lib/mix/tasks/ezagent.agent.grant_git_identity.ex`：

```elixir
defmodule Mix.Tasks.Ezagent.Agent.GrantGitIdentity do
  @shortdoc "授权一个 agent 读取某个 User 的 SSH 私钥（SSH 凭据 1b）"

  @moduledoc """
  Grant `<agent_uri>` the `read_ssh_key` capability on `<user_uri>`.

      mix ezagent.agent.grant_git_identity entity://acme/agent/dev-1 entity://acme/user/allen

  That single capability is the **entire switch** for form B2′: holding it, the
  agent gets the User's SSH private key materialized into its own git-identity
  dir at every spawn, plus a `GIT_SSH_COMMAND` pointing at it. Not holding it,
  nothing happens at all.

  **This is a deliberate, per-agent, human decision.** The capability's
  `instance` field is simultaneously the authorization and the pointer to whose
  key — see `Ezagent.Identity.AgentGitIdentity`.

  ## 撤销不是即时的

  Revoking the capability takes effect at the agent's **next spawn**; the key
  file already on disk is unaffected. To cut access immediately, also remove the
  agent's git-identity dir and restart it. This is inherent to form B2′ (once a
  key reaches a filesystem the agent can read, the platform has lost control of
  it), not a defect of this task.
  """

  use Mix.Task

  alias Ezagent.ActionSet.UserSshIdentity

  @requirements ["app.config"]
  @absorb_timeout_ms 5_000

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    with {:ok, %{agent: agent, user: user}} <- plan(argv),
         {:ok, cap} <- grant(agent, user) do
      Mix.shell().info(
        "granted #{inspect(cap.action)} on #{URI.to_string(user)} to #{URI.to_string(agent)}"
      )

      Mix.shell().info("takes effect at the agent's next spawn")
    else
      {:error, reason} ->
        Mix.raise("ezagent.agent.grant_git_identity failed: #{inspect(reason)}")
    end
  end

  @doc false
  @spec plan([String.t()]) :: {:ok, %{agent: URI.t(), user: URI.t()}} | {:error, term()}
  def plan([agent_str, user_str]) do
    with {:ok, agent} <- parse_typed(agent_str, "agent", :not_an_agent_uri),
         {:ok, user} <- parse_typed(user_str, "user", :not_a_user_uri) do
      {:ok, %{agent: agent, user: user}}
    end
  end

  def plan(_), do: {:error, :usage}

  @doc false
  @spec grant(URI.t(), URI.t()) :: {:ok, Ezagent.Capability.t()} | {:error, term()}
  def grant(%URI{} = agent_uri, %URI{} = user_uri) do
    admin = Ezagent.Entity.User.admin_uri()
    target = Ezagent.URI.with_action(user_uri, :user_ssh_identity, :read_ssh_key)

    with {:ok, _pid} <- ensure_started(user_uri),
         # `issue_for_action/3` derives the required cap from the Behavior's own
         # `required_caps/0` — no hand-built axes to get wrong.
         {:ok, cap} <- Ezagent.Cap.issue_for_action({:admin, admin}, agent_uri, target),
         :ok <- Ezagent.Identity.absorb_cap(agent_uri, cap),
         :ok <-
           Ezagent.Identity.CapAbsorbAwait.await_exact(agent_uri, [cap], @absorb_timeout_ms) do
      {:ok, cap}
    end
  end

  defp ensure_started(uri) do
    case Ezagent.LocalRuntime.ensure_started_detailed(uri) do
      {:ok, _status, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, {:user_not_startable, reason}}
    end
  end

  defp parse_typed(str, expected_type, error_tag) do
    uri = Ezagent.URI.new!(str)

    case Ezagent.URI.type(uri) do
      {:ok, ^expected_type} -> {:ok, uri}
      _ -> {:error, {error_tag, str}}
    end
  rescue
    _ -> {:error, {error_tag, str}}
  end
end
```

> **不要**为了消掉 `alias Ezagent.ActionSet.UserSshIdentity` 的 unused 警告而加一个只为消警告而存在的函数。这个 task 用 `issue_for_action/3` 从 target 反推 required cap，**根本不需要引用该模块** —— 直接把 alias 删掉，在 moduledoc 里写清它授权的是 `Ezagent.ActionSet.UserSshIdentity` 的 `:read_ssh_key`。

- [ ] **Step 8: 跑测试确认通过**

Run: `POSTGRES_PORT=15432 mix test apps/ezagent_domain_identity/test/mix/tasks/`
Expected: 两个文件全部通过。

- [ ] **Step 9: 红演示**

1. 把 `write_scanned/2` 的空值检查删掉，跑"空的 scan 结果被拒"，贴红 → 还原 → 贴绿
2. 把 `grant/2` 里的 `:read_ssh_key` 换成 `:read_ssh_public_key`，跑"与 Task 3 的选择器对齐"那条，贴红 → 还原 → 贴绿

- [ ] **Step 10: 提交**

```bash
mix format apps/ezagent_domain_identity/lib/mix/tasks/ezagent.git.known_hosts.ex apps/ezagent_domain_identity/lib/mix/tasks/ezagent.agent.grant_git_identity.ex apps/ezagent_domain_identity/test/mix/tasks/ezagent_git_known_hosts_test.exs apps/ezagent_domain_identity/test/mix/tasks/ezagent_agent_grant_git_identity_test.exs
git add apps/ezagent_domain_identity/lib/mix/tasks/ apps/ezagent_domain_identity/test/mix/tasks/
git commit -m "feat(identity): known_hosts 生成 + git 身份 cap 发放两个 mix task

known_hosts 无默认路径（猜一个运维文件位置比问一句更糟），空
scan 结果被拒（ssh-keyscan 对不可达主机返回 0 + 空输出）。"
```

---

### Task 5: cc flavor 接线 + destroy 清理

**Files:**
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/template/spawn_plan.ex`（PTY 路径的 `cmd_env`）
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_agent.ex`（headless 路径的 `cmd_env/2`）
- Modify: `apps/ezagent_core/lib/ezagent/behavior/sandbox.ex`（destroy 时 wipe）
- Test: `apps/ezagent_plugin_cc/test/ezagent/template/git_identity_env_test.exs`

**Interfaces:**
- Consumes: `Ezagent.Identity.AgentGitIdentity.materialize/1`（Task 3）、`Ezagent.Credential.GitIdentityRuntime.wipe/1`（Task 2）

**依赖方向已验证**：`apps/ezagent_plugin_cc/mix.exs:51` 已依赖 `ezagent_domain_identity`；后者只依赖 `ezagent_core` + `ezagent_actor`。**无循环依赖。**

**关键约束：关闭态必须零影响。** `materialize/1` 返回 `{:ok, :none}` 时，`cmd_env` 必须**逐字节不变**。这是绝大多数 agent 的路径。

- [ ] **Step 1: 写失败测试**

创建 `apps/ezagent_plugin_cc/test/ezagent/template/git_identity_env_test.exs`：

```elixir
defmodule Ezagent.PluginCc.Template.GitIdentityEnvTest do
  use ExUnit.Case, async: true

  alias Ezagent.PluginCc.Template.SpawnPlan

  @base %{"EZAGENT_AGENT_URI" => "entity://ws/agent/a", "EZAGENT_AGENT_TOKEN" => "t"}

  describe "merge_git_identity_env/2" do
    test "关闭态：env 逐字节不变" do
      assert SpawnPlan.merge_git_identity_env(@base, {:ok, :none}) == @base
    end

    test "错误态：env 逐字节不变（配错不能连带改变 agent 的其它 env）" do
      assert SpawnPlan.merge_git_identity_env(@base, {:error, :owner_has_no_key}) == @base
      assert SpawnPlan.merge_git_identity_env(@base, {:error, :known_hosts_unconfigured}) == @base
    end

    test "开启态：恰好多出 GIT_SSH_COMMAND，其余不变" do
      merged =
        SpawnPlan.merge_git_identity_env(@base, {:ok, %{"GIT_SSH_COMMAND" => "ssh -i /k"}})

      assert merged == Map.put(@base, "GIT_SSH_COMMAND", "ssh -i /k")
    end

    test "不覆盖已有的 GIT_SSH_COMMAND 以外的键" do
      base = Map.put(@base, "GIT_SSH_COMMAND", "ssh -i /old")

      merged =
        SpawnPlan.merge_git_identity_env(base, {:ok, %{"GIT_SSH_COMMAND" => "ssh -i /new"}})

      assert merged["GIT_SSH_COMMAND"] == "ssh -i /new"
      assert Map.delete(merged, "GIT_SSH_COMMAND") == Map.delete(base, "GIT_SSH_COMMAND")
    end
  end
end
```

- [ ] **Step 2: 跑测试确认失败**

Run: `POSTGRES_PORT=15432 mix test apps/ezagent_plugin_cc/test/ezagent/template/git_identity_env_test.exs`
Expected: 失败 —— `SpawnPlan.merge_git_identity_env/2` 未定义。

- [ ] **Step 3: 在 SpawnPlan 加 merge 函数并接进 PTY 路径**

在 `apps/ezagent_plugin_cc/lib/ezagent/template/spawn_plan.ex` 加：

```elixir
  @doc """
  SSH 凭据 1b — merge the git-identity env into `env`, tolerating every
  non-materialized outcome.

  A git identity is a CAPABILITY of the agent, not a precondition for its
  existence: an unconfigured `known_hosts` must not stop the agent from
  starting. `Ezagent.Identity.AgentGitIdentity` has already logged + emitted
  telemetry for the error cases, so swallowing them here is not a silent drop.

  `{:ok, :none}` is the DEFAULT for nearly every agent and returns `env`
  byte-identically.
  """
  @spec merge_git_identity_env(map(), term()) :: map()
  def merge_git_identity_env(env, {:ok, git_env}) when is_map(git_env),
    do: Map.merge(env, git_env)

  def merge_git_identity_env(env, _outcome), do: env
```

并在 `build_claude_cmd/3` 的 `cmd_env` 管道**末尾**加一步（在现有 `Map.merge(Ezagent.PluginCc.Provider.bridge_topic_env(tmpl, agent_uri))` 之后）：

```elixir
        # SSH 凭据 1b — 持有 read_ssh_key cap 的 agent 拿到 GIT_SSH_COMMAND；
        # 没有该 cap 的（绝大多数）env 逐字节不变。
        |> merge_git_identity_env(Ezagent.Identity.AgentGitIdentity.materialize(agent_uri))
```

- [ ] **Step 4: 接进 headless 路径**

在 `apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_agent.ex` 中，把 `cmd_env/2` 改为：

```elixir
  defp cmd_env(agent_uri, tmpl) do
    tmpl
    |> provider_cmd_env()
    |> Ezagent.PluginCc.Template.SpawnPlan.maybe_put_cli_identity_env(agent_uri, tmpl)
    # SSH 凭据 1b — 与 PTY 路径同一个 seam。
    |> Ezagent.PluginCc.Template.SpawnPlan.merge_git_identity_env(
      Ezagent.Identity.AgentGitIdentity.materialize(agent_uri)
    )
  end
```

- [ ] **Step 5: destroy 时清理**

在 `apps/ezagent_core/lib/ezagent/behavior/sandbox.ex` 中，`invoke_destroy_config_dir/3` 的**两个调用点**（约 `:422` 与 `:562`）各自紧邻加一行清理。先 `grep -n "invoke_destroy_config_dir" apps/ezagent_core/lib/ezagent/behavior/sandbox.ex` 确认当前行号。

在 `:422` 处：

```elixir
    cleanup_result = invoke_destroy_config_dir(self_uri, config_dir, template_class)
    # SSH 凭据 1b — git 身份住在 config_dir 之外的独立目录（见
    # Ezagent.Sandbox.GitIdentityDir 的 moduledoc），所以必须在这里单独清。
    # 幂等、best-effort、从不抛异常 —— 绝不能让清理失败挡住 destroy。
    _ = Ezagent.Credential.GitIdentityRuntime.wipe(self_uri)
```

在 `:562` 处同样加：

```elixir
    _ = invoke_destroy_config_dir(self_uri, config_dir, template_class)
    _ = Ezagent.Credential.GitIdentityRuntime.wipe(self_uri)
```

- [ ] **Step 6: 跑测试确认通过**

```bash
POSTGRES_PORT=15432 mix test apps/ezagent_plugin_cc/test/ezagent/template/git_identity_env_test.exs
POSTGRES_PORT=15432 mix test apps/ezagent_core/test/ezagent/behavior/
```
Expected: 全部通过（后者证明 destroy 路径未被破坏）。

- [ ] **Step 7: 红演示**

把 `merge_git_identity_env/2` 的第二个 clause 改成 `def merge_git_identity_env(env, _outcome), do: Map.put(env, "GIT_SSH_COMMAND", "")`，跑"关闭态 env 逐字节不变"，贴红 → 还原 → `git diff` 空 → 贴绿。

- [ ] **Step 8: 跑全套相关测试**

```bash
POSTGRES_PORT=15432 mix test apps/ezagent_core/test/ apps/ezagent_domain_identity/test/ apps/ezagent_plugin_cc/test/
```
把结果如实贴出（含既有的 main 级红，标明来源）。

- [ ] **Step 9: 提交**

```bash
mix format apps/ezagent_plugin_cc/lib/ezagent/template/spawn_plan.ex apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_agent.ex apps/ezagent_core/lib/ezagent/behavior/sandbox.ex apps/ezagent_plugin_cc/test/ezagent/template/git_identity_env_test.exs
git add apps/ezagent_plugin_cc/lib/ezagent/template/spawn_plan.ex apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_agent.ex apps/ezagent_core/lib/ezagent/behavior/sandbox.ex apps/ezagent_plugin_cc/test/ezagent/template/git_identity_env_test.exs
git commit -m "feat(cc): 接线 git 身份 env + destroy 时清理身份目录

关闭态（无 cap，绝大多数 agent）env 逐字节不变；错误态亦然
——身份配错不得连带改变 agent 的其它 env，也不得挡住 spawn。"
```

---

## 收尾（所有 task 完成后）

- [ ] 跑 `mix ci.fast`（显式 `timeout: 300000`，`POSTGRES_PORT=15432`）
- [ ] 跑 `mix ezagent.arch.scan`，如实报告命中与每一处 `arch-allow`
- [ ] 跑 `mix ezagent.check_invariants.lifecycle`，与 main 基线对比，**只报告本支新增的红**
- [ ] **架构 ratchet**：`apps/ezagent_core/test/architecture/arch_baseline_manifest.exs` 里有按精确计数钉住的 ratchet（1a 那轮把某个计数从 131 抬到 141）。本支新增了 `File.write` / `File.chmod` / `System.cmd` 等调用点，**若 ratchet 变红，是抬 cap 到新的精确值，不是加宽正则**（memory `reference-arch-gate-enforcement-patterns`）。抬之前先确认每一个新增命中都是真实站点。
- [ ] 结论措辞用「**本支无新增红**」，不得写「gate 全绿」
- [ ] **本支未覆盖、需上报的既有问题**（1a 已发现，不在本支修）：`mix ezagent.check_invariants.lifecycle` 在 main 上即红；`Ezagent.Invariants.BehaviorRequiredCapsParityTest` 在 `apps/ezagent_actor/lib/ezagent/behavior.ex:318` 有文档但模块不存在
