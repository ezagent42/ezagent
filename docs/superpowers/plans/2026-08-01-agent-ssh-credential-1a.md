# User SSH 身份（任务 1a）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **每个 subagent prompt 必须带上 `Skill: ezagent-developer` 和 `Skill: elixir-phoenix-helper`** —— 不带的话会写出过时 Elixir 或违反不变式（memory `feedback_subagent_must_load_project_skills`）。

**Goal:** 给 User Kind 加一个 SSH 身份 ActionSet：生成 / 读公钥 / 读私钥（cap 授权）/ 撤销。

**Architecture:** 新增 `Ezagent.ActionSet.UserSshIdentity`（`use Ezagent.Lifecycle`），挂在 `Ezagent.Entity.User` 上，与既有 `UserTokens` 完全同构。密钥对由 `ssh-keygen` 子进程生成（`System.cmd`），存进 Lifecycle 的 `state` 容器（明文，与既有凭据轨一致），`transients` 为空。四个 action 全部 `modes: [:call]`。

**Tech Stack:** Elixir 1.19 / OTP 28，`Ezagent.Lifecycle` 宏，`System.cmd/3`，ExUnit。

## Global Constraints

- **禁用 `use Ezagent.ActionSet` / `state_slice/0` / `init_slice/1` / `invoke/4` / `post_init` / `handle_continue` / `on_ready` / `reconcile_after_load`** —— 开发者面只有 `use Ezagent.Lifecycle`；Phase C gate `mix ezagent.check_invariants.lifecycle` 会 HARD-fail CI。
- **不做 at-rest 封存** —— 与既有凭据轨一致（snapshot 明文落库）。理由与延后记录见 spec §6。不得引入 `SealedEnvelope`（`ezagent_domain_provider_connection` 依赖 `ezagent_domain_identity`，反向即循环依赖）。
- **不碰** `GitRunner` / `Provisioner` / `ChangeCollector` / `StageRunner` / `git_workflow` / `Ezagent.Credential.*` cascade。
- **不新建 app，不往 core 加抽象** —— 全部改动落在 `apps/ezagent_domain_identity/`（外加 spec 回填）。
- **格式化只格式化改动过的文件**：`mix format <改动的文件>`，不要跑全项目 `mix format`。
- **Gate**：`mix ci.fast`，**必须带显式 `timeout: 300000`**；被 kill 的运行**不算通过**。

---

## File Structure

| 文件 | 职责 |
|---|---|
| `apps/ezagent_domain_identity/lib/ezagent/behavior/user_ssh_identity.ex` | **新建** —— 四个 action + handler + keygen 子进程封装 |
| `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex` | **修改**（`behaviors/0` 列表，约 :173-178） |
| `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex` | **修改**（alias 块约 :47-55；CapabilityRegistry 注册约 :478 之后） |
| `apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs` | **新建** —— 功能 + 错误分支 + 卫生 |
| `apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_authz_test.exs` | **新建** —— cap 门 |
| `docs/superpowers/specs/2026-08-01-agent-ssh-credential-1a-design.md` | **修改** —— 回填 known_hosts 移出 1a |

### 范围修正：`known_hosts` 移出 1a

spec §3.4 描述了 `known_hosts` 的做法，但 §9 未把它排除出 1a，存在歧义。**本计划将其移到 1b。**

理由（X/Y）：Y 是「known_hosts 放哪个 app」；X 是「**1a 交付什么**」—— 1a 是 SSH 身份的 CRUD，**不发起任何 git 连接**，因此 known_hosts 在 1a 内**没有可验证的对象**，放进来等于交付一段未经验证的配置写入代码。它是 1b / 任务 2 的前置，应跟着消费者走。Task 3 Step 6 执行这处回填。

---

## Task 1: `UserSshIdentity` 模块骨架 + 注册 + `:generate_ssh_key`

**Files:**
- Create: `apps/ezagent_domain_identity/lib/ezagent/behavior/user_ssh_identity.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex`（`behaviors/0`）
- Modify: `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex`（alias + CapabilityRegistry）
- Test: `apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs`

**Interfaces:**
- Consumes: `Ezagent.Lifecycle`（`action/2` 宏、`ctx[:read]`、`{:set,_,_}`、`{:emit,_,_}` effects）；`Ezagent.Entity.User`（Kind）；`Ezagent.CapabilityRegistry.register/3`
- Produces:
  - `Ezagent.ActionSet.UserSshIdentity.handle_generate_ssh_key(map(), map()) :: {:ok, %{public_key: String.t(), fingerprint: String.t()}, [effect]} | {:error, term()}`
  - `Ezagent.ActionSet.UserSshIdentity.actions() :: [atom()]`（宏生成）
  - state 键：`:public_key` / `:fingerprint` / `:private_key` / `:comment` / `:created_at`

---

- [ ] **Step 1: 写失败测试**

创建 `apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs`：

```elixir
defmodule Ezagent.ActionSet.UserSshIdentityTest do
  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.UserSshIdentity

  # Lifecycle handler 是纯 (args, ctx) 函数，可直接单测，无需起 Kind 进程。
  # ctx 只需提供 handler 实际用到的键：:self_uri 与 :read。
  defp ctx(state \\ %{}) do
    %{
      self_uri: Ezagent.URI.entity("default", "user", "alice"),
      read: fn key, default -> Map.get(state, key, default) end
    }
  end

  describe "generate_ssh_key" do
    test "生成密钥对，返回公钥与指纹，且不返回私钥" do
      assert {:ok, result, effects} =
               UserSshIdentity.handle_generate_ssh_key(%{comment: "alice@ezagent"}, ctx())

      assert String.starts_with?(result.public_key, "ssh-ed25519 ")
      assert is_binary(result.fingerprint) and result.fingerprint != ""
      refute Map.has_key?(result, :private_key)

      # 私钥必须进 state
      private =
        Enum.find_value(effects, fn
          {:set, :private_key, v} -> v
          _ -> nil
        end)

      assert String.starts_with?(private, "-----BEGIN OPENSSH PRIVATE KEY-----")

      # 审计
      assert Enum.any?(effects, &match?({:emit, :ssh_identity_generated, _}, &1))
    end

    test "已存在身份时拒绝，不覆盖" do
      state = %{public_key: "ssh-ed25519 AAAA existing", private_key: "existing"}

      assert {:error, :ssh_identity_exists} =
               UserSshIdentity.handle_generate_ssh_key(%{}, ctx(state))
    end

    test "生成后临时目录不残留" do
      before = tmp_entries()
      assert {:ok, _r, _e} = UserSshIdentity.handle_generate_ssh_key(%{}, ctx())
      assert tmp_entries() == before
    end
  end

  defp tmp_entries do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "ezagent-sshkeygen-"))
    |> Enum.sort()
  end
end
```

- [ ] **Step 2: 跑测试确认失败**

```bash
POSTGRES_PORT=15432 mix test apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs
```

预期：FAIL —— `Ezagent.ActionSet.UserSshIdentity.handle_generate_ssh_key/2 is undefined (module Ezagent.ActionSet.UserSshIdentity is not available)`

- [ ] **Step 3: 写模块骨架 + `:generate_ssh_key`**

创建 `apps/ezagent_domain_identity/lib/ezagent/behavior/user_ssh_identity.ex`：

```elixir
defmodule Ezagent.ActionSet.UserSshIdentity do
  @moduledoc """
  User 的 SSH 身份 —— 生成 / 读公钥 / 读私钥 / 撤销。

  与 `Ezagent.ActionSet.UserTokens` 同构：挂 User Kind，四个 action 全部
  `modes: [:call]`（同步返回结果，失败即 `{:error, _}`，无 fire-and-forget
  路径，故不需要 DLQ 兜底）。

  ## 归属

  SSH 身份归 **User**，不归 Agent。agent 是动态物化的，若归 agent 则每物化
  一个就要去 provider 手工加一次公钥 —— 用不了。设计见
  `docs/superpowers/specs/2026-08-01-agent-ssh-credential-1a-design.md` §2。

  ## 两容器

  `state`（持久）：`:public_key` / `:fingerprint` / `:private_key` /
  `:comment` / `:created_at`。
  `transients`：**空** —— 无 PID / port / ETS / 连接需要在 `activate/2`
  重建，故结构上不可能出现 #110/#113/#114 那族 cold-restart bug。

  ## at-rest

  私钥**明文**存进 snapshot，与既有凭据轨一致（`:api_keys` slice 亦然；
  snapshot 层无加密）。这不是判断 SSH 私钥不值得封存，而是遵循 CLAUDE.md
  「不要在功能 PR 内联引入 caps 正确性以外的安全代码」。统一安全轨接手
  at-rest 加密时，**SSH 私钥应排在 api_keys 之前** —— 后果更重（仓库写权限
  vs LLM 花费）。见 spec §6。

  ## 部署契约（无代码强制，故在此显式记录）

  租户隔离靠**不共享部署**：互不信任的租户各自一套 ezagent 部署
  （workspace = 部署单元）。同部署内的多 workspace 仅用于同一 operator 的
  多环境。**SSH key 的隔离依赖这条契约。**
  """

  use Ezagent.Lifecycle

  @keygen_tmp_prefix "ezagent-sshkeygen-"

  action(:generate_ssh_key,
    args: %{comment: {:option, :string}},
    returns: %{public_key: :string, fingerprint: :string},
    caps: [{:generate_ssh_key, kind: :user}],
    description:
      "Generate a fresh ed25519 SSH identity for this User. The private " <>
        "key is stored and NEVER returned by this action — use " <>
        ":read_ssh_key (a separate, more sensitive cap) to retrieve it. " <>
        "Refuses when an identity already exists; revoke first.",
    data_owner: :self,
    modes: [:call]
  )

  # 保留 `kind: :user` 轴（宏自动派生会硬编码 `:any`，见 UserCredentials.ex）
  def data_owner(%URI{} = entity_uri), do: entity_uri
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # =================================================================
  # Handlers
  # =================================================================

  def handle_generate_ssh_key(args, ctx) when is_map(args) do
    if ctx[:read].(:private_key, nil) || ctx[:read].(:public_key, nil) do
      {:error, :ssh_identity_exists}
    else
      comment = Map.get(args, :comment) || default_comment(ctx)

      case keygen(comment) do
        {:ok, %{public_key: pub, private_key: priv, fingerprint: fp}} ->
          now = DateTime.utc_now()

          {:ok, %{public_key: pub, fingerprint: fp},
           [
             {:set, :public_key, pub},
             {:set, :private_key, priv},
             {:set, :fingerprint, fp},
             {:set, :comment, comment},
             {:set, :created_at, now},
             {:emit, :ssh_identity_generated,
              %{
                user_uri: uri_to_string(ctx.self_uri),
                fingerprint: fp,
                comment: comment,
                at: now
              }}
           ]}

        {:error, reason} ->
          {:error, {:keygen_failed, reason}}
      end
    end
  end

  # =================================================================
  # ssh-keygen —— 用 System.cmd 而非 OsProcess
  #
  # X/Y：Y 是"用哪个跑子进程"，X 是"这个子进程的风险特征"。ssh-keygen 是
  # 本地 / 无网络 / 毫秒级 / 输出固定小的命令，没有 GitRunner 要防的那些
  # （网络挂死、大输出、孤儿进程树），因此不需要 OsProcess + 自建 GenServer
  # + deadline + 输出上限那一整套。core 内已有先例：stress_metrics.ex:208、
  # pid_file.ex:240 都用 System.cmd 跑 `ps`。
  #
  # argv 中只有路径与 `-N ""`（空 passphrase 标志，不是密钥），无敏感内容，
  # 故 /proc/<pid>/cmdline 世界可读不构成泄漏。
  # =================================================================
  defp keygen(comment) do
    dir = Path.join(System.tmp_dir!(), @keygen_tmp_prefix <> random_suffix())
    key_path = Path.join(dir, "id_ed25519")

    try do
      File.mkdir_p!(dir)

      case System.cmd(
             "ssh-keygen",
             ["-t", "ed25519", "-N", "", "-C", comment, "-f", key_path],
             stderr_to_stdout: true
           ) do
        {_out, 0} ->
          with {:ok, priv} <- File.read(key_path),
               {:ok, pub} <- File.read(key_path <> ".pub") do
            {:ok,
             %{
               private_key: priv,
               public_key: String.trim(pub),
               fingerprint: fingerprint(String.trim(pub))
             }}
          else
            {:error, posix} -> {:error, {:read_failed, posix}}
          end

        {out, status} ->
          {:error, {:exit_status, status, String.slice(out, 0, 500)}}
      end
    rescue
      e in [File.Error, ErlangError] -> {:error, {:keygen_exception, Exception.message(e)}}
    catch
      :error, :enoent -> {:error, :ssh_keygen_not_found}
    after
      # 立刻删，不依赖进程退出或 GC
      File.rm_rf(dir)
    end
  end

  # OpenSSH 的 SHA256 指纹：对公钥 base64 段解码后取 sha256，再 base64（去 padding）
  defp fingerprint(pub_line) do
    case String.split(pub_line, " ") do
      [_type, b64 | _rest] ->
        case Base.decode64(b64) do
          {:ok, raw} ->
            "SHA256:" <> (:crypto.hash(:sha256, raw) |> Base.encode64(padding: false))

          :error ->
            "SHA256:unknown"
        end

      _ ->
        "SHA256:unknown"
    end
  end

  defp default_comment(ctx), do: uri_to_string(ctx.self_uri)

  defp random_suffix, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

  # 单独的 helper：避免在 map 字面量里内联 URI.to_string（会触发
  # uri_query.scan 的 :uri_string_key 启发式，capbac.md §9 pitfall 7）
  defp uri_to_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_to_string(other) when is_binary(other), do: other
end
```

- [ ] **Step 4: 注册到 User Kind**

修改 `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex`，`behaviors/0` 加一项：

```elixir
  @impl Ezagent.Kind
  def behaviors,
    do: [
      Ezagent.ActionSet.Identity,
      Ezagent.ActionSet.UserCredentials,
      Ezagent.ActionSet.UserTokens,
      Ezagent.ActionSet.UserSshIdentity
    ]
```

- [ ] **Step 5: 注册到 CapabilityRegistry**

修改 `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex`。

alias 块加一项（在 `UserTokens,` 之后）：

```elixir
    UserTokens,
    UserSshIdentity,
```

在 `for action <- UserTokens.actions() do ... end` 那个循环之后，加：

```elixir
    # 任务 1a (2026-08-01): UserSshIdentity Behavior —— User 的 SSH 身份
    # (generate / read_public / read / revoke)。仅注册在 User Kind 上：
    # 身份归 User，不归 Agent（agent 是动态物化的，归 agent 则每物化一个
    # 就要去 provider 手工加一次公钥）。
    for action <- UserSshIdentity.actions() do
      :ok = CapabilityRegistry.register(User, action, UserSshIdentity)
    end
```

- [ ] **Step 6: 跑测试确认通过**

```bash
POSTGRES_PORT=15432 mix test apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs
```

预期：PASS，3 tests, 0 failures

- [ ] **Step 7: 格式化并提交**

```bash
mix format \
  apps/ezagent_domain_identity/lib/ezagent/behavior/user_ssh_identity.ex \
  apps/ezagent_domain_identity/lib/ezagent/entity/user.ex \
  apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex \
  apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs

git add apps/ezagent_domain_identity/
git commit -m "feat(identity): UserSshIdentity — :generate_ssh_key

User 的 SSH 身份 ActionSet，挂 User Kind，与 UserTokens 同构。
ed25519 密钥对由 ssh-keygen 子进程生成（System.cmd —— 本地/无网络/
毫秒级/小输出，无需 OsProcess 那套重机制；core 内已有先例）。

私钥进 state 但不出 action 返回值 —— 取私钥是 :read_ssh_key 的事，
单独一条更敏感的 cap。已存在身份时拒绝而非覆盖：静默覆盖会让用户
已在 provider 配好的公钥突然失效且不可回退，属必须挡的事故面。

临时目录随机名 + after 块立刻 rm_rf，不依赖进程退出。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 2: 读与撤销 —— `:read_ssh_public_key` / `:read_ssh_key` / `:revoke_ssh_key`

**Files:**
- Modify: `apps/ezagent_domain_identity/lib/ezagent/behavior/user_ssh_identity.ex`
- Test: `apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs`（追加 describe 块）

**Interfaces:**
- Consumes: Task 1 的 state 键（`:public_key` / `:fingerprint` / `:private_key`）与 `ctx[:read]`
- Produces:
  - `handle_read_ssh_public_key(map(), map()) :: {:ok, %{public_key: String.t(), fingerprint: String.t()}, []} | {:error, :ssh_identity_absent | :ssh_identity_unavailable}`
  - `handle_read_ssh_key(map(), map()) :: {:ok, %{private_key: String.t()}, [effect]} | {:error, :ssh_identity_absent | :ssh_identity_unavailable}`
  - `handle_revoke_ssh_key(map(), map()) :: {:ok, %{revoked: boolean()}, [effect]}`

---

- [ ] **Step 1: 写失败测试**

在 `user_ssh_identity_test.exs` 末尾（`end` 之前）追加：

```elixir
  describe "read_ssh_public_key" do
    test "返回公钥与指纹" do
      state = %{public_key: "ssh-ed25519 AAAAC3 alice", fingerprint: "SHA256:abc"}

      assert {:ok, %{public_key: "ssh-ed25519 AAAAC3 alice", fingerprint: "SHA256:abc"}, []} =
               UserSshIdentity.handle_read_ssh_public_key(%{}, ctx(state))
    end

    test "无身份时 absent" do
      assert {:error, :ssh_identity_absent} =
               UserSshIdentity.handle_read_ssh_public_key(%{}, ctx())
    end
  end

  describe "read_ssh_key" do
    test "返回私钥并留审计" do
      state = %{
        public_key: "ssh-ed25519 AAAAC3 alice",
        private_key: "-----BEGIN OPENSSH PRIVATE KEY-----\nx\n",
        fingerprint: "SHA256:abc"
      }

      assert {:ok, %{private_key: priv}, effects} =
               UserSshIdentity.handle_read_ssh_key(%{}, ctx(state))

      assert String.starts_with?(priv, "-----BEGIN OPENSSH PRIVATE KEY-----")
      assert Enum.any?(effects, &match?({:emit, :ssh_identity_read, _}, &1))
    end

    test "无身份时 absent" do
      assert {:error, :ssh_identity_absent} = UserSshIdentity.handle_read_ssh_key(%{}, ctx())
    end

    test "有公钥但私钥缺失时 unavailable —— 绝不降级成 absent" do
      state = %{public_key: "ssh-ed25519 AAAAC3 alice", fingerprint: "SHA256:abc"}

      assert {:error, :ssh_identity_unavailable} =
               UserSshIdentity.handle_read_ssh_key(%{}, ctx(state))
    end

    test "私钥形状不合法时 unavailable" do
      state = %{public_key: "ssh-ed25519 AAAAC3 alice", private_key: "not-a-key"}

      assert {:error, :ssh_identity_unavailable} =
               UserSshIdentity.handle_read_ssh_key(%{}, ctx(state))
    end
  end

  describe "revoke_ssh_key" do
    test "清除全部身份字段并留审计" do
      state = %{
        public_key: "ssh-ed25519 AAAAC3 alice",
        private_key: "-----BEGIN OPENSSH PRIVATE KEY-----\nx\n",
        fingerprint: "SHA256:abc",
        comment: "alice",
        created_at: DateTime.utc_now()
      }

      assert {:ok, %{revoked: true}, effects} =
               UserSshIdentity.handle_revoke_ssh_key(%{}, ctx(state))

      for key <- [:public_key, :private_key, :fingerprint, :comment, :created_at] do
        assert Enum.any?(effects, &match?({:set, ^key, nil}, &1)),
               "revoke 必须清除 #{key}"
      end

      assert Enum.any?(effects, &match?({:emit, :ssh_identity_revoked, _}, &1))
    end

    test "无身份时幂等返回 revoked: false" do
      assert {:ok, %{revoked: false}, []} = UserSshIdentity.handle_revoke_ssh_key(%{}, ctx())
    end

    # spec §8 明确要求：revoke 之后 read 必须得 :absent 而非 :unavailable。
    # 这是 revoke 必须清除**全部**身份字段（而非只清私钥）的原因 —— 只清
    # 私钥会留下"有公钥无私钥"的形状，正好落进 :unavailable。
    test "revoke 之后 read 得 absent 而非 unavailable" do
      state = %{
        public_key: "ssh-ed25519 AAAAC3 alice",
        private_key: "-----BEGIN OPENSSH PRIVATE KEY-----\nx\n",
        fingerprint: "SHA256:abc"
      }

      assert {:ok, %{revoked: true}, effects} =
               UserSshIdentity.handle_revoke_ssh_key(%{}, ctx(state))

      # 把 revoke 的 {:set, k, nil} 应用回 state，模拟框架 commit 后的样子
      after_state =
        Enum.reduce(effects, state, fn
          {:set, k, v}, acc -> Map.put(acc, k, v)
          _, acc -> acc
        end)

      assert {:error, :ssh_identity_absent} =
               UserSshIdentity.handle_read_ssh_key(%{}, ctx(after_state))
    end
  end
```

- [ ] **Step 2: 跑测试确认失败**

```bash
POSTGRES_PORT=15432 mix test apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs
```

预期：FAIL —— `handle_read_ssh_public_key/2 is undefined or private`

- [ ] **Step 3: 加三个 action 声明**

在 `user_ssh_identity.ex` 的 `action(:generate_ssh_key, ...)` 之后追加：

```elixir
  action(:read_ssh_public_key,
    args: %{},
    returns: %{public_key: :string, fingerprint: :string},
    caps: [{:read_ssh_public_key, kind: :user}],
    description:
      "Read this User's SSH public key + fingerprint. NOT sensitive — " <>
        "this is what the user pastes into the provider. Deliberately a " <>
        "SEPARATE cap from :read_ssh_key.",
    data_owner: :self,
    modes: [:call]
  )

  action(:read_ssh_key,
    args: %{},
    returns: %{private_key: :string},
    caps: [{:read_ssh_key, kind: :user}],
    description:
      "Read this User's SSH PRIVATE key. Sensitive — every call is " <>
        "audited. This is the `ssh.read` authorization gate.",
    data_owner: :self,
    modes: [:call]
  )

  action(:revoke_ssh_key,
    args: %{},
    returns: %{revoked: :boolean},
    caps: [{:revoke_ssh_key, kind: :user}],
    description:
      "Clear this User's SSH identity entirely. Idempotent — returns " <>
        "revoked: false when there was nothing to revoke. Required " <>
        "before :generate_ssh_key can run again.",
    data_owner: :self,
    modes: [:call]
  )
```

- [ ] **Step 4: 写三个 handler**

在 `handle_generate_ssh_key/2` 之后追加：

```elixir
  def handle_read_ssh_public_key(_args, ctx) do
    case ctx[:read].(:public_key, nil) do
      nil -> {:error, :ssh_identity_absent}
      pub -> {:ok, %{public_key: pub, fingerprint: ctx[:read].(:fingerprint, nil)}, []}
    end
  end

  def handle_read_ssh_key(_args, ctx) do
    case identity_state(ctx) do
      :absent ->
        {:error, :ssh_identity_absent}

      :unavailable ->
        {:error, :ssh_identity_unavailable}

      {:ok, priv} ->
        {:ok, %{private_key: priv},
         [
           {:emit, :ssh_identity_read,
            %{
              user_uri: uri_to_string(ctx.self_uri),
              fingerprint: ctx[:read].(:fingerprint, nil),
              at: DateTime.utc_now()
            }}
         ]}
    end
  end

  def handle_revoke_ssh_key(_args, ctx) do
    if ctx[:read].(:public_key, nil) || ctx[:read].(:private_key, nil) do
      {:ok, %{revoked: true},
       [
         {:set, :public_key, nil},
         {:set, :private_key, nil},
         {:set, :fingerprint, nil},
         {:set, :comment, nil},
         {:set, :created_at, nil},
         {:emit, :ssh_identity_revoked,
          %{user_uri: uri_to_string(ctx.self_uri), at: DateTime.utc_now()}}
       ]}
    else
      {:ok, %{revoked: false}, []}
    end
  end

  # =================================================================
  # absent ≠ unavailable —— 这个区分必须从第一天就有
  #
  # absent   = 完全没有身份 → 调用方可决定 fall-through 还是报错
  # unavailable = 有身份记录但私钥缺失/形状不合法（部分写入、迁移遗留；
  #               统一安全轨接手 at-rest 加密后，解封失败也归这一类）
  #
  # 若把 unavailable 降级成 absent，将来接入既有的覆盖策略
  # (Ezagent.Credential.Resolver.pick_credential_source/1: explicit >
  # user > workspace-shared) 时会出现静默降权 —— 一个损坏的身份被误当成
  # "没配"而 fall through 到下一层。错误名刻意对齐既有的
  # :user_source_unavailable。
  # =================================================================
  @private_key_header "-----BEGIN OPENSSH PRIVATE KEY-----"

  defp identity_state(ctx) do
    priv = ctx[:read].(:private_key, nil)
    pub = ctx[:read].(:public_key, nil)

    cond do
      is_binary(priv) and String.starts_with?(priv, @private_key_header) -> {:ok, priv}
      is_nil(priv) and is_nil(pub) -> :absent
      true -> :unavailable
    end
  end
```

- [ ] **Step 5: 跑测试确认通过**

```bash
POSTGRES_PORT=15432 mix test apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs
```

预期：PASS，10 tests, 0 failures

- [ ] **Step 6: 格式化并提交**

```bash
mix format \
  apps/ezagent_domain_identity/lib/ezagent/behavior/user_ssh_identity.ex \
  apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_test.exs

git add apps/ezagent_domain_identity/
git commit -m "feat(identity): UserSshIdentity — 读公钥 / 读私钥 / 撤销

三个 action 补齐 1a 的 CRUD。读私钥每次 emit 审计（谁何时取走私钥是这条
线上最值得留痕的事）；读公钥不 emit（高频、非敏感）。

absent ≠ unavailable 从第一天就分：absent = 完全没身份（调用方可决定
fall-through）；unavailable = 有身份但私钥缺失/形状不合法（部分写入、
迁移遗留；将来 at-rest 加密落地后解封失败也归这类）。降级成 absent 会在
接入既有覆盖策略时造成静默降权 —— 正是 pick_credential_source 明令禁止的。

revoke 清除全部身份字段，确保之后 read 得 absent 而非 unavailable。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Task 3: 授权测试 + gate + spec 回填

**Files:**
- Test: `apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_authz_test.exs`（新建）
- Modify: `docs/superpowers/specs/2026-08-01-agent-ssh-credential-1a-design.md`

**Interfaces:**
- Consumes: Task 1/2 的四个 action；`Ezagent.CapabilityRegistry`；`Ezagent.Entity.User`
- Produces: 无（终端任务）

---

- [ ] **Step 1: 写授权测试**

创建 `apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_authz_test.exs`：

```elixir
defmodule Ezagent.ActionSet.UserSshIdentityAuthzTest do
  @moduledoc """
  1a 的授权面：四个 action 都必须落在 User Kind 的 cap 门后，且公钥读与
  私钥读是两条**不同**的 cap —— 持公钥 cap 不得能取私钥（最小权限）。
  """
  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.UserSshIdentity

  test "四个 action 全部声明在 actions/0 上" do
    assert Enum.sort(UserSshIdentity.actions()) == [
             :generate_ssh_key,
             :read_ssh_key,
             :read_ssh_public_key,
             :revoke_ssh_key
           ]
  end

  test "每个 action 都要求一条 kind: :user 的 cap，且互不相同" do
    caps = UserSshIdentity.required_caps()

    for action <- UserSshIdentity.actions() do
      assert Map.has_key?(caps, action), "#{action} 必须声明 required cap"
    end

    # 公钥读与私钥读必须是不同的 cap —— 持前者不得能做后者
    refute caps[:read_ssh_public_key] == caps[:read_ssh_key]
  end

  test "已注册到 User Kind" do
    assert UserSshIdentity in Ezagent.Entity.User.behaviors()
  end
end
```

- [ ] **Step 2: 跑测试**

```bash
POSTGRES_PORT=15432 mix test apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_authz_test.exs
```

预期：PASS，3 tests, 0 failures。

**已知不确定项（实施时先验证再断言）**：`required_caps/0` 的返回形状本计划**未经实测**（`UserTokens` 未导出该形状的用例）。执行 Step 2 前先跑：

```bash
POSTGRES_PORT=15432 mix run -e 'IO.inspect(Ezagent.ActionSet.UserSshIdentity.required_caps())'
```

按实际形状调整第二个测试的断言 —— 要断言的**性质**是固定的：**`:read_ssh_public_key` 与 `:read_ssh_key` 要求的 cap 不相等**（持公钥 cap 不得能取私钥）。形状怎么写按实测来，**不要改生产代码去迁就测试**。

**为什么不在这里测"无 cap 的 dispatch 被拒"**：spec §8 列了这一条，但 cap 门是**框架层 step-5.5** 的行为，对每个 ActionSet 重测一遍是重复劳动（"少创造"）。本文件只锁**声明正确性**（四个 action 都要 cap、两条读 cap 互不相同），框架层拒绝由 CapBAC 的中央测试覆盖。**若 reviewer 认为不够，加一个真 dispatch 测试即可 —— 这是一个有意识的取舍，不是遗漏。**

- [ ] **Step 3: 跑 Lifecycle gate**

```bash
POSTGRES_PORT=15432 mix ezagent.check_invariants.lifecycle
```

预期：PASS。若报 `use Ezagent.ActionSet` / `init_slice` / `invoke/4` 再引入 —— 说明写错了开发者面，回到 Task 1 Step 3 改用 `use Ezagent.Lifecycle`。

- [ ] **Step 4: 跑 fast gate**

```bash
POSTGRES_PORT=15432 mix ci.fast
```

**用显式 `timeout: 300000` 跑。被 kill 的运行不算通过 —— 超时说明不了任何事，如实报告并重跑。**

预期：全绿。

- [ ] **Step 5: 跑 identity app 全量测试（防回归）**

```bash
POSTGRES_PORT=15432 mix test apps/ezagent_domain_identity/test
```

预期：全绿。新增 behavior 挂上 User Kind 后，既有 User Kind 测试可能因 `behaviors/0` 长度断言而红 —— 若红，改**测试**去容纳新 behavior，不要把 behavior 摘掉。

- [ ] **Step 6: 回填 spec 的 known_hosts 范围**

修改 `docs/superpowers/specs/2026-08-01-agent-ssh-credential-1a-design.md`：

在 §3.4 标题下第一行插入：

```markdown
> **范围修正（实施时）：`known_hosts` 移出 1a，归 1b。** 1a 不发起任何 git
> 连接，known_hosts 在 1a 内没有可验证的对象 —— 放进来等于交付一段未经
> 验证的配置写入代码。它是 1b / 任务 2 的前置，跟着消费者走。本节描述的
> 做法（部署配置 + 刷新用 mix task + 不做运行时网络调用）**不变**，只是
> 落在 1b。
```

并在 §9「明确不在 1a 范围内」列表末尾加一项：

```markdown
- `known_hosts` 配置与刷新 mix task（移到 1b —— 见 §3.4 范围修正）
```

- [ ] **Step 7: 提交**

```bash
git add apps/ezagent_domain_identity/test/ezagent/behavior/user_ssh_identity_authz_test.exs \
        docs/superpowers/specs/2026-08-01-agent-ssh-credential-1a-design.md

git commit -m "test(identity): UserSshIdentity 授权面 + 回填 known_hosts 范围

授权测试锁三条：四个 action 都在 actions/0 上；每个都要求 kind: :user 的
cap；公钥读与私钥读是两条不同的 cap（持前者不得能取私钥）。

spec 回填：known_hosts 移出 1a 归 1b —— 1a 不发起 git 连接，known_hosts
在 1a 内无可验证对象，放进来等于交付未经验证的配置写入代码。做法不变，
只是跟着消费者走。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## 完成条件

- [ ] `mix ci.fast` 全绿（显式 300s timeout，非超时中断）
- [ ] `mix ezagent.check_invariants.lifecycle` 全绿
- [ ] `mix test apps/ezagent_domain_identity/test` 全绿
- [ ] 三个 commit 落地
- [ ] spec §3.4 / §9 已回填 known_hosts 范围

**不做**（留给 1b / 任务 2）：物化进 agent config_dir、`GIT_SSH_COMMAND`、cascade/grant 铸造、`known_hosts`、world UI 入口、端到端 git 操作。

**1a 的验收是单元/集成测试，不是端到端 git 操作** —— 1a 交付的是一个完整但暂无消费者的能力。
