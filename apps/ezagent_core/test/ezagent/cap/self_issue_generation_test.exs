defmodule Ezagent.Cap.SelfIssueGenerationTest do
  @moduledoc """
  G-6/MF5: a live target whose cached signer is older than the durable active
  generation cannot construct or sign a new self-target artifact.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.{Authority, Grant}
  alias Ezagent.{Cap, Capability, Invocation}
  alias Ezagent.Test.{SelfIssueBehavior, SelfIssueKind}

  setup do
    previous = Application.get_env(:ezagent_core, Ezagent.Cap, [])
    admin = admin()
    caller = unique_user("caller")

    Application.put_env(
      :ezagent_core,
      Ezagent.Cap,
      Keyword.put(previous, :authority_loader, EzagentCore.Test.CapAuthorityLoaderStub)
    )

    Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{
      Ezagent.URI.stable_key(admin) => MapSet.new([:admin_self_license]),
      Ezagent.URI.stable_key(caller) => MapSet.new([:caller_self_license])
    })

    :ok = Ezagent.BehaviorRegistry.register(SelfIssueKind, :mint_for_self, SelfIssueBehavior)
    :ok = Ezagent.BehaviorRegistry.register(SelfIssueKind, :noop, SelfIssueBehavior)

    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, previous) end)

    {:ok, caller: caller}
  end

  test "externally bumped live target refuses self-issue from its stale process signer", %{
    caller: caller
  } do
    target = spawn_target("stale")
    assert {:ok, new_authority} = Authority.regenesis(target, :agent)
    invoke_cap = issue_direct!(new_authority, caller, requested(target, :mint_for_self))

    assert {:error, :stale_target_generation} = dispatch_mint(target, caller, invoke_cap)
  end

  test "current-generation live target can still self-issue", %{caller: caller} do
    target = spawn_target("current")
    invoke_cap = issue!(caller, requested(target, :mint_for_self))
    assert {:ok, %{key_id: key_id}} = dispatch_mint(target, caller, invoke_cap)

    assert {:ok, current_generation} = Authority.current_generation(target)
    assert String.starts_with?(key_id, "kind-g#{current_generation}:")
  end

  defp dispatch_mint(target, caller, cap) do
    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: Ezagent.URI.with_action(target, :self_issue, :mint_for_self),
      mode: :call,
      args: %{},
      ctx: %{
        caller: caller,
        authenticated_principal: caller,
        caps: MapSet.new([cap]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp spawn_target(suffix) do
    target =
      Ezagent.URI.agent(
        "self-issue-generation",
        "#{suffix}-#{System.unique_integer([:positive])}"
      )

    assert {:ok, _pid} = Ezagent.Kind.spawn(SelfIssueKind, %{uri: target, initial_caps: []})
    wait_until_ready(target)

    on_exit(fn ->
      _ = Ezagent.Lifecycle.destroy(target, :test_cleanup)
    end)

    target
  end

  defp issue!(grantee, requested) do
    assert {:ok, cap} = Cap.issue({:admin, admin()}, grantee, requested)
    cap
  end

  defp issue_direct!(authority, grantee, requested) do
    intent = Grant.freeze(requested.instance, admin(), grantee, requested)

    assert {:ok, cap} =
             Authority.with_current(authority, fn -> Authority.issue_current(intent) end)

    cap
  end

  defp requested(target, action) do
    Capability.cap(
      :agent,
      SelfIssueBehavior,
      action,
      target,
      Capability.workspace_of(target)
    )
  end

  defp unique_user(suffix) do
    Ezagent.URI.user(
      "self-issue-generation",
      "#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp admin, do: Ezagent.URI.user(:system, :admin)

  defp wait_until_ready(uri, attempts \\ 100)
  defp wait_until_ready(_uri, 0), do: flunk("target did not become ready")

  defp wait_until_ready(uri, attempts) do
    case Ezagent.ReadyGate.status(uri) do
      :ready ->
        :ok

      _ ->
        Process.sleep(10)
        wait_until_ready(uri, attempts - 1)
    end
  end
end
