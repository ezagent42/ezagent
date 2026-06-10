defmodule EzagentPluginAutoservice.SocialwareCSAdapterSupervisionTest do
  @moduledoc """
  Live wiring — `SocialwareCS.ensure_adapter/3` lazily + idempotently starts
  the per-session CS turn adapter under the plugin's `AdapterSupervisor`,
  registered by session-URI string in `AdapterRegistry`.

  The adapter GenServer itself is exercised in `socialware_cs_turn_test.exs`;
  this test asserts the SUPERVISION wiring only: a first `ensure_adapter` call
  starts an alive, registry-discoverable process, and a second call is a no-op
  returning the SAME pid.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.SocialwareSession
  alias EzagentPluginAutoservice.SocialwareCS

  defp setup_session do
    n = System.unique_integer([:positive])
    session = Ezagent.URI.session(:team_alpha, :cs, "cs-adapter-#{n}")
    customer = Ezagent.URI.user(:team_alpha, "cust-adapter-#{n}")
    {:ok, _pid} = Ezagent.Kind.spawn(SocialwareSession, %{uri: session})
    :ok = Ezagent.WorkspaceRegistry.bind(session, Ezagent.Capability.workspace_of(session))
    {session, customer}
  end

  test "ensure_adapter/3 starts the adapter, registered by session URI" do
    {session, customer} = setup_session()

    assert {:ok, pid} = SocialwareCS.ensure_adapter(session, customer)
    assert is_pid(pid) and Process.alive?(pid)

    # Discoverable via the plugin's AdapterRegistry, keyed by URI string.
    assert [{^pid, _}] =
             Registry.lookup(
               EzagentPluginAutoservice.AdapterRegistry,
               URI.to_string(session)
             )
  end

  test "ensure_adapter/3 is idempotent — second call returns the same pid" do
    {session, customer} = setup_session()

    assert {:ok, pid1} = SocialwareCS.ensure_adapter(session, customer)
    assert {:ok, pid2} = SocialwareCS.ensure_adapter(session, customer)
    assert pid1 == pid2
    assert Process.alive?(pid1)
  end
end
