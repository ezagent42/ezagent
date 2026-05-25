defmodule Ezagent.UI.UriOptionsTest do
  @moduledoc """
  V1 UI PR-1 (SPEC §1.3, §1.6) — `Ezagent.UI.UriOptions` tests.

  Includes the tenant-isolation invariants (SPEC §4 items 13-14): a
  non-system caller may only see its OWN workspace's URIs; a system
  member sees any workspace. These are the gate for the option-build
  read path, which sits OUTSIDE dispatch step 5.6.

  `KindRegistry` is a globally-named stdlib `Registry`. Each test
  registers its URIs via short-lived holder processes (registration is
  per-process; the process must stay alive for the URI to appear in
  `list_all/0`). Helper-registered URIs are namespaced with a unique
  integer so concurrent/other tests can't collide — `async: false`
  because `KindRegistry` is shared global state.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.UI.UriOptions

  # --- registration helpers --------------------------------------------------

  setup do
    {:ok, uniq: System.unique_integer([:positive])}
  end

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

  # --- entities/2 ------------------------------------------------------------

  describe "entities/2 — same-workspace caller" do
    test "lists entity URIs in the caller's own workspace", %{uniq: u} do
      ws = "ws_a_#{u}"
      caller = "entity://user/#{ws}/admin_#{u}"
      agent = "entity://agent/#{ws}/cc_demo_#{u}"
      user = "entity://user/#{ws}/alice_#{u}"
      :ok = register(caller)
      :ok = register(agent)
      :ok = register(user)

      opts = UriOptions.entities(caller, "workspace://#{ws}")
      uris = Enum.map(opts, & &1.uri)

      assert agent in uris
      assert user in uris
      assert Enum.all?(opts, &(&1.kind == :entity))
    end

    test "does not include session URIs", %{uniq: u} do
      ws = "ws_b_#{u}"
      caller = "entity://user/#{ws}/admin_#{u}"
      session = "session://default/#{ws}/main_#{u}"
      :ok = register(caller)
      :ok = register(session)

      opts = UriOptions.entities(caller, "workspace://#{ws}")
      refute session in Enum.map(opts, & &1.uri)
    end

    test "parses agent flavor from the name prefix", %{uniq: u} do
      ws = "ws_c_#{u}"
      caller = "entity://user/#{ws}/admin_#{u}"
      agent = "entity://agent/#{ws}/cc_xyz_#{u}"
      :ok = register(caller)
      :ok = register(agent)

      opts = UriOptions.entities(caller, "workspace://#{ws}")
      found = Enum.find(opts, &(&1.uri == agent))
      assert found.flavor == "cc"
    end
  end

  # --- tenant isolation (SPEC §4 item 13) ------------------------------------

  describe "tenant isolation — entities/2" do
    test "a non-system caller asking for ANOTHER workspace gets []", %{uniq: u} do
      caller_ws = "tenant_self_#{u}"
      other_ws = "tenant_other_#{u}"
      caller = "entity://user/#{caller_ws}/admin_#{u}"
      other_agent = "entity://agent/#{other_ws}/cc_demo_#{u}"
      :ok = register(caller)
      :ok = register(other_agent)

      # The caller is NOT a system member and other_ws is not its own.
      assert UriOptions.entities(caller, "workspace://#{other_ws}") == []
    end

    test "a system member sees ANY workspace's entities", %{uniq: u} do
      other_ws = "tenant_sys_other_#{u}"
      # A caller whose workspace segment is `system` → system member.
      sys_caller = "entity://user/system/admin_#{u}"
      other_agent = "entity://agent/#{other_ws}/cc_demo_#{u}"
      :ok = register(sys_caller)
      :ok = register(other_agent)

      opts = UriOptions.entities(sys_caller, "workspace://#{other_ws}")
      assert other_agent in Enum.map(opts, & &1.uri)
    end

    test "a non-system caller asking for its OWN workspace still works", %{uniq: u} do
      ws = "tenant_own_#{u}"
      caller = "entity://user/#{ws}/admin_#{u}"
      agent = "entity://agent/#{ws}/cc_demo_#{u}"
      :ok = register(caller)
      :ok = register(agent)

      opts = UriOptions.entities(caller, "workspace://#{ws}")
      assert agent in Enum.map(opts, & &1.uri)
    end

    test "a malformed caller URI yields [] (never leaks, never crashes)" do
      assert UriOptions.entities("not-a-uri", "workspace://team-alpha") == []
      assert UriOptions.entities(nil, "workspace://team-alpha") == []
    end
  end

  # --- sessions/2 ------------------------------------------------------------

  describe "sessions/2" do
    test "lists only session URIs in the caller's workspace", %{uniq: u} do
      ws = "ws_sess_#{u}"
      caller = "entity://user/#{ws}/admin_#{u}"
      session = "session://default/#{ws}/main_#{u}"
      agent = "entity://agent/#{ws}/cc_demo_#{u}"
      :ok = register(caller)
      :ok = register(session)
      :ok = register(agent)

      opts = UriOptions.sessions(caller, "workspace://#{ws}")
      uris = Enum.map(opts, & &1.uri)
      assert session in uris
      refute agent in uris
    end

    test "non-system caller cannot see another workspace's sessions", %{uniq: u} do
      caller_ws = "ws_sess_self_#{u}"
      other_ws = "ws_sess_other_#{u}"
      caller = "entity://user/#{caller_ws}/admin_#{u}"
      session = "session://default/#{other_ws}/main_#{u}"
      :ok = register(caller)
      :ok = register(session)

      assert UriOptions.sessions(caller, "workspace://#{other_ws}") == []
    end
  end

  # --- entities_and_sessions/2 ----------------------------------------------

  describe "entities_and_sessions/2" do
    test "unions entities + sessions in the caller's workspace", %{uniq: u} do
      ws = "ws_both_#{u}"
      caller = "entity://user/#{ws}/admin_#{u}"
      agent = "entity://agent/#{ws}/cc_demo_#{u}"
      session = "session://default/#{ws}/main_#{u}"
      :ok = register(caller)
      :ok = register(agent)
      :ok = register(session)

      uris = caller |> UriOptions.entities_and_sessions("workspace://#{ws}") |> Enum.map(& &1.uri)
      assert agent in uris
      assert session in uris
    end
  end

  # --- valid_for?/4 (SPEC §1.6) ---------------------------------------------

  describe "valid_for?/4 — the shared validator" do
    test "true for a well-formed in-workspace entity URI", %{uniq: u} do
      ws = "ws_vf_#{u}"
      caller = "entity://user/#{ws}/admin_#{u}"
      agent = "entity://agent/#{ws}/cc_demo_#{u}"
      :ok = register(caller)
      :ok = register(agent)

      assert UriOptions.valid_for?(caller, "workspace://#{ws}", agent, [:entity])
    end

    test "false for an out-of-workspace URI (tampered hidden input)", %{uniq: u} do
      caller_ws = "ws_vf_self_#{u}"
      other_ws = "ws_vf_other_#{u}"
      caller = "entity://user/#{caller_ws}/admin_#{u}"
      :ok = register(caller)

      tampered = "entity://agent/#{other_ws}/cc_evil_#{u}"
      refute UriOptions.valid_for?(caller, "workspace://#{caller_ws}", tampered, [:entity])
    end

    test "false when the scheme is not in kinds", %{uniq: u} do
      ws = "ws_vf_scheme_#{u}"
      caller = "entity://user/#{ws}/admin_#{u}"
      session = "session://default/#{ws}/main_#{u}"
      :ok = register(caller)
      :ok = register(session)

      # A session URI submitted into an entity-only field is rejected.
      refute UriOptions.valid_for?(caller, "workspace://#{ws}", session, [:entity])
      # …but accepted when sessions are an allowed kind.
      assert UriOptions.valid_for?(caller, "workspace://#{ws}", session, [:entity, :session])
    end

    test "false for a malformed / non-URI submission", %{uniq: u} do
      ws = "ws_vf_bad_#{u}"
      caller = "entity://user/#{ws}/admin_#{u}"
      :ok = register(caller)

      refute UriOptions.valid_for?(caller, "workspace://#{ws}", "garbage", [:entity])
      refute UriOptions.valid_for?(caller, "workspace://#{ws}", "", [:entity])
      refute UriOptions.valid_for?(caller, "workspace://#{ws}", nil, [:entity])
    end

    test "a system member may validate URIs in any workspace", %{uniq: u} do
      other_ws = "ws_vf_sys_#{u}"
      sys_caller = "entity://user/system/admin_#{u}"
      agent = "entity://agent/#{other_ws}/cc_demo_#{u}"
      :ok = register(sys_caller)
      :ok = register(agent)

      assert UriOptions.valid_for?(sys_caller, "workspace://#{other_ws}", agent, [:entity])
    end

    test "a non-system caller cannot validate a URI in a workspace not their own", %{uniq: u} do
      caller_ws = "ws_vf_deny_#{u}"
      other_ws = "ws_vf_deny_other_#{u}"
      caller = "entity://user/#{caller_ws}/admin_#{u}"
      agent = "entity://agent/#{other_ws}/cc_demo_#{u}"
      :ok = register(caller)
      :ok = register(agent)

      # Even a well-formed live URI in other_ws is rejected — the
      # caller has no authority over other_ws.
      refute UriOptions.valid_for?(caller, "workspace://#{other_ws}", agent, [:entity])
    end
  end
end
