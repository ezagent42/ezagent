defmodule Ezagent.UI.UriOptionsTest do
  @moduledoc """
  V1 UI PR-1 (SPEC §1.3, §1.6) — `Ezagent.UI.UriOptions` tests.

  Read-plane PR-4 rework: the option-build path now enumerates through
  the caller-authorizing chokepoints (`WorkspaceReads` / `UserReads`),
  so these tests seed REAL fixtures (workspace + declared membership +
  agent snapshots/lineage + live sessions) instead of merely registering
  URIs in the global `KindRegistry`. The discriminating invariant (F1):
  an ordinary workspace member does NOT receive labels/URIs for private
  sessions/agents they have no relationship to (the command-palette
  leak). `valid_for?/4` (SPEC §1.6) behavior is unchanged and its tests
  are preserved.

  `async: false` — the fixtures touch shared global state (KindRegistry,
  the workspace store, AgentLineage).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.UI.UriOptions

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    Ezagent.UriQuery.init()
    previous = :ets.lookup(Ezagent.UriQuery.table(), :flavor)

    on_exit(fn ->
      :ets.delete(Ezagent.UriQuery.table(), :flavor)

      for entry <- previous do
        :ets.insert(Ezagent.UriQuery.table(), entry)
      end
    end)

    :ok
  end

  # --- fixtures ---------------------------------------------------------------

  # A workspace + a declared-member caller (provisioned user + member row).
  defp seed_workspace(prefix) do
    ws_name = "#{prefix}-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Ezagent.Workspace.create(ws_name, %{})
    ws = Ezagent.URI.workspace(ws_name)
    caller = Ezagent.URI.user(ws_name, "member")
    {:ok, _row} = Ezagent.Users.create(caller, nil, [])
    {:ok, _} = Ezagent.Workspace.Store.update_members(ws_name, [caller])
    {ws_name, ws, caller}
  end

  # An agent that `owner_uri` OWNS (lineage-backed data-owner rule) with a
  # durable snapshot row (the chokepoint's base listing is snapshot-sourced).
  defp seed_agent(ws_name, name, owner_uri) do
    agent = Ezagent.URI.agent(ws_name, name)
    :ok = Ezagent.AgentLineage.record(agent, owner_uri)
    {:ok, _snap} = Ezagent.SnapshotStore.write(agent, %{}, kind_type: :agent)

    on_exit(fn -> Ezagent.AgentLineage.forget(agent) end)

    agent
  end

  # A LIVE session owned by `owner_uri`, bound to the workspace.
  defp seed_session(ws_name, name, owner_uri) do
    session = Ezagent.URI.session(ws_name, "default", name)
    kind = Module.concat([Ezagent.Entity, Session])

    {:ok, _pid} =
      Ezagent.Kind.spawn(kind, %{
        uri: session,
        behaviors: apply(kind, :behaviors, []),
        owner_uri: owner_uri
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session, Ezagent.URI.workspace(ws_name))
    wait_until(fn -> Ezagent.ReadyGate.status(session) == :ready end)

    session
  end

  # --- entities/2 (chokepoint-backed) ------------------------------------------

  describe "entities/2 — workspace member" do
    test "lists the caller's own agents, the shared roster, and the user roster" do
      {ws_name, ws, caller} = seed_workspace("opts-ents")
      other = Ezagent.URI.user(ws_name, "other")
      {:ok, _row} = Ezagent.Users.create(other, nil, [])

      my_agent = seed_agent(ws_name, "mine", caller)
      shared_agent = seed_agent(ws_name, "shared", other)
      {:ok, _} = Ezagent.Workspace.Store.update_members(ws_name, [caller, shared_agent])

      opts = UriOptions.entities(caller, ws)
      uris = Enum.map(opts, & &1.uri)

      assert URI.to_string(my_agent) in uris
      assert URI.to_string(shared_agent) in uris
      assert URI.to_string(caller) in uris
      assert URI.to_string(other) in uris
      assert Enum.all?(opts, &(&1.kind == :entity))
    end

    test "reads agent flavor from UriQuery" do
      {ws_name, ws, caller} = seed_workspace("opts-flavor")
      agent = seed_agent(ws_name, "flavored", caller)
      put_flavors(%{URI.to_string(agent) => "cc"})

      found = Enum.find(UriOptions.entities(caller, ws), &(&1.uri == URI.to_string(agent)))
      assert found.flavor == "cc"
    end
  end

  # --- tenant isolation ---------------------------------------------------------

  describe "tenant isolation — entities/2 and sessions/2" do
    test "a non-member caller asking for ANOTHER workspace gets []" do
      {_ws1_name, _ws1, caller} = seed_workspace("opts-iso-self")
      {ws2_name, ws2, _other} = seed_workspace("opts-iso-other")
      _agent_in_ws2 = seed_agent(ws2_name, "theirs", Ezagent.URI.user(ws2_name, "member"))

      assert UriOptions.entities(caller, ws2) == []
      assert UriOptions.sessions(caller, ws2) == []
    end

    test "a promoted system operator sees a workspace's USER roster (but not its shared agent roster)" do
      {ws_name, ws, _member} = seed_workspace("opts-iso-sys")

      operator =
        Ezagent.URI.new!("entity://system/user/op-#{System.unique_integer([:positive])}")

      agent = seed_agent(ws_name, "rostered", Ezagent.URI.user(ws_name, "member"))
      {:ok, _} = Ezagent.Workspace.Store.update_members(ws_name, [agent])

      uris = UriOptions.entities(operator, ws) |> Enum.map(& &1.uri)

      # Operator authority admits the workspace + the user roster…
      assert uris != []
      # …but the shared AGENT roster is members-only (F2-consistent): the
      # operator is not a declared member and owns/manages nothing here.
      refute URI.to_string(agent) in uris
    end

    test "a malformed caller URI yields [] (never leaks, never crashes)" do
      assert UriOptions.entities("not-a-uri", "workspace://team-alpha") == []
      assert UriOptions.entities(nil, "workspace://team-alpha") == []
    end
  end

  # --- sessions/2 ---------------------------------------------------------------

  describe "sessions/2" do
    test "lists the caller's own/member sessions, not another member's private session" do
      {ws_name, ws, caller} = seed_workspace("opts-sess")
      other = Ezagent.URI.user(ws_name, "other")
      {:ok, _row} = Ezagent.Users.create(other, nil, [])

      my_session = seed_session(ws_name, "mine", caller)
      private_session = seed_session(ws_name, "private", other)

      uris = UriOptions.sessions(caller, ws) |> Enum.map(& &1.uri)

      assert URI.to_string(my_session) in uris
      refute URI.to_string(private_session) in uris
    end
  end

  # --- entities_and_sessions/2 ---------------------------------------------------

  describe "entities_and_sessions/2" do
    test "unions caller-visible entities + sessions" do
      {ws_name, ws, caller} = seed_workspace("opts-both")
      agent = seed_agent(ws_name, "agent", caller)
      session = seed_session(ws_name, "session", caller)

      uris = caller |> UriOptions.entities_and_sessions(ws) |> Enum.map(& &1.uri)
      assert URI.to_string(agent) in uris
      assert URI.to_string(session) in uris
    end
  end

  # --- F1 (read-plane PR-4 rework acceptance) ------------------------------------

  describe "F1 — the command-palette private-data leak stays closed" do
    test "an ordinary member does NOT receive labels/URIs for private sessions/agents they have no relationship to" do
      {ws_name, ws, caller} = seed_workspace("opts-f1")
      other = Ezagent.URI.user(ws_name, "other")
      {:ok, _row} = Ezagent.Users.create(other, nil, [])

      # The other member's PRIVATE assets: owned by them, NOT declared to the
      # workspace, NOT public — pre-rework the global-registry enumeration
      # handed these to ANY caller who could name the workspace.
      private_agent = seed_agent(ws_name, "private-agent", other)
      private_session = seed_session(ws_name, "private-session", other)

      # The caller's own + the shared roster stay visible.
      my_agent = seed_agent(ws_name, "my-agent", caller)
      shared_agent = seed_agent(ws_name, "shared-agent", other)
      {:ok, _} = Ezagent.Workspace.Store.update_members(ws_name, [caller, shared_agent])
      my_session = seed_session(ws_name, "my-session", caller)

      opts = UriOptions.entities_and_sessions(caller, ws)
      uris = Enum.map(opts, & &1.uri)

      refute URI.to_string(private_agent) in uris
      refute URI.to_string(private_session) in uris
      assert URI.to_string(my_agent) in uris
      assert URI.to_string(shared_agent) in uris
      assert URI.to_string(my_session) in uris
    end
  end

  # --- valid_for?/4 (SPEC §1.6) — UNCHANGED behavior -----------------------------

  # Register `uri` in KindRegistry from a holder process that stays
  # alive for the test's duration (registration is per-process).
  defp register(uri) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        :ok = Ezagent.KindRegistry.put_new(uri)
        send(parent, {:registered, uri})

        receive do
          :stop -> :ok
        end
      end)

    receive do
      {:registered, ^uri} -> :ok
    after
      1000 -> flunk("timed out registering #{uri}")
    end

    on_exit(fn ->
      send(pid, :stop)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1000 -> :ok
      end
    end)

    :ok
  end

  describe "valid_for?/4 — the shared validator" do
    test "true for a well-formed in-workspace entity URI" do
      u = System.unique_integer([:positive])
      ws = "ws_vf_#{u}"
      caller = "entity://#{ws}/user/admin_#{u}"
      agent = "entity://#{ws}/agent/cc_demo_#{u}"
      :ok = register(caller)
      :ok = register(agent)

      assert UriOptions.valid_for?(caller, "workspace://#{ws}", agent, [:entity])
    end

    test "false for an out-of-workspace URI (tampered hidden input)" do
      u = System.unique_integer([:positive])
      caller_ws = "ws_vf_self_#{u}"
      other_ws = "ws_vf_other_#{u}"
      caller = "entity://#{caller_ws}/user/admin_#{u}"
      :ok = register(caller)

      tampered = "entity://#{other_ws}/agent/cc_evil_#{u}"
      refute UriOptions.valid_for?(caller, "workspace://#{caller_ws}", tampered, [:entity])
    end

    test "false when the scheme is not in kinds" do
      u = System.unique_integer([:positive])
      ws = "ws_vf_scheme_#{u}"
      caller = "entity://#{ws}/user/admin_#{u}"
      session = "session://#{ws}/default/main_#{u}"
      :ok = register(caller)
      :ok = register(session)

      # A session URI submitted into an entity-only field is rejected.
      refute UriOptions.valid_for?(caller, "workspace://#{ws}", session, [:entity])
      # …but accepted when sessions are an allowed kind.
      assert UriOptions.valid_for?(caller, "workspace://#{ws}", session, [:entity, :session])
    end

    test "false for a malformed / non-URI submission" do
      u = System.unique_integer([:positive])
      ws = "ws_vf_bad_#{u}"
      caller = "entity://#{ws}/user/admin_#{u}"
      :ok = register(caller)

      refute UriOptions.valid_for?(caller, "workspace://#{ws}", "garbage", [:entity])
      refute UriOptions.valid_for?(caller, "workspace://#{ws}", "", [:entity])
      refute UriOptions.valid_for?(caller, "workspace://#{ws}", nil, [:entity])
    end

    test "a system member may validate URIs in any workspace" do
      u = System.unique_integer([:positive])
      other_ws = "ws_vf_sys_#{u}"
      sys_caller = "entity://system/user/admin_#{u}"
      agent = "entity://#{other_ws}/agent/cc_demo_#{u}"
      :ok = register(sys_caller)
      :ok = register(agent)

      assert UriOptions.valid_for?(sys_caller, "workspace://#{other_ws}", agent, [:entity])
    end

    test "a non-system caller cannot validate a URI in a workspace not their own" do
      u = System.unique_integer([:positive])
      caller_ws = "ws_vf_deny_#{u}"
      other_ws = "ws_vf_deny_other_#{u}"
      caller = "entity://#{caller_ws}/user/admin_#{u}"
      agent = "entity://#{other_ws}/agent/cc_demo_#{u}"
      :ok = register(caller)
      :ok = register(agent)

      # Even a well-formed live URI in other_ws is rejected — the
      # caller has no authority over other_ws.
      refute UriOptions.valid_for?(caller, "workspace://#{other_ws}", agent, [:entity])
    end
  end

  defp put_flavors(flavors) when is_map(flavors) do
    by_uri = Map.new(flavors)

    :ets.insert(Ezagent.UriQuery.table(), {:flavor, &resolve_test_flavor(&1, by_uri)})
  end

  defp resolve_test_flavor(%URI{} = uri, by_uri) do
    case Map.fetch(by_uri, URI.to_string(uri)) do
      {:ok, flavor} -> {:ok, flavor}
      :error -> :none
    end
  end

  defp wait_until(fun, retries \\ 100)

  defp wait_until(fun, retries) when retries > 0 do
    case fun.() do
      true ->
        true

      _ ->
        Process.sleep(10)
        wait_until(fun, retries - 1)
    end
  end

  defp wait_until(fun, _retries), do: fun.() == true
end
