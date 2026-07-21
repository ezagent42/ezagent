defmodule Ezagent.Cap.AuthorizeTest do
  @moduledoc """
  Unified-revocation Phase F-1 — the `Ezagent.Cap.authorize/3` facade: the
  single chokepoint later phases (F-2..F-6, G, M) extend. It takes an explicit
  authenticated holder, resolves the principal gate from the holder's
  INDEPENDENTLY LOADED caps (never from the presented candidates — MF2), then
  verifies each candidate against the target's CURRENT active authority row
  (`Authority.verify_against_current/3` — the fresh-read revocation basis).
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

    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, previous) end)

    # Every test starts revoked (empty independent load) unless it explicitly
    # licenses the holder — the stub env is BEAM-global and tests shuffle.
    license_holder(MapSet.new())
    :ok
  end

  test "authorize/3 denies a revoked holder even when it presents a valid cap inline (MF2)" do
    {uri, _pid, holder} = start_target("revoked-holder")
    valid = mint_signed_cap_for(uri, holder)

    # The holder's independently-loaded set is EMPTY (stub loader default) —
    # the presented inline candidate can never satisfy the principal gate.
    assert {:error, :holder_revoked} =
             Ezagent.Cap.authorize(holder, [valid], needed_for(uri))
  end

  test "authorize/3 returns {:ok, cap} for a licensed holder presenting a current-gen match" do
    {uri, _pid, holder} = start_target("licensed")
    cap = mint_signed_cap_for(uri, holder)
    license_holder(MapSet.new([cap]))

    assert {:ok, authorized} = Ezagent.Cap.authorize(holder, [cap], needed_for(uri))
    assert authorized == cap
  end

  test "authorize/3 denies with :no_matching_cap when no verified candidate matches" do
    {uri, _pid, holder} = start_target("no-match")
    cap = mint_signed_cap_for(uri, holder)
    license_holder(MapSet.new([cap]))

    wrong_action = %{needed_for(uri) | action: :fail}

    assert {:error, :no_matching_cap} =
             Ezagent.Cap.authorize(holder, [cap], wrong_action)
  end

  test "authorize/3 denies an old-gen cap after the target's generation bumps" do
    {uri, _pid, holder} = start_target("bump")
    cap = mint_signed_cap_for(uri, holder)
    license_holder(MapSet.new([cap]))

    assert {:ok, _} = Ezagent.Cap.authorize(holder, [cap], needed_for(uri))

    {:ok, _bumped} = Authority.regenesis(uri, :test, admin())

    assert {:error, :no_matching_cap} =
             Ezagent.Cap.authorize(holder, [cap], needed_for(uri))
  end

  test "authorize/3 denies unsigned candidates presented by a licensed holder" do
    {uri, _pid, holder} = start_target("unsigned")
    license_holder(MapSet.new([:holder_is_licensed]))

    unsigned = %{
      action_cap(uri)
      | granted_by: admin(),
        granted_at: DateTime.utc_now(),
        grantee_uri: holder
    }

    assert {:error, :no_matching_cap} =
             Ezagent.Cap.authorize(holder, [unsigned], needed_for(uri))
  end

  defp license_holder(caps) do
    Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, caps)
  end

  defp start_target(suffix) do
    uri = unique_uri(suffix)
    holder = unique_user(suffix)
    assert {:ok, pid} = Ezagent.Kind.Server.start_link({TestKind, %{uri: uri}})
    assert :ok = await_ready(uri)
    {uri, pid, holder}
  end

  defp mint_signed_cap_for(uri, grantee) do
    # Issuance itself goes through authorize/3, so license the canonical admin
    # independently for exactly the duration of this fixture mint. Restore the
    # test's holder state afterwards so the revoked-holder case stays revoked.
    previous =
      Application.get_env(
        :ezagent_core,
        EzagentCore.Test.CapAuthorityLoaderStub,
        MapSet.new()
      )

    license_holder(MapSet.new([:admin_self_license]))
    result = Ezagent.Cap.issue({:admin, admin()}, grantee, action_cap(uri))
    Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, previous)

    {:ok, cap} = result
    cap
  end

  defp action_cap(uri) do
    Capability.cap(
      :test,
      TestBehavior,
      :noop,
      Ezagent.URI.instance(uri),
      Capability.workspace_of(uri)
    )
  end

  defp needed_for(uri) do
    %{
      kind: :test,
      behavior: TestBehavior,
      action: :noop,
      instance: Ezagent.URI.instance(uri),
      workspace_uri: Capability.workspace_of(uri)
    }
  end

  defp unique_uri(suffix) do
    Ezagent.URI.new!(
      "entity://team-alpha/agent/authorize-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp unique_user(suffix) do
    Ezagent.URI.new!(
      "entity://team-alpha/user/authorize-#{suffix}-#{System.unique_integer([:positive])}"
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
