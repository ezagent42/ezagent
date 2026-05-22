defmodule EzagentDomainChat.Integration.GeneratorTest do
  @moduledoc """
  Phase 7 completion PR-4 (SPEC §2 PR-4) — the Generator, fully.

  Drives `Ezagent.Entity.Session.spawn_from_template/2` through the
  production dispatch path — no mocks — and asserts the 8 SPEC steps:

  - a multi-slot SessionTemplate instantiates ALL workers + the
    routing rules;
  - each worker IS recorded in `Ezagent.AgentLineage` UNDER THE
    ORCHESTRATOR (cap #2 resolves) and is bound to the session
    workspace (invariant 4);
  - `template_working_copy.agent_slots` is populated with the correct
    SOURCE-TEMPLATE URIs (not live instance URIs);
  - the working-copy slice survives a Session restart (snapshot
    reload);
  - re-instantiating the SAME SessionTemplate produces an identical
    team (same slot → source-template mapping);
  - **owner-cap preflight denial** — an owner WITHOUT a SessionTemplate
    `Behavior.Template` cap → the Generator is denied
    `{:error, :unauthorized}`; an owner without cap-#3/#4 authority →
    the orchestrator still spawns but its delegated cap set OMITS
    cap #3 and/or cap #4 (no fabricated authority).

  Workers are instantiated through the `template.instantiate` dispatch
  path — NOT `Class.instantiate/3` directly — so the §1.6a wrapper
  records lineage + binds the workspace. A synthetic flavor is
  registered for the test so the workers spawn the plain
  `Ezagent.Entity.Agent` Kind with no PTY.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{AgentFlavorRegistry, AgentLineage, Behavior, Capability, KindRegistry}
  alias Ezagent.Entity.{Session, SessionTemplate, User}

  # --- a no-PTY test Template Class --------------------------------------

  defmodule TestFlavorClass do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "generator.test.agent"

    @impl true
    def validate(tmpl) when is_map(tmpl), do: if(Map.has_key?(tmpl, "agent_uri"), do: :ok, else: {:error, :missing_agent_uri})
    def validate(_), do: {:error, :not_a_map}

    # Just bring the Agent Kind up — no PTY, no claude. The flavor's
    # `kind: Ezagent.Entity.Agent` wiring means SpawnRegistry resolves
    # the URI to the plain Agent Kind.
    #
    # codex round-6 HIGH-1 / round-7 HIGH-1 — return the 3-element
    # `{:ok, uris, %{fresh?: _}}` form, deriving `fresh?` from the
    # ATOMIC `SpawnRegistry.spawn_detailed/1` outcome (`:started` vs
    # `:already_started`). All production Template Classes (cc / echo /
    # curl) use this form; `spawn_from_template_content/4` records
    # lineage + binds the workspace only for `fresh?: true` workers.
    @impl true
    def instantiate(_tmpl_name, %{"agent_uri" => uri_str}, _workspace_uri) do
      agent_uri = URI.parse(uri_str)

      case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do
        {:ok, :started, _pid} -> {:ok, [agent_uri], %{fresh?: true}}
        {:ok, :already_started, _pid} -> {:ok, [agent_uri], %{fresh?: false}}
        {:error, _} = err -> err
      end
    end

    def instantiate(_n, tmpl, _ws), do: {:error, {:invalid_template, tmpl}}
  end

  # --- helpers -----------------------------------------------------------

  defp uniq, do: System.unique_integer([:positive])

  # Register a unique synthetic flavor for this test run. Idempotent
  # registration is fine; a unique name avoids collision with siblings.
  defp register_test_flavor do
    flavor = "gentest#{uniq()}"

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: TestFlavorClass
      })

    flavor
  end

  # An AgentTemplate content map for the test flavor.
  defp agent_template_content(flavor, name) do
    %{
      name: name,
      description: "worker #{name}",
      flavor: flavor,
      working_directory: "/tmp/generator-test",
      claude_config_dir: nil,
      settings_path: nil,
      mcp_config_path: nil,
      api_key_helper: nil,
      default_caps: [],
      created_by: User.admin_uri(),
      created_at: ~U[2026-05-22 00:00:00Z]
    }
  end

  # Spawn an AgentTemplate Kind at `uri` and populate its `:template`
  # slice via the dispatch `:write` path.
  defp create_agent_template(uri, content) do
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    {:ok, %{content: ^content}} = dispatch(uri, "template.write", %{content: content})
    :ok
  end

  defp dispatch(uri, action, args) do
    target = URI.parse("#{URI.to_string(uri)}?action=#{action}")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: User.admin_uri(),
        caps: User.admin_caps(),
        reply: {:caller_inbox, self()}
      }
    })
  end

  # Build a SessionTemplate content map + persist the Kind at its
  # content-addressed hash URI.
  defp create_session_template(name, agent_slots, routing_rules) do
    content = %{
      name: name,
      description: "test team #{name}",
      agent_slots: agent_slots,
      routing_rules: routing_rules,
      orchestrator_template_uri: URI.parse("template://agent/default/cc-orchestrator"),
      default_workspace_uri: URI.parse("workspace://default"),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-05-22 00:00:00Z]
    }

    {:ok, uri} = SessionTemplate.persist_version(content, "default")
    uri
  end

  # Spawn a User Kind at `uri` carrying exactly `caps`.
  defp spawn_owner(uri, caps) do
    {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: uri, initial_caps: MapSet.new(caps)})
    :ok
  end

  # A `Behavior.Template` cap for a kind, workspace-bounded.
  defp template_cap(kind, workspace_uri) do
    %Capability{
      kind: kind,
      behavior: Behavior.Template,
      instance: {:within_workspace, workspace_uri},
      workspace_uri: workspace_uri,
      granted_by: User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  # Read the live orchestrator's caps directly off its Identity slice.
  defp orchestrator_caps(orchestrator_uri) do
    {:ok, pid} = KindRegistry.lookup(orchestrator_uri)

    pid
    |> :sys.get_state()
    |> Map.get(:state, %{})
    |> Map.get(:identity, %{})
    |> Map.get(:caps, MapSet.new())
  end

  # Read the durable template_working_copy off the live Session's slice.
  defp session_working_copy(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)

    chat_slice =
      pid
      |> :sys.get_state()
      |> Map.get(:state, %{})
      |> Map.get(:chat, %{})

    Ezagent.Behavior.Chat.template_working_copy(chat_slice)
  end

  @workspace_uri URI.new!("workspace://default")

  # --- the happy path: multi-slot team -----------------------------------

  describe "Generator instantiates a multi-slot team" do
    setup do
      flavor = register_test_flavor()

      # Two worker AgentTemplates.
      backend_uri = URI.new!("template://agent/default/gen-backend-#{uniq()}")
      frontend_uri = URI.new!("template://agent/default/gen-frontend-#{uniq()}")
      :ok = create_agent_template(backend_uri, agent_template_content(flavor, "backend"))
      :ok = create_agent_template(frontend_uri, agent_template_content(flavor, "frontend"))

      # A SessionTemplate with 2 slots + 1 routing rule whose receiver
      # is a slot NAME.
      st_uri =
        create_session_template(
          "gen-team-#{uniq()}",
          [{"backend-dev", backend_uri}, {"frontend-dev", frontend_uri}],
          [{{:text_contains, "deploy"}, ["backend-dev"]}]
        )

      # An owner holding a SessionTemplate Behavior.Template cap (so the
      # Generator-entry preflight passes) AND an AgentTemplate one.
      owner_uri = URI.parse("entity://user/default/gen-owner-#{uniq()}")

      :ok =
        spawn_owner(owner_uri, [
          template_cap(:session_template, @workspace_uri),
          template_cap(:agent_template, @workspace_uri)
        ])

      %{
        st_uri: st_uri,
        owner_uri: owner_uri,
        backend_uri: backend_uri,
        frontend_uri: frontend_uri
      }
    end

    test "all workers spawn, land in AgentLineage under the orchestrator + are workspace-bound",
         %{st_uri: st_uri, owner_uri: owner_uri} do
      assert {:ok, %{session_uri: session_uri, orchestrator_uri: orch_uri}} =
               Session.spawn_from_template(st_uri, owner_uri)

      wc = session_working_copy(session_uri)
      assert length(wc.agent_slots) == 2

      # Each slot's worker (built from the slot name, flavor-prefixed)
      # is alive, recorded under the orchestrator in AgentLineage, and
      # bound to the session workspace.
      for {_slot_name, agent_template_uri} <- wc.agent_slots do
        # source URI is the AgentTemplate URI, NOT a live instance URI.
        assert agent_template_uri.scheme == "template"
        assert agent_template_uri.host == "agent"
      end

      # The live workers (resolved from the slot names) are in lineage.
      worker_uris = live_worker_uris(orch_uri)
      assert length(worker_uris) == 2

      for worker_uri <- worker_uris do
        assert {:ok, _pid} = KindRegistry.lookup(worker_uri)

        assert AgentLineage.spawned_in_lineage?(worker_uri, orch_uri),
               "worker #{URI.to_string(worker_uri)} must be in the orchestrator's lineage " <>
                 "(cap #2 {:spawned_by, orchestrator} depends on it)"

        assert {:ok, ws} = Ezagent.WorkspaceRegistry.lookup(worker_uri)
        assert URI.to_string(ws) == "workspace://default"
      end
    end

    test "template_working_copy.agent_slots holds the source-template URIs", %{
      st_uri: st_uri,
      owner_uri: owner_uri,
      backend_uri: backend_uri,
      frontend_uri: frontend_uri
    } do
      assert {:ok, %{session_uri: session_uri}} = Session.spawn_from_template(st_uri, owner_uri)

      wc = session_working_copy(session_uri)
      # Phase 7 hardening — agent_slots is the 4-tuple
      # {slot_name, source_agent_template_uri, live_worker_uri, generation}.
      slots =
        Map.new(wc.agent_slots, fn {name, src, _live, _gen} ->
          {name, URI.to_string(src)}
        end)

      assert slots["backend-dev"] == URI.to_string(backend_uri)
      assert slots["frontend-dev"] == URI.to_string(frontend_uri)
    end

    test "the routing rule slot-name resolves to a live worker URI", %{
      st_uri: st_uri,
      owner_uri: owner_uri
    } do
      assert {:ok, %{orchestrator_uri: orch_uri}} =
               Session.spawn_from_template(st_uri, owner_uri)

      rules = Ezagent.Routing.RuleStore.list(EzagentDomainChat.Routing.MentionRouting)

      # The Generator installed a rule whose receivers are the live
      # `entity://agent/...` URI the "backend-dev" slot resolved to.
      worker_uris = live_worker_uris(orch_uri) |> Enum.map(&URI.to_string/1)

      installed =
        Enum.find(rules, fn r ->
          Enum.any?(r.receivers, &(&1 in worker_uris))
        end)

      assert installed, "the Generator must install the SessionTemplate's routing rule " <>
                          "with slot names resolved to live worker URIs"
    end

    test "the working-copy slice survives a Session restart", %{
      st_uri: st_uri,
      owner_uri: owner_uri
    } do
      assert {:ok, %{session_uri: session_uri}} = Session.spawn_from_template(st_uri, owner_uri)

      before = session_working_copy(session_uri)
      assert length(before.agent_slots) == 2

      # Stop the Session Kind, then re-reference it — the snapshot
      # rehydrates the :chat slice.
      {:ok, pid} = KindRegistry.lookup(session_uri)
      DynamicSupervisor.terminate_child(EzagentDomainChat.SessionSupervisor, pid)
      wait_until(fn -> KindRegistry.lookup(session_uri) == :error end)

      {:ok, _pid} = Ezagent.SpawnRegistry.spawn(session_uri)
      restored = session_working_copy(session_uri)

      assert length(restored.agent_slots) == 2
      # The whole 4-tuple (incl. live worker URI + generation) survives.
      assert Enum.sort(restored.agent_slots) == Enum.sort(before.agent_slots)
    end

    test "re-instantiating the SAME SessionTemplate produces an identical team", %{
      st_uri: st_uri,
      owner_uri: owner_uri
    } do
      assert {:ok, %{session_uri: s1}} = Session.spawn_from_template(st_uri, owner_uri)
      assert {:ok, %{session_uri: s2}} = Session.spawn_from_template(st_uri, owner_uri)

      assert s1 != s2, "each Generator call produces a fresh session"

      # Same slot → source-template mapping (the team config is
      # identical). The CRITICAL hardening fix means the LIVE worker
      # URIs DIFFER between the two sessions — so we compare only the
      # {slot_name, source_agent_template_uri} projection.
      wc1 = session_working_copy(s1)
      wc2 = session_working_copy(s2)

      norm = fn wc ->
        wc.agent_slots
        |> Enum.map(fn {name, src, _live, _gen} -> {name, URI.to_string(src)} end)
        |> Enum.sort()
      end

      assert norm.(wc1) == norm.(wc2),
             "re-instantiating the same template yields the same slot → source-template team"

      # ...and the LIVE worker URIs are DISJOINT (CRITICAL fix).
      live = fn wc ->
        wc.agent_slots |> Enum.map(fn {_n, _s, live, _g} -> URI.to_string(live) end)
      end

      assert MapSet.disjoint?(MapSet.new(live.(wc1)), MapSet.new(live.(wc2))),
             "two sessions from one SessionTemplate must get DISJOINT live worker URIs"
    end
  end

  # The live `entity://agent/...` worker URIs for a given orchestrator —
  # exactly the agents the Generator recorded UNDER that orchestrator in
  # `AgentLineage` (cap #2's `{:spawned_by, orchestrator}` source). Per
  # orchestrator → no cross-test bleed from the global registry.
  defp live_worker_uris(orchestrator_uri) do
    orch_str = URI.to_string(orchestrator_uri)

    AgentLineage.list_all()
    |> Enum.filter(fn {_agent, spawned_by} -> spawned_by == orch_str end)
    |> Enum.map(fn {agent, _spawned_by} -> URI.parse(agent) end)
  end

  # --- owner-cap preflight denial ----------------------------------------

  describe "owner-cap preflight (SPEC §1.4)" do
    setup do
      flavor = register_test_flavor()
      worker_uri = URI.new!("template://agent/default/gen-pf-worker-#{uniq()}")
      :ok = create_agent_template(worker_uri, agent_template_content(flavor, "worker"))

      st_uri =
        create_session_template(
          "gen-pf-team-#{uniq()}",
          [{"worker", worker_uri}],
          []
        )

      %{st_uri: st_uri}
    end

    test "owner with NO SessionTemplate Behavior.Template cap → Generator denied", %{
      st_uri: st_uri
    } do
      # Owner holds no template caps at all.
      owner_uri = URI.parse("entity://user/default/gen-pf-nocap-#{uniq()}")
      :ok = spawn_owner(owner_uri, [])

      assert {:error, :unauthorized} = Session.spawn_from_template(st_uri, owner_uri)
    end

    test "owner with cap #3 but NOT cap #4 → orchestrator gets #3, omits #4", %{st_uri: st_uri} do
      # Owner holds ONLY a :session_template cap — passes the Generator
      # entry gate + the cap-#3 preflight, but FAILS the cap-#4 preflight.
      owner_uri = URI.parse("entity://user/default/gen-pf-only3-#{uniq()}")
      :ok = spawn_owner(owner_uri, [template_cap(:session_template, @workspace_uri)])

      assert {:ok, %{orchestrator_uri: orch_uri}} =
               Session.spawn_from_template(st_uri, owner_uri)

      caps = orchestrator_caps(orch_uri)

      assert has_template_cap?(caps, :session_template),
             "owner holds :session_template authority → cap #3 IS delegated"

      refute has_template_cap?(caps, :agent_template),
             "owner lacks :agent_template authority → cap #4 must NOT be fabricated"

      # Caps #1/#2 are unconditional regardless.
      assert has_scope_cap?(caps, :session, :within_session)
      assert has_scope_cap?(caps, :agent, :spawned_by)
    end

    test "owner with full template authority → orchestrator gets both #3 and #4", %{
      st_uri: st_uri
    } do
      owner_uri = URI.parse("entity://user/default/gen-pf-full-#{uniq()}")

      :ok =
        spawn_owner(owner_uri, [
          template_cap(:session_template, @workspace_uri),
          template_cap(:agent_template, @workspace_uri)
        ])

      assert {:ok, %{orchestrator_uri: orch_uri}} =
               Session.spawn_from_template(st_uri, owner_uri)

      caps = orchestrator_caps(orch_uri)
      assert has_template_cap?(caps, :session_template)
      assert has_template_cap?(caps, :agent_template)
    end
  end

  # --- codex round-8 HIGH-2: fresh?: false ownership verification --------
  #
  # A `fresh?: false` worker means `spawn_from_template_content/4` did NO
  # lineage/workspace binding (round-7 gating). If a candidate worker
  # appeared in the TOCTOU window between `preflight_candidate_uris_free/3`
  # and the atomic spawn, the Generator must NOT record it in the session
  # working-copy + routing rules unless its ownership verifies:
  # `AgentLineage.lookup` == this orchestrator AND `WorkspaceRegistry.lookup`
  # == the target workspace. Otherwise the slot fails
  # `:slot_candidate_not_owned`.

  # A Template Class whose `instantiate/3` ALWAYS reports `fresh?: false`
  # and records NO lineage/workspace binding — modelling a foreign /
  # unknown-lineage worker that appeared in the TOCTOU window. The
  # Generator must REFUSE to adopt it.
  defmodule ForeignWorkerClass do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "generator.test.foreign-worker"

    @impl true
    def validate(tmpl) when is_map(tmpl),
      do: if(Map.has_key?(tmpl, "agent_uri"), do: :ok, else: {:error, :missing_agent_uri})

    def validate(_), do: {:error, :not_a_map}

    @impl true
    def instantiate(_n, %{"agent_uri" => uri_str}, _ws) do
      agent_uri = URI.parse(uri_str)
      # Spawn the Kind so the URI is live, but report `fresh?: false`
      # and record NOTHING — the worker has unknown lineage + is not
      # workspace-bound. (`spawn_from_template_content/4` skips its own
      # recording for `fresh?: false`, round-7.)
      _ = Ezagent.SpawnRegistry.spawn_detailed(agent_uri)
      {:ok, [agent_uri], %{fresh?: false}}
    end

    def instantiate(_n, tmpl, _ws), do: {:error, {:invalid_template, tmpl}}
  end

  # A Template Class whose `instantiate/3` reports `fresh?: false` but
  # FIRST records lineage + workspace binding for the worker under THIS
  # run's orchestrator + workspace — modelling the legitimate idempotent
  # `Workspace.Loader` re-run, where the FIRST (fresh) instantiation
  # already recorded ownership. The Generator MUST accept it.
  #
  # The orchestrator URI is reconstructed from the worker URI: the
  # Generator folds the session discriminator (`gen-<millis>-<int>`) into
  # the worker instance name as the `--<disc>` suffix
  # (`session_instance_name/3`), and the orchestrator instance is
  # `entity://agent/<ws>/cc_orchestrator-<disc>` (`spawn_orchestrator/3`).
  defmodule OwnedRerunClass do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "generator.test.owned-rerun"

    @impl true
    def validate(tmpl) when is_map(tmpl),
      do: if(Map.has_key?(tmpl, "agent_uri"), do: :ok, else: {:error, :missing_agent_uri})

    def validate(_), do: {:error, :not_a_map}

    @impl true
    def instantiate(_n, %{"agent_uri" => uri_str}, %URI{} = workspace_uri) do
      agent_uri = URI.parse(uri_str)
      _ = Ezagent.SpawnRegistry.spawn_detailed(agent_uri)

      orchestrator_uri = reconstruct_orchestrator_uri(agent_uri)

      # The FIRST fresh instantiation would have recorded these; this
      # call is the idempotent re-run, so the worker is already owned.
      :ok = Ezagent.AgentLineage.record(agent_uri, orchestrator_uri)
      :ok = Ezagent.WorkspaceRegistry.bind(agent_uri, workspace_uri)

      {:ok, [agent_uri], %{fresh?: false}}
    end

    def instantiate(_n, tmpl, _ws), do: {:error, {:invalid_template, tmpl}}

    # worker URI: entity://agent/<ws>/<flavor>_<slot>-<hash>--<disc>
    # orchestrator: entity://agent/<ws>/cc_orchestrator-<disc>
    defp reconstruct_orchestrator_uri(%URI{path: "/" <> rest} = worker_uri) do
      [ws, entity_name] = String.split(rest, "/", parts: 2)
      [_flavor, suffix] = String.split(entity_name, "_", parts: 2)
      [_slot_component, disc] = String.split(suffix, "--", parts: 2)

      URI.new!("#{worker_uri.scheme}://#{worker_uri.host}/#{ws}/cc_orchestrator-#{disc}")
    end
  end

  describe "fresh?: false slot candidate ownership verification (codex round-8 HIGH-2)" do
    test "a fresh?: false worker NOT owned by this orchestrator fails the slot" do
      flavor = "genforeign#{uniq()}"

      :ok =
        AgentFlavorRegistry.register(%{
          flavor: flavor,
          kind: Ezagent.Entity.Agent,
          template_class: ForeignWorkerClass
        })

      worker_uri = URI.new!("template://agent/default/gen-foreign-worker-#{uniq()}")
      :ok = create_agent_template(worker_uri, agent_template_content(flavor, "foreign"))

      st_uri =
        create_session_template(
          "gen-foreign-team-#{uniq()}",
          [{"foreign-slot", worker_uri}],
          []
        )

      owner_uri = URI.parse("entity://user/default/gen-foreign-owner-#{uniq()}")

      :ok =
        spawn_owner(owner_uri, [
          template_cap(:session_template, @workspace_uri),
          template_cap(:agent_template, @workspace_uri)
        ])

      # The Generator must REFUSE the foreign worker — the slot fails
      # `:slot_candidate_not_owned`, wrapped by `instantiate_agent_slots`
      # as `{:agent_slot_failed, slot_name, reason}`.
      assert {:error, {:agent_slot_failed, "foreign-slot", reason}} =
               Session.spawn_from_template(st_uri, owner_uri)

      assert {:slot_candidate_not_owned, "foreign-slot", _worker_uri_str} = reason,
             "a fresh?: false worker with unknown lineage must NOT be silently adopted"
    end

    test "a fresh?: false worker already owned by this orchestrator+workspace succeeds (idempotent re-run)" do
      flavor = "genrerun#{uniq()}"

      :ok =
        AgentFlavorRegistry.register(%{
          flavor: flavor,
          kind: Ezagent.Entity.Agent,
          template_class: OwnedRerunClass
        })

      worker_uri = URI.new!("template://agent/default/gen-rerun-worker-#{uniq()}")
      :ok = create_agent_template(worker_uri, agent_template_content(flavor, "rerun"))

      st_uri =
        create_session_template(
          "gen-rerun-team-#{uniq()}",
          [{"rerun-slot", worker_uri}],
          []
        )

      owner_uri = URI.parse("entity://user/default/gen-rerun-owner-#{uniq()}")

      :ok =
        spawn_owner(owner_uri, [
          template_cap(:session_template, @workspace_uri),
          template_cap(:agent_template, @workspace_uri)
        ])

      # A fresh?: false worker that IS already owned by this run's
      # orchestrator + workspace (the legitimate idempotent re-run)
      # passes ownership verification — the Generator commits it.
      assert {:ok, %{session_uri: session_uri, orchestrator_uri: orch_uri}} =
               Session.spawn_from_template(st_uri, owner_uri)

      wc = session_working_copy(session_uri)
      assert length(wc.agent_slots) == 1

      [{slot_name, _src, live_worker_uri, _gen}] = wc.agent_slots
      assert slot_name == "rerun-slot"

      # The committed worker is the one the OwnedRerunClass owned.
      assert {:ok, lineage} = AgentLineage.lookup(live_worker_uri)
      assert URI.to_string(lineage) == URI.to_string(orch_uri)

      assert {:ok, ws} = Ezagent.WorkspaceRegistry.lookup(live_worker_uri)
      assert URI.to_string(ws) == "workspace://default"
    end
  end

  defp has_template_cap?(caps, kind) do
    Enum.any?(caps, fn cap ->
      cap.kind == kind and cap.behavior == Behavior.Template and
        match?({:within_workspace, _}, cap.instance)
    end)
  end

  defp has_scope_cap?(caps, kind, scope_tag) do
    Enum.any?(caps, fn cap ->
      cap.kind == kind and match?({^scope_tag, _}, cap.instance)
    end)
  end

  # The behavior_template_dispatch_test wait helper — re-used here.
  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: :ok

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

end
