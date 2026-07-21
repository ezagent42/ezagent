defmodule Ezagent.Cap.RevokeAllToTest do
  @moduledoc """
  Unified-revocation G-1: target-wide revocation is authorized by the target's
  existing grant/manage capability, never by URI equality. The bump runs in the
  live target process, atomically flips the durable active authority row, and
  swaps the process-private authority before replying.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Ecto.KindCapAuthority
  alias Ezagent.Test.{TestBehavior, TestKind}

  setup do
    previous = Application.get_env(:ezagent_core, Ezagent.Cap, [])
    admin = Ezagent.URI.user(:system, :admin)
    manager = unique_user("manager")
    attacker = unique_user("attacker")

    Application.put_env(
      :ezagent_core,
      Ezagent.Cap,
      Keyword.put(previous, :authority_loader, EzagentCore.Test.CapAuthorityLoaderStub)
    )

    Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{
      Ezagent.URI.stable_key(admin) => MapSet.new([:admin_self_license]),
      Ezagent.URI.stable_key(manager) => MapSet.new([:manager_self_license]),
      Ezagent.URI.stable_key(attacker) => MapSet.new([:attacker_self_license])
    })

    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, previous) end)

    :ok = Ezagent.BehaviorRegistry.register(TestKind, :noop, TestBehavior)
    {:ok, admin: admin, manager: manager, attacker: attacker}
  end

  test "caller lacking target manage authority cannot bump and generation is unchanged", ctx do
    {target, _pid} = start_target("denied")

    assert {:error, :no_matching_cap} =
             Ezagent.Cap.revoke_all_to(target, auth_ctx(ctx.attacker, MapSet.new()))

    assert generation(target) == 1
  end

  test "target manager bumps the live authority and old-gen caps deny immediately", ctx do
    {target, pid} = start_target("manager")
    manage_cap = issue!(ctx.admin, ctx.manager, manage_cap(target))
    action_cap = issue!(ctx.admin, ctx.manager, action_cap(target))

    assert {:ok, ^action_cap} =
             Ezagent.Cap.authorize(ctx.manager, [action_cap], needed_for(target))

    assert {:ok, 2} =
             Ezagent.Cap.revoke_all_to(
               target,
               auth_ctx(ctx.manager, MapSet.new([manage_cap]))
             )

    assert generation(target) == 2
    assert :sys.get_state(pid).authority.generation == 2

    assert Enum.any?(Ezagent.EventLog.stream_by_aggregate(target), fn event ->
             event.event_name == "cap_revoked_all" and
               event.caller == Ezagent.URI.stable_key(ctx.manager) and
               event.payload == %{"new_generation" => 2}
           end)

    assert {:error, :no_matching_cap} =
             Ezagent.Cap.authorize(ctx.manager, [action_cap], needed_for(target))
  end

  defp start_target(suffix) do
    target = unique_target(suffix)
    assert {:ok, pid} = Ezagent.Kind.Server.start_link({TestKind, %{uri: target}})
    assert :ok = await_ready(target)
    {target, pid}
  end

  defp issue!(admin, grantee, requested) do
    assert {:ok, cap} = Ezagent.Cap.issue({:admin, admin}, grantee, requested)
    cap
  end

  defp manage_cap(target) do
    Capability.cap(
      :test,
      Ezagent.Cap.Grant,
      :grant,
      Ezagent.URI.instance(target),
      Capability.workspace_of(target)
    )
  end

  defp action_cap(target) do
    Capability.cap(
      :test,
      TestBehavior,
      :noop,
      Ezagent.URI.instance(target),
      Capability.workspace_of(target)
    )
  end

  defp needed_for(target) do
    %{
      kind: :test,
      behavior: TestBehavior,
      action: :noop,
      instance: Ezagent.URI.instance(target),
      workspace_uri: Capability.workspace_of(target)
    }
  end

  defp auth_ctx(holder, caps) do
    %{
      caller: Ezagent.URI.new!("system://cap-revocation/operator"),
      authenticated_principal: holder,
      caps: caps,
      trace_id: "g1-revoke-all"
    }
  end

  defp generation(target) do
    target
    |> Ezagent.URI.stable_key()
    |> KindCapAuthority.active()
    |> Map.fetch!(:generation)
  end

  defp unique_target(suffix) do
    Ezagent.URI.new!(
      "entity://team-alpha/agent/revoke-all-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp unique_user(suffix) do
    Ezagent.URI.new!(
      "entity://team-alpha/user/revoke-all-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp await_ready(uri), do: await_ready(uri, System.monotonic_time(:millisecond) + 1_000)

  defp await_ready(uri, deadline) do
    case Ezagent.ReadyGate.status(uri) do
      :ready ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(5)
          await_ready(uri, deadline)
        end
    end
  end
end
