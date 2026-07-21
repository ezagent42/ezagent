defmodule Ezagent.Kind.DefaultHoldsCapSignedTest do
  @moduledoc """
  Unified-revocation F-2: the legacy identity-slice authorization engine must
  reject a dormant capability as soon as its target generation is bumped.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.Authority
  alias Ezagent.Capability
  alias Ezagent.Test.{TestBehavior, TestKind}

  setup do
    :ok = Ezagent.BehaviorRegistry.register(TestKind, :noop, TestBehavior)
    :ok
  end

  test "default_holds_cap? denies a slice-held cap whose target generation was bumped" do
    target = unique_uri("target")
    holder = unique_user("holder")

    assert {:ok, _pid} = Ezagent.Kind.Server.start_link({TestKind, %{uri: target}})
    assert :ok = await_ready(target)

    cap = mint_signed_cap_for(target, holder)
    assert {:ok, _user} = Ezagent.Users.create(holder, nil, [cap])
    assert {:ok, _holder_pid} = Ezagent.SpawnRegistry.spawn(holder)
    assert :ok = await_ready(holder)

    needed = needed_for(target)
    assert Ezagent.Kind.default_holds_cap?(holder, needed)

    assert {:ok, _bumped} = Authority.regenesis(target, :test, admin())

    refute Ezagent.Kind.default_holds_cap?(holder, needed)
  end

  defp mint_signed_cap_for(target, holder) do
    {:ok, cap} = Ezagent.Cap.issue({:admin, admin()}, holder, action_cap(target))
    cap
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
    %Capability{
      action_cap(target)
      | granted_by: admin(),
        granted_at: DateTime.utc_now()
    }
  end

  defp unique_uri(suffix) do
    Ezagent.URI.new!(
      "entity://team-alpha/agent/f2-slice-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp unique_user(suffix) do
    Ezagent.URI.new!(
      "entity://team-alpha/user/f2-slice-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp admin, do: Ezagent.URI.user(:system, :admin)

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
