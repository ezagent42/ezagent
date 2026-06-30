defmodule EzagentPluginGithub.IdentityTokenTest do
  @moduledoc """
  T8 —— github per-identity token（gateway 按 `ctx.caller` 选 token）。

  范式照 `Ezagent.Behavior.ApiKeys`（per-entity `:api_keys` slice + data-owner gate）：
  每个 caller 的 github PAT 存在它自己 Agent Kind 的 `:api_keys` slice（provider
  `"github"`），经复用的 `put_api_key` 写（cap-gated）。本测试用真 Agent Kind（spawn +
  dispatch）覆三件事：

    1. **存+读回 + data-owner gate**：持 put cap 的 caller 能写自己的 token、`token_for_caller/1`
       读回；无 cap 的他人 dispatch 被 step 5.5 拒（`:unauthorized`）——不另造写路径，gate 复用 ApiKeys。
    2. **gateway 按 caller 选**：caller A 配了 → `{:ok, tokenA}`；caller B 没配 → `:none`
       （调用方落全局 fallback）。
    3. **不破全局路径**：caller 非 entity / nil → `:none`（落全局 `github.yaml`），现有
       `token_env/0` + `*_args/N` 单测仍绿（`gh_test.exs`）。

  token 用假值（`ghp_*`），绝不打真网、绝不暴露明文。
  """
  use Ezagent.LifecycleCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Invocation
  alias EzagentPluginGithub.Creds

  @workspace "team-alpha"

  setup do
    # `:ezagent_domain_agent` 是 only:test dep（非运行时自启）——spawn Entity.Agent 前先起。
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    :ok
  end

  defp agent_uri(label) do
    Ezagent.URI.new!(
      "entity://#{@workspace}/agent/gh-tok-#{label}-#{System.unique_integer([:positive])}"
    )
  end

  # 真 Agent Kind（base_behaviors 含 ApiKeys），等 ready。
  defp spawn_agent!(label) do
    uri = agent_uri(label)

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: uri,
        behaviors: Ezagent.Entity.Agent.base_behaviors()
      })

    wait_for(fn -> Ezagent.ReadyGate.status(uri) == :ready end)
    uri
  end

  # 实例级 put_api_key cap（照 curl `target_put_api_key_cap`）。
  defp put_cap(uri) do
    Capability.cap(
      :any,
      Ezagent.Behavior.ApiKeys,
      :put_api_key,
      Ezagent.URI.instance(uri),
      Capability.workspace_of(uri)
    )
  end

  # 持 put cap 的授权写：把 caller 自己的 github PAT 落进自己的 `:api_keys` slice。
  defp put_github_token!(uri, token) do
    assert {:ok, _} =
             Invocation.dispatch(%Invocation{
               target: Ezagent.URI.with_action(uri, :api_keys, :put_api_key),
               mode: :call,
               args: %{provider: "github", key: token},
               ctx: %{caller: uri, caps: [put_cap(uri)], reply: {:caller_inbox, self()}}
             })
  end

  describe "存 + 读回（per-identity，复用 ApiKeys slice）" do
    test "持 cap 的 caller 写自己的 github PAT → token_for_caller/1 读回" do
      a = spawn_agent!("owner")
      put_github_token!(a, "ghp_owner_aaaaaaaaaaaa")

      assert {:ok, "ghp_owner_aaaaaaaaaaaa"} = Creds.token_for_caller(a)

      Ezagent.Kind.terminate(a)
    end

    test "data-owner gate：无 cap 的他人 dispatch 被拒（:unauthorized）" do
      a = spawn_agent!("gated")

      # 陌生 caller、空 caps、无 slice cap → step 5.5 authz_check 拒（非静默丢）。
      stranger = Ezagent.URI.new!("entity://#{@workspace}/agent/stranger")

      assert {:error, :unauthorized} =
               Invocation.dispatch(%Invocation{
                 target: Ezagent.URI.with_action(a, :api_keys, :put_api_key),
                 mode: :call,
                 args: %{provider: "github", key: "ghp_intruder_xxxxxxxx"},
                 ctx: %{caller: stranger, caps: [], reply: {:caller_inbox, self()}}
               })

      # token 未被写入（slice 仍空）。
      assert :none = Creds.token_for_caller(a)

      Ezagent.Kind.terminate(a)
    end
  end

  describe "gateway 按 ctx.caller 选 token" do
    test "caller A 配了 → 用 A 的；caller B 没配 → :none（落全局 fallback）" do
      a = spawn_agent!("sel-a")
      b = spawn_agent!("sel-b")

      put_github_token!(a, "ghp_a_token_aaaaaaaa")

      assert {:ok, "ghp_a_token_aaaaaaaa"} = Creds.token_for_caller(a)
      assert :none = Creds.token_for_caller(b)

      Ezagent.Kind.terminate(a)
      Ezagent.Kind.terminate(b)
    end
  end

  describe "不破全局路径" do
    test "非 entity / nil caller → :none（调用方落全局 github.yaml）" do
      assert :none = Creds.token_for_caller(nil)
      assert :none = Creds.token_for_caller(:vm_internal)
      assert :none = Creds.token_for_caller("not-a-uri")
    end

    test "caller Kind 无 :api_keys（不 live、无快照）→ :none" do
      ghost =
        Ezagent.URI.new!(
          "entity://#{@workspace}/agent/gh-ghost-#{System.unique_integer([:positive])}"
        )

      assert :none = Creds.token_for_caller(ghost)
    end
  end

  # 轮询等条件（照 curl_cascade_activation_test 本地 helper；ReadyGate 是异步态）。
  defp wait_for(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition was not met before timeout")

      true ->
        Process.sleep(10)
        do_wait_until(fun, deadline)
    end
  end
end
