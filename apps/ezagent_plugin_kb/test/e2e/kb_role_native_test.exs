defmodule EzagentPluginKb.E2E.KbRoleNativeTest do
  @moduledoc """
  KB acceptance — create a `kb` agent (role × native) via the RF-5a role-create
  path, and prove the load-bearing properties (SPEC §8), mirroring the
  kanban-as-role e2e harness:

    * **§8.1 round-trip** — create kb×native → `kb.ingest` a source doc →
      `kb.query` returns the chunk with provenance.
    * **§8.2 persistence across restart** — ingest → `Kind.terminate` the agent →
      dispatch re-spawns it (rehydrate from snapshot → `activate/2` re-opens the
      sqlite file) → query STILL retrievable (no in-memory dependency).
    * **§8.3 cap separation** — a caller holding ONLY `kb.query` is REFUSED
      `kb.ingest` (`{:error, :unauthorized}`); the same caller CAN query
      (positive control pins the denial to the cap, not a generic failure).
    * **§8.4 source authority** — a foreign-workspace `kb-source` URI is
      rejected (R-3); a symlinked source escaping the backend is rejected.
    * **§8.5 store-path confinement** — the store URI is derived from the
      kb-agent's OWN identity; no caller arg can redirect it. The corpus lives
      under the `kb-store` backend, nowhere else.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.{AgentFlavorRegistry, Agent.RecipeRegistry}
  alias EzagentPluginKb.Application, as: KbApp

  @flavor "kb-native-test"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    # The kb plugin's resource types must be registered for FsResolver to
    # resolve kb-store / kb-source (Plugin.boot does this in prod; the test
    # registers idempotently so it runs in isolation).
    case Ezagent.Resource.FsResolver.Registry.register_all(KbApp.resource_types()) do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
      {:error, {:duplicate_type, _}} -> :ok
      _ -> :ok
    end

    ws_name = "kb-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: @flavor,
        kind: Ezagent.Entity.Agent,
        template_class: nil,
        cap_policy: &cap_policy/1
      })

    {:ok, _} = RecipeRegistry.seed_role_if_absent(KbApp.kb_recipe())

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  defp cap_policy(requested_caps) do
    allowed =
      requested_caps
      |> Enum.map(fn c -> {Map.get(c, :behavior), Map.get(c, :action)} end)
      |> MapSet.new()

    fn needed ->
      MapSet.member?(allowed, {Map.get(needed, :behavior), Map.get(needed, :action)})
    end
  end

  @tag :integration
  test "round-trip + persistence-across-restart (SPEC §8.1, §8.2)",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      name = "kb-#{System.unique_integer([:positive])}"
      {:ok, agent_uri} = create_kb_agent(workspace_uri, ws_name, name, admin_ctx)

      # Place a real source document under the kb-source backend for this ws.
      source_name = "doc-#{System.unique_integer([:positive])}"
      source_uri = write_source(ws_name, source_name, "elixir processes are isolated and cheap")

      # --- §8.1 round-trip ---
      assert {:ok, %{chunks: n}} =
               dispatch(agent_uri, :ingest, %{source_uri: source_uri}, admin_ctx)

      assert n >= 1

      assert {:ok, %{hits: [hit | _]}} =
               dispatch(agent_uri, :query, %{query: "isolated processes", k: 5}, admin_ctx)

      assert hit.text =~ "isolated"
      assert hit.source_uri == source_uri
      assert is_integer(hit.chunk_id)
      assert is_float(hit.score)

      # --- §8.2 persistence across restart ---
      # Capture the live pid, then terminate the agent. Whether the supervisor
      # restarts it (a permanent child) OR it stays cold until re-dispatched,
      # the NEXT live incarnation runs activate/2 afresh — re-opening the sqlite
      # file from disk with NO in-memory index carried over. The property under
      # test is "the corpus survives a new process incarnation".
      {:ok, old_pid} = Ezagent.KindRegistry.lookup(agent_uri)
      :ok = Ezagent.Kind.terminate(agent_uri)

      # Bring up a fresh incarnation (rehydrate if cold; no-op if the supervisor
      # already restarted it) and confirm it is a NEW process (activate/2 ran).
      assert {:ok, _} = Ezagent.SpawnRegistry.ensure_live(agent_uri)
      assert {:ok, new_pid} = wait_until_live(agent_uri, old_pid)
      assert new_pid != old_pid, "a fresh incarnation must run activate/2 (cold-load re-open)"

      assert {:ok, %{hits: [hit2 | _]}} =
               dispatch(agent_uri, :query, %{query: "isolated processes", k: 5}, admin_ctx),
             "corpus must survive restart (sqlite file + activate/2 re-open, no in-memory index)"

      assert hit2.text =~ "isolated"
      assert hit2.source_uri == source_uri
    end)
  end

  @tag :integration
  test "cap separation: query-only caller refused ingest (SPEC §8.3)",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      name = "kb-#{System.unique_integer([:positive])}"
      {:ok, agent_uri} = create_kb_agent(workspace_uri, ws_name, name, admin_ctx)

      source_name = "doc-#{System.unique_integer([:positive])}"
      source_uri = write_source(ws_name, source_name, "alpha beta gamma delta corpus")
      # Seed via admin so there is something to query.
      assert {:ok, _} = dispatch(agent_uri, :ingest, %{source_uri: source_uri}, admin_ctx)

      # A caller holding ONLY the kb.query cap (kind axis :agent — the host is
      # Entity.Agent; a :kb-kind cap would be a false-pass trap).
      reader = URI.new!("entity://#{ws_name}/user/reader")
      :ok = spawn_test_user(reader)

      query_only = %{
        caller: reader,
        caps: MapSet.new([Ezagent.Capability.cap(:agent, Ezagent.ActionSet.Kb, :query)])
      }

      # Positive control: the cap authorizes query.
      assert {:ok, %{hits: _}} =
               dispatch(agent_uri, :query, %{query: "alpha beta", k: 5}, query_only)

      # The same caller is REFUSED ingest — fail-closed cap separation.
      assert {:error, :missing_cap} =
               dispatch(
                 agent_uri,
                 :ingest,
                 %{source_uri: source_uri},
                 query_only
               ),
             "a query-only caller must NOT be able to mutate the corpus (kb.query != kb.ingest)"

      # A caller with NEITHER cap is refused BOTH.
      nobody = URI.new!("entity://#{ws_name}/user/nobody")
      :ok = spawn_test_user(nobody)
      none = %{caller: nobody, caps: MapSet.new([])}

      assert {:error, :missing_cap} =
               dispatch(agent_uri, :query, %{query: "alpha", k: 5}, none)

      assert {:error, :missing_cap} =
               dispatch(agent_uri, :ingest, %{source_uri: source_uri}, none)
    end)
  end

  @tag :integration
  test "source authority + symlink rejected (SPEC §8.4)",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      name = "kb-#{System.unique_integer([:positive])}"
      {:ok, agent_uri} = create_kb_agent(workspace_uri, ws_name, name, admin_ctx)

      # A foreign-workspace source URI: the agent's scope is its OWN workspace,
      # so resolving a victim-ws kb-source fails R-3 (foreign_workspace).
      foreign = "resource://victim-ws/kb-source/secret"

      assert {:error, _} =
               dispatch(agent_uri, :ingest, %{source_uri: foreign}, admin_ctx),
             "a foreign-workspace source URI must be rejected (R-3)"

      # A symlinked source escaping the backend root is rejected (§6.2 realpath).
      backend_dir = Path.join([Ezagent.Home.path("kb-sources"), ws_name])
      File.mkdir_p!(backend_dir)

      outside =
        Path.join(System.tmp_dir!(), "kb-escape-#{System.unique_integer([:positive])}.txt")

      File.write!(outside, "secret outside the backend root")
      link_name = "link-#{System.unique_integer([:positive])}"
      link_path = Path.join(backend_dir, link_name)
      :ok = File.ln_s(outside, link_path)
      on_exit(fn -> File.rm_rf(outside) end)

      link_uri = "resource://#{ws_name}/kb-source/#{link_name}"

      assert {:error, {:symlink_rejected, _}} =
               dispatch(agent_uri, :ingest, %{source_uri: link_uri}, admin_ctx),
             "a symlinked source escaping the backend must be rejected (§6.2)"
    end)
  end

  @tag :integration
  test "store-path confinement: corpus lives only under kb-store backend (SPEC §8.5)",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      name = "kb-#{System.unique_integer([:positive])}"
      {:ok, agent_uri} = create_kb_agent(workspace_uri, ws_name, name, admin_ctx)

      source_name = "doc-#{System.unique_integer([:positive])}"
      source_uri = write_source(ws_name, source_name, "confinement corpus content here")
      assert {:ok, _} = dispatch(agent_uri, :ingest, %{source_uri: source_uri}, admin_ctx)

      # The store file is at the identity-derived path; no caller arg redirects it.
      expected = Path.join([Ezagent.Home.path("kb-stores"), ws_name, name, "kb.sqlite"])
      assert File.exists?(expected), "the corpus sqlite file must be under the kb-store backend"

      # The store URI on the snapshot is identity-derived (never caller input).
      assert {:ok, slice} = Ezagent.Kind.read(agent_uri, :kb, spawn: :never)
      assert slice.store_uri == Ezagent.URI.resource(ws_name, "kb-store", name)
    end)
  end

  @tag :integration
  test "MCP tools (SPEC §8.7): kb_query / kb_ingest dispatch with caller caps",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      name = "kb-#{System.unique_integer([:positive])}"
      {:ok, agent_uri} = create_kb_agent(workspace_uri, ws_name, name, admin_ctx)

      source_name = "doc-#{System.unique_integer([:positive])}"
      _src = write_source(ws_name, source_name, "mcp retrieval over indexed documents works")
      source_uri = "resource://#{ws_name}/kb-source/#{source_name}"

      # An authenticated principal holding kb caps; SessionConfig reconstructs
      # these from the principal's identity slice.
      orch = URI.new!("entity://#{ws_name}/agent/orchestrator")

      caps =
        MapSet.new([
          Ezagent.Test.CapHelper.signed_cap!(agent_uri, orch, kb_cap(:query, workspace_uri)),
          Ezagent.Test.CapHelper.signed_cap!(agent_uri, orch, kb_cap(:ingest, workspace_uri))
        ])

      :ok = Ezagent.AgentFlavorAttributes.put(orch, "cc")
      {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: orch, initial_caps: caps})
      :ok = Ezagent.WorkspaceRegistry.bind(orch, workspace_uri)

      on_exit(fn ->
        Ezagent.Kind.terminate(orch)
        Ezagent.AgentFlavorAttributes.delete(orch)
      end)

      assert Enum.any?(Ezagent.IdentityCaps.load(orch), fn cap ->
               cap.behavior == Ezagent.ActionSet.Kb and cap.action == :ingest
             end)

      # kb_ingest MCP tool → dispatches kb.ingest into the named kb-agent.
      assert {:ok, %{chunks: _}} =
               Ezagent.Session.Config.execute(
                 "kb_ingest",
                 %{"kb_agent" => name, "source_uri" => source_uri},
                 orch,
                 workspace_uri
               )

      # kb_query MCP tool → dispatches kb.query, returns hits with provenance.
      assert {:ok, %{hits: [hit | _]}} =
               Ezagent.Session.Config.execute(
                 "kb_query",
                 %{"kb_agent" => name, "query" => "indexed documents", "k" => 5},
                 orch,
                 workspace_uri
               )

      assert hit.text =~ "indexed"

      # An orchestrator WITHOUT the kb.ingest cap is denied (fail-closed).
      read_only = URI.new!("entity://#{ws_name}/agent/read-only-orchestrator")
      :ok = Ezagent.AgentFlavorAttributes.put(read_only, "cc")

      read_only_cap =
        Ezagent.Test.CapHelper.signed_cap!(
          agent_uri,
          read_only,
          kb_cap(:query, workspace_uri)
        )

      {:ok, _pid} =
        Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
          uri: read_only,
          initial_caps: MapSet.new([read_only_cap])
        })

      :ok = Ezagent.WorkspaceRegistry.bind(read_only, workspace_uri)

      on_exit(fn ->
        Ezagent.Kind.terminate(read_only)
        Ezagent.AgentFlavorAttributes.delete(read_only)
      end)

      assert {:error, {:gate_failed, :operation_caps, :unauthorized}} =
               Ezagent.Session.Config.execute(
                 "kb_ingest",
                 %{"kb_agent" => name, "source_uri" => source_uri},
                 read_only,
                 workspace_uri
               ),
             "an orchestrator without kb.ingest must be denied (option-1 caps gate)"
    end)
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp kb_cap(action, workspace_uri) do
    %Ezagent.Capability{
      kind: :agent,
      behavior: Ezagent.ActionSet.Kb,
      action: action,
      instance: {:within_workspace, workspace_uri},
      workspace_uri: workspace_uri,
      granted_by: User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  defp create_kb_agent(workspace_uri, ws_name, name, admin_ctx) do
    assert {:ok, %{agent_uri: agent_uri}} =
             Workspace.create_agent(
               workspace_uri,
               %{flavor: @flavor, name: name, role: "kb", cwd: "", with_pty: false},
               admin_ctx
             )

    assert agent_uri == Ezagent.URI.agent(ws_name, name)
    assert {:ok, _pid} = Ezagent.KindRegistry.lookup(agent_uri)
    {:ok, agent_uri}
  end

  # Write a real source file under the kb-source backend for `ws_name`, return
  # the resource:// URI string.
  defp write_source(ws_name, source_name, content) do
    dir = Path.join([Ezagent.Home.path("kb-sources"), ws_name])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, source_name), content)
    "resource://#{ws_name}/kb-source/#{source_name}"
  end

  # Wait for the agent to be a live actor with a pid distinct from `old_pid`
  # (i.e. a genuinely fresh incarnation), polling briefly to absorb the async
  # terminate/restart window.
  defp wait_until_live(uri, old_pid, attempts \\ 50)
  defp wait_until_live(_uri, _old_pid, 0), do: {:error, :timeout}

  defp wait_until_live(uri, old_pid, attempts) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} when pid != old_pid ->
        {:ok, pid}

      _ ->
        _ = Ezagent.SpawnRegistry.ensure_live(uri)
        Process.sleep(20)
        wait_until_live(uri, old_pid, attempts - 1)
    end
  end

  defp dispatch(agent_uri, action, args, %{caller: caller, caps: caps}) do
    target = Ezagent.URI.with_action(agent_uri, :kb, action)
    caps = signed_dispatch_caps(target, caller, caps)

    cmd =
      Ezagent.Cmd.new(
        target,
        action,
        args,
        %{
          mode: :call,
          caller: caller,
          authenticated_principal: caller,
          caps: caps,
          reply: {:caller_inbox, self()}
        }
      )

    Ezagent.Router.dispatch(cmd)
  end

  defp signed_dispatch_caps(target, caller, caps) do
    cond do
      Ezagent.Identity.admin?(caller) ->
        MapSet.new([Ezagent.Test.CapHelper.signed_action_cap!(target, caller)])

      Enum.empty?(caps) ->
        MapSet.new()

      true ->
        caps
        |> Enum.map(&Ezagent.Test.CapHelper.signed_cap!(target, caller, &1))
        |> MapSet.new()
    end
  end

  defp spawn_test_user(%URI{} = user) do
    assert {:ok, _row} = Ezagent.Users.create(user, "test-password", [])
    assert :ok = Ezagent.Entity.spawn_principal(user)

    on_exit(fn -> Ezagent.Kind.terminate(user) end)
    :ok
  end

  defp skip_if_no_entity_spawn(body) do
    if not function_exported?(Ezagent.SpawnRegistry, :registered_schemes, 0) or
         "entity" not in Ezagent.SpawnRegistry.registered_schemes() do
      IO.puts(:stderr, "SKIP: entity spawn fn not registered (test bootstrap incomplete)")
      :ok
    else
      body.()
    end
  end
end
