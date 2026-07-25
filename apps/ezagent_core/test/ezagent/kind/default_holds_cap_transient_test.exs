defmodule Ezagent.Kind.DefaultHoldsCapTransientTest do
  @moduledoc """
  Ratchet for the per-Kind authority cutover: authorization no longer reads a
  presenter's identity slice through `Kind.default_holds_cap?/2`. That legacy
  path could turn identity-read availability into an authorization outcome and
  could not validate a target-private signature.
  """

  use EzagentCore.DataCase, async: false

  @moduletag :umbrella_only

  alias Ezagent.{Capability, Kind, Users}

  @needed %Capability{
    kind: :session,
    behavior: Ezagent.ActionSet.Session,
    action: :send,
    instance: :any,
    workspace_uri: :any,
    granted_by: nil,
    granted_at: ~U[2026-01-01 00:00:00Z]
  }

  test "legacy identity-slice authorization is closed for an absent entity" do
    uri = Ezagent.URI.new!("entity://team-alpha/user/closed-absent-#{unique()}")
    refute Kind.default_holds_cap?(uri, @needed)
  end

  test "legacy identity-slice authorization is closed even when a live entity stores a wildcard" do
    uri_string = "entity://team-alpha/user/closed-live-#{unique()}"

    unsigned_wildcard = %{
      Capability.admin_genesis_cap()
      | grantee_uri: Ezagent.URI.new!(uri_string)
    }

    assert {:ok, _} = Users.create(uri_string, nil, [unsigned_wildcard])
    uri = Ezagent.URI.new!(uri_string)
    assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)

    refute Kind.default_holds_cap?(uri, @needed)
  end

  test "legacy helper may fail loud, but the target verifier never calls it" do
    uri = Ezagent.URI.new!("entity://team-alpha/user/closed-transient-#{unique()}")
    parent = self()

    dummy =
      spawn(fn ->
        :ok = Ezagent.KindRegistry.put_new(uri)
        send(parent, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered, 1_000
    on_exit(fn -> Process.exit(dummy, :kill) end)

    assert_raise Kind.IdentityReadError, fn -> Kind.default_holds_cap?(uri, @needed) end

    runtime =
      File.read!(Path.expand("../../../ezagent_actor/lib/ezagent/kind/runtime.ex", __DIR__))

    verifier = File.read!(Path.expand("../../../lib/ezagent/cap/verifier.ex", __DIR__))
    refute runtime =~ "default_holds_cap?"
    refute verifier =~ "default_holds_cap?"
  end

  defp unique, do: System.unique_integer([:positive])
end
