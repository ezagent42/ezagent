defmodule Ezagent.Identity.CapsAuthorizeSignedTest do
  @moduledoc """
  Unified-revocation F-2: the identity-domain read/preflight predicate must
  reject a target-signed capability after the target generation changes.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.Authority
  alias Ezagent.Capability
  alias Ezagent.Test.{TestBehavior, TestKind}

  setup do
    :ok = Ezagent.BehaviorRegistry.register(TestKind, :noop, TestBehavior)

    previous = Application.get_env(:ezagent_core, Ezagent.Cap, [])

    Application.put_env(
      :ezagent_core,
      Ezagent.Cap,
      Keyword.put(previous, :authority_loader, EzagentCore.Test.CapAuthorityLoaderStub)
    )

    Application.put_env(
      :ezagent_core,
      EzagentCore.Test.CapAuthorityLoaderStub,
      MapSet.new([:independent_holder_license])
    )

    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, previous) end)
    :ok
  end

  test "caps_authorize? denies a capability whose target generation was bumped" do
    target = unique_uri("target")
    holder = unique_user("holder")

    assert {:ok, _pid} = Ezagent.Kind.Server.start_link({TestKind, %{uri: target}})
    assert :ok = await_ready(target)

    cap = mint_signed_cap_for(target, holder)
    license_holder(cap)
    needed = needed_for(target)

    assert Ezagent.Identity.caps_authorize?(holder, [cap], needed)
    assert {:ok, _bumped} = Authority.regenesis(target, :test)
    refute Ezagent.Identity.caps_authorize?(holder, [cap], needed)
  end

  defp license_holder(cap) do
    Application.put_env(
      :ezagent_core,
      EzagentCore.Test.CapAuthorityLoaderStub,
      MapSet.new([cap])
    )
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
    %{
      kind: :test,
      behavior: TestBehavior,
      action: :noop,
      instance: Ezagent.URI.instance(target),
      workspace_uri: Capability.workspace_of(target)
    }
  end

  defp unique_uri(suffix) do
    Ezagent.URI.new!(
      "entity://team-alpha/agent/f2-identity-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp unique_user(suffix) do
    Ezagent.URI.new!(
      "entity://team-alpha/user/f2-identity-#{suffix}-#{System.unique_integer([:positive])}"
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
