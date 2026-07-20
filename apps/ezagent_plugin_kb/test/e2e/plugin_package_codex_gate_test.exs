defmodule EzagentPluginKb.E2E.PluginPackageCodexGateTest do
  @moduledoc """
  Plugin-package lifecycle gate (Q1-C completion gate).

  Sibling of `socialware_p10_codex_gate_test.exs`. In-process: package
  install/unload go through the real `Ezagent.PluginPackage.install/1` +
  `unload/1` (the same API `mix ezagent.plugin.install` delegates to), the
  behavior round-trip goes through `Ezagent.Invocation.dispatch/1`, and the
  island asset fetch goes through the real `EzagentWeb.Endpoint` plug stack
  via `Phoenix.ConnTest`. No hand-inserted registry stubs — every assertion
  observes state through a PUBLIC entrypoint.

  ## Lifecycle asserted

  1. BUILD a test plugin package (manifest + tiny Behavior + tiny island
     asset + seed recipe) in a temp dir.
  2. INSTALL (hot-load, no restart): Behavior/Kind reachable (dispatch
     echo round-trips) + island asset served (HTTP 200) + seed recipe in
     ConfigStore.
  3. UNLOAD: Behavior/Kind gone (new dispatch fails cleanly with
     `{:error, {:unknown_action, _}}`), island asset 404s, seed recipe
     retired.
  4. SWAP v2: install the v2 package (changed behavior) → the round-trip
     now reflects v2.

  The invariant FAILS if any piece (manifest / hot-load / assets /
  unload / swap) is missing or broken.
  """

  use EzagentCore.DataCase, async: false

  import Phoenix.ConnTest

  alias Ezagent.{Invocation, PluginPackage, Workspace}
  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Entity.Agent

  @endpoint EzagentWeb.Endpoint

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_world)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_kb)
    {:ok, _} = Application.ensure_all_started(:ezagent_web)

    tmp_dir = Path.join(System.tmp_dir!(), "plugin-pkg-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      # Best-effort: unload anything left installed + clean the temp dir.
      _ = PluginPackage.unload("pkg-test")
      File.rm_rf!(tmp_dir)
    end)

    {:ok, %{tmp_dir: tmp_dir}}
  end

  @tag :e2e
  @tag :integration
  test "install -> use -> unload -> swap reflects the full plugin-package lifecycle", %{
    tmp_dir: tmp_dir
  } do
    ws = "pkg-e2e-#{uniq()}"
    workspace_uri = Ezagent.URI.workspace(ws)
    agent_uri = Ezagent.URI.agent(ws, "echo-bot-#{uniq()}")

    {:ok, _} = Workspace.create(ws, %{})
    :ok = spawn_agent(agent_uri, workspace_uri)
    on_exit(fn -> cleanup_agent(agent_uri) end)

    # --- 1. BUILD + INSTALL v1 (hot-load, no restart) -------------------
    v1_dir = EzagentPluginPkgTest.Builder.build!(:v1, tmp_dir)

    assert {:ok, %{slug: "pkg-test", app: :ezagent_pkg_test}} =
             PluginPackage.install(v1_dir)

    # Behavior reachable: the registered EchoBehavior v1 resolves.
    assert {:ok, behavior} = Ezagent.BehaviorRegistry.lookup(Agent, :echo_pkg)
    assert behavior == EzagentPluginPkgTest.EchoBehavior

    # --- 2. USE (round-trip through the Behavior via dispatch) ----------
    assert {:ok, %{echo: text, version: version}} =
             dispatch_echo(agent_uri, "hello from v1")

    assert text == "hello from v1"
    assert version == "v1"

    # Island asset served (real HTTP fetch through the endpoint).
    assert {200, body} = fetch_asset("pkg-test", "main.js")
    assert body =~ "plugin-package E2E island bundle v1"

    # Seed recipe landed in ConfigStore (read-through lookup).
    assert {:ok, _recipe_map} = RecipeRegistry.lookup("pkg-echo-recipe")

    # --- 3. UNLOAD -------------------------------------------------------
    assert :ok = PluginPackage.unload("pkg-test")

    # Behavior gone: registry miss → dispatch fails cleanly (NOT a crash).
    assert :error = Ezagent.BehaviorRegistry.lookup(Agent, :echo_pkg)

    assert {:error, {:unknown_action, :echo_pkg}} =
             dispatch_echo(agent_uri, "should not reach")

    # Island asset 404s (unregistered from PluginAssetRegistry).
    assert {404, _} = fetch_asset("pkg-test", "main.js")

    # Seed recipe retired from ConfigStore.
    assert :error = RecipeRegistry.lookup("pkg-echo-recipe")

    # --- 4. SWAP to v2 (unload-v1 + install-v2, BEAM hot-code-reload) ----
    # Re-install v1 so the swap has a live v1 to unload atomically.
    assert {:ok, _} = PluginPackage.install(v1_dir)

    v2_dir = EzagentPluginPkgTest.Builder.build!(:v2, tmp_dir)

    assert {:ok, %{slug: "pkg-test"}} = PluginPackage.swap("pkg-test", v2_dir)

    # The swapped-in v2 Behavior resolves now.
    assert {:ok, behavior_v2} = Ezagent.BehaviorRegistry.lookup(Agent, :echo_pkg)
    assert behavior_v2 == EzagentPluginPkgTestV2.EchoBehavior

    # Round-trip reflects v2.
    assert {:ok, %{echo: text2, version: version2}} =
             dispatch_echo(agent_uri, "hello from v2")

    assert text2 == "hello from v2"
    assert version2 == "v2"

    # Island asset now serves the v2 bundle.
    assert {200, body2} = fetch_asset("pkg-test", "main.js")
    assert body2 =~ "plugin-package E2E island bundle v2"

    # Final cleanup: unload v2.
    assert :ok = PluginPackage.unload("pkg-test")
  end

  # --- helpers --------------------------------------------------------------

  defp dispatch_echo(agent_uri, text) do
    target = Ezagent.URI.with_action(agent_uri, :echo, :echo_pkg)
    admin = Ezagent.URI.user(:system, :admin)

    caps =
      case Ezagent.BehaviorRegistry.lookup(Agent, :echo_pkg) do
        {:ok, _behavior} ->
          MapSet.new([Ezagent.Test.CapHelper.signed_action_cap!(target, admin)])

        :error ->
          MapSet.new()
      end

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{text: text},
      ctx: %{
        caller: admin,
        caps: caps,
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp fetch_asset(slug, route) do
    conn = get(build_conn(), "/plugin-assets/#{slug}/#{route}")
    {conn.status, conn.resp_body}
  end

  defp spawn_agent(uri, workspace_uri) do
    case Ezagent.Kind.spawn(Agent, %{uri: uri}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
    |> case do
      :ok -> Ezagent.WorkspaceRegistry.bind(uri, workspace_uri)
      other -> other
    end
  end

  defp cleanup_agent(agent_uri) do
    case Ezagent.KindRegistry.lookup(agent_uri) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid),
          do: DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.AgentSupervisor, pid)

      :error ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp uniq, do: System.unique_integer([:positive])
end
