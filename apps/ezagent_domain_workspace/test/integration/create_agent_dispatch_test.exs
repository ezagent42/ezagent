defmodule Ezagent.Integration.CreateAgentDispatchTest do
  @moduledoc """
  Acceptance test for SPEC 2026-05-25-agent-create-cli-gui-parity:
  the unified `Ezagent.Workspace.create_agent/3` facade — what BOTH the CLI
  (`mix ezagent.agent.create`) and the operator UI call — dispatches the
  `ActionSet.Workspace.:create_agent` action.

  Focused on the action's contract surface (validation + early-exit
  shapes) without needing real plugin Template Classes. The full
  spawn-via-Template chain is exercised by:

  - `add_template_invokes_test.exs` — the Loader.invoke_template
    chain that the action body delegates to.
  - Plugin-side integration tests (`ezagent_plugin_cc/test/...`) —
    cc/py Template Class instantiate behaviour.

  This test verifies the unification's WIRING: the dispatched action
  routes through `ActionSet.Workspace.:create_agent` and returns the
  shapes the CLI + LV both consume.
  """

  use EzagentCore.DataCase, async: false

  import Ecto.Query

  alias Ezagent.Cap.Delivery
  alias Ezagent.Workspace
  alias Ezagent.Entity.User

  setup do
    ws_name = "create-agent-test-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})

    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = signed_workspace_ctx!(workspace_uri)

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  describe "Ezagent.Workspace.create_agent/3 — validation + dispatch wiring" do
    test "empty flavor returns {:error, :flavor_required}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, :flavor_required} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: "", name: "x", cwd: "", with_pty: false},
                 admin_ctx
               )
    end

    test "empty name returns {:error, :name_required}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, :name_required} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: "curl", name: "", cwd: "", with_pty: false},
                 admin_ctx
               )
    end

    test "bad flavor returns {:error, {:bad_flavor, _}}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, {:bad_flavor, "definitely-not-a-flavor"}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "definitely-not-a-flavor",
                   name: "x",
                   cwd: "",
                   with_pty: false
                 },
                 admin_ctx
               )
    end

    test "bad name returns {:error, {:bad_name, _}}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, {:bad_name, "invalid name with space"}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "curl",
                   name: "invalid name with space",
                   cwd: "",
                   with_pty: false
                 },
                 admin_ctx
               )
    end

    test "file flavors accept empty cwd so the config_dir default can apply" do
      for flavor <- ~w(cc cc-headless codex codex-remote) do
        assert :ok =
                 Ezagent.ActionSet.Workspace.AgentCreate.FlavorValidation.validate_cwd_for_flavor(
                   flavor,
                   false,
                   ""
                 )
      end
    end

    test "file flavor template defaults empty project_cwd to the per-agent config_dir", %{
      ws_name: ws_name
    } do
      {:ok, _apps} = Application.ensure_all_started(:ezagent_plugin_cc)

      agent_uri =
        Ezagent.URI.agent(
          ws_name,
          "cc_default-cwd-#{System.unique_integer([:positive])}"
        )

      tmpl =
        Ezagent.ActionSet.Workspace.__file_flavor_template_for_test__(
          "cc",
          "cc.agent",
          agent_uri,
          ""
        )

      assert tmpl["project_cwd"] == tmpl["config_dir"]
      assert String.contains?(tmpl["project_cwd"], "/cc-agents/#{ws_name}/cc_default-cwd-")
    end

    test "cc flavor nonexistent cwd returns {:error, {:cwd_not_a_dir, _}}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      assert {:error, {:cwd_not_a_dir, "/this/path/definitely/does/not/exist/anywhere"}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "cc",
                   name: "demo",
                   cwd: "/this/path/definitely/does/not/exist/anywhere",
                   with_pty: false
                 },
                 admin_ctx
               )
    end
  end

  describe "Ezagent.Workspace.grant_initial_caps/3 — empty list short-circuit" do
    test "empty cap list returns :ok without dispatching", %{admin_ctx: admin_ctx} do
      # No agent URI needed — empty list never touches dispatch.
      fake_uri = Ezagent.URI.new!("entity://system/agent/cc_fake")
      assert :ok = Workspace.grant_initial_caps(fake_uri, [], admin_ctx)
    end
  end

  # System-principal elimination (#154, 2026-06-19) — behavioral proof for the
  # ONE ISSUE sub-path of `mix ezagent.agent.create --caps`: the operator's ctx
  # now carries `caller: User.admin_uri()`, and `grant_initial_caps/3` calls
  # `Ezagent.Cap.issue/3` as `{:held_by, caller}`. The chokepoint RE-READS the
  # caller's REAL held caps (`Ezagent.Identity.read_held_caps/1`) to authorize.
  # This proves the admin entity (a) resolves and (b) holds the
  # bootstrap wildcard (`User.initial_caps_for_spawn/1`) — i.e. the grant
  # AUTHORIZES. (The prior mix-task code passed `caller: system://mix-task`,
  # whose `read_held_caps` returns EMPTY → any `--caps` grant would have failed;
  # it only ever short-circuited because no `--caps` were given.)
  describe "Ezagent.Workspace.grant_initial_caps/3 — operator → admin-entity grant (#154)" do
    test "a non-empty cap grant under caller=admin_uri authorizes + lands on the agent", %{
      ws_name: ws_name,
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      # Create a real agent through the same facade the mix task uses.
      name = "graphite-#{System.unique_integer([:positive])}"

      assert {:ok, %{agent_uri: agent_uri}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: "curl", name: name, cwd: "", with_pty: false},
                 admin_ctx
               )

      # The operator-parsed cap to grant the new agent (a concrete, non-wildcard
      # cap so this exercises the real authorization, not just the empty path).
      granted_cap =
        Ezagent.Capability.cap(
          :session,
          Ezagent.ActionSet.Session,
          :send,
          Ezagent.URI.new!("session://#{ws_name}/default/main"),
          workspace_uri
        )

      # mix-task ctx: caller is the real admin entity (NOT system://mix-task).
      operator_ctx = %{caller: User.admin_uri(), caps: admin_ctx.caps}

      assert :ok = Workspace.grant_initial_caps(agent_uri, [granted_cap], operator_ctx)

      # ABSORB is intentionally a cast; eventually the artifact lands on the
      # agent's identity slice with issuer provenance = admin.
      assert eventually(fn ->
               agent_uri
               |> Ezagent.Identity.read_entity_caps()
               |> Enum.any?(fn
                 %Ezagent.Capability{behavior: Ezagent.ActionSet.Session, granted_by: gb} = c ->
                   Ezagent.Capability.action_of(c) == :send and gb == User.admin_uri()

                 _ ->
                   false
               end)
             end),
             "expected the operator → admin-entity grant to land on the agent's caps"
    end
  end

  describe "S7 grant_initial_caps issue + self-store hand-off" do
    test "a not-ready agent persists the artifacts and never blocks workspace provisioning", %{
      ws_name: ws_name,
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      name = "s7-buffered-#{System.unique_integer([:positive])}"

      assert {:ok, %{agent_uri: agent_uri}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: "curl", name: name, cwd: "", with_pty: false},
                 admin_ctx
               )

      {:ok, agent_pid} = Ezagent.KindRegistry.lookup(agent_uri)
      on_exit(fn -> terminate_agent(agent_uri) end)

      proposal =
        Ezagent.Capability.cap(
          :session,
          Ezagent.ActionSet.Session,
          :send,
          Ezagent.URI.session(ws_name, :default, :s7_target),
          workspace_uri
        )

      :ok = Ezagent.ReadyGate.put(agent_uri, :not_ready)
      buffer_size_before = Ezagent.PendingDelivery.buffer_size(agent_uri)

      task =
        Task.async(fn ->
          receive do
            :run -> Workspace.grant_initial_caps(agent_uri, [proposal], admin_ctx)
          end
        end)

      Ecto.Adapters.SQL.Sandbox.allow(EzagentCore.Repo, self(), task.pid)
      send(task.pid, :run)

      assert {:ok, :ok} = Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
      assert Ezagent.ReadyGate.status(agent_uri) == :not_ready
      assert Ezagent.PendingDelivery.buffer_size(agent_uri) == buffer_size_before

      delivery =
        EzagentCore.Repo.one!(
          from(delivery in Delivery,
            where: delivery.target_uri == ^URI.to_string(agent_uri),
            where: delivery.op == :absorb_cap,
            where: delivery.status == :pending,
            order_by: [desc: delivery.id],
            limit: 1
          )
        )

      refute Enum.any?(Ezagent.Identity.read_entity_caps(agent_uri), fn cap ->
               cap.behavior == Ezagent.ActionSet.Session and cap.action == :send
             end)

      assert :ready =
               Ezagent.Kind.ReadyTransition.drain_pending_then_mark_ready(
                 URI.to_string(agent_uri),
                 agent_pid
               )

      assert eventually(fn ->
               Enum.any?(Ezagent.Identity.read_entity_caps(agent_uri), fn cap ->
                 cap.behavior == Ezagent.ActionSet.Session and
                   cap.action == :send and
                   cap.instance == Ezagent.URI.instance(proposal.instance) and
                   cap.granted_by == User.admin_uri()
               end) and
                 EzagentCore.Repo.get!(Delivery, delivery.id).status == :applied
             end)
    end

    test "all ISSUE authorization finishes before the first absorb hand-off", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      name = "s7-c2-#{System.unique_integer([:positive])}"

      assert {:ok, %{agent_uri: agent_uri}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: "curl", name: name, cwd: "", with_pty: false},
                 admin_ctx
               )

      on_exit(fn -> terminate_agent(agent_uri) end)

      cap_config = Application.fetch_env!(:ezagent_core, Ezagent.Cap)
      loader = EzagentCore.Test.CapAuthorityLoaderStub
      loader_config = Application.fetch_env(:ezagent_core, loader)

      on_exit(fn ->
        Application.put_env(:ezagent_core, Ezagent.Cap, cap_config)

        case loader_config do
          {:ok, value} -> Application.put_env(:ezagent_core, loader, value)
          :error -> Application.delete_env(:ezagent_core, loader)
        end
      end)

      Application.put_env(
        :ezagent_core,
        Ezagent.Cap,
        Keyword.put(cap_config, :authority_loader, loader)
      )

      caller = User.admin_uri()

      {:ok, authority_anchor} = Ezagent.Cap.Authority.anchor(agent_uri)
      Application.put_env(:ezagent_core, loader, MapSet.new([authority_anchor]))

      owner_permitted =
        Ezagent.Capability.cap(
          :agent,
          Ezagent.ActionSet.Identity,
          :list_caps,
          agent_uri,
          workspace_uri
        )

      missing_target =
        Ezagent.URI.agent(workspace_uri.host, "missing-#{System.unique_integer([:positive])}")

      later_denied =
        Ezagent.Capability.cap(
          :agent,
          Ezagent.ActionSet.Identity,
          :list_caps,
          missing_target,
          workspace_uri
        )

      assert {:ok, %Ezagent.Capability{instance: ^agent_uri}} =
               Ezagent.Cap.issue({:held_by, caller}, agent_uri, owner_permitted)

      caps_before = Ezagent.Identity.read_entity_caps(agent_uri)
      buffer_size_before = Ezagent.PendingDelivery.buffer_size(agent_uri)

      assert {:error,
              {:grant_failed, ^later_denied,
               {:no_kind_module_for_agent, missing_target_string}}} =
               Workspace.grant_initial_caps(
                 agent_uri,
                 [owner_permitted, later_denied],
                 %{
                   caller: caller,
                   # C1 teeth: caller-supplied caps are deliberately powerful,
                   # but ISSUE must ignore them and use the configured durable
                   # authority loader, which is empty in this test.
                   caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
                 }
               )

      assert missing_target_string == URI.to_string(missing_target)

      assert Ezagent.Identity.read_entity_caps(agent_uri) == caps_before
      assert Ezagent.PendingDelivery.buffer_size(agent_uri) == buffer_size_before
    end
  end

  describe "Ezagent.Workspace.create_agent/3 — `--from` source resolution (agent.duplicate simple SPEC)" do
    # These tests exercise the contract surface of the `--from` flag:
    #   - flavor gating (only `cc` supports clone)
    #   - source resolution failures (no_such_actor, not_readable)
    #
    # The end-to-end deep-copy is covered in the cc plugin test
    # (`cc_agent_clone_from_test.exs`) since the actual `File.cp_r/2`
    # lives in `Ezagent.PluginCc.Template.CcAgent.create_agent_config_dir/2`.

    test "py flavor with --from returns {:error, {:from_unsupported_for_flavor, _}}", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      source_uri = Ezagent.URI.new!("entity://system/agent/cc_some-source")

      assert {:error, {:from_unsupported_for_flavor, "py"}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "py",
                   name: "clone-me",
                   cwd: "",
                   with_pty: false,
                   from: source_uri,
                   flavor_config: %{"script" => "print('x')"}
                 },
                 admin_ctx
               )
    end

    test "cc + --from pointing at a non-existent source returns {:error, :source_not_found}",
         %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

      # A real `cc_` URI shape so coerce + validate pass; the URI must
      # NOT correspond to a live Agent Kind — `sandbox.read` dispatch
      # short-circuits at ReadyGate with `:no_such_actor`.
      source_uri =
        URI.parse(
          "entity://#{ws_name}/agent/cc_definitely-does-not-exist-#{System.unique_integer([:positive])}"
        )

      # cwd MUST exist for the cc validator to get past `:cwd_not_a_dir`
      # — we want to exercise the source-resolution branch, not earlier
      # validation.
      assert {:error, :source_not_found} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "cc",
                   name: "new-clone",
                   cwd: System.tmp_dir!(),
                   with_pty: false,
                   from: source_uri
                 },
                 admin_ctx
               )
    end

    test "bad --from shape (not an entity://agent/ URI) is rejected at the dispatch validator",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      # Two layers of defense:
      #  - dispatch-level: `InterfaceValidator` rejects anything that
      #    isn't `%URI{}` for the `from` arg (`{:option, :uri}` schema)
      #    → `{:invalid_args, [{[:from], {:type_mismatch, _}}]}`.
      #  - action-body: `coerce_create_args/1`'s `valid_from?/1`
      #    rejects a `%URI{}` whose scheme/host isn't entity/agent
      #    → `{:bad_from, _}`.
      # This test asserts the FIRST gate fires for a non-URI string.
      assert {:error, {:invalid_args, violations}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "cc",
                   name: "x",
                   cwd: System.tmp_dir!(),
                   with_pty: false,
                   from: "not-a-uri-string"
                 },
                 admin_ctx
               )

      assert [{[:from], {:type_mismatch, _}}] = violations
    end

    test "bad --from URI (right type, wrong scheme) is rejected by valid_from?/1", %{
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      # The action body's `valid_from?/1` rejects a `%URI{}` that
      # doesn't conform to `entity://agent/...`. This guards against a
      # caller bypassing the CLI parser (e.g. LV building its own args).
      bad_uri = URI.parse("http://example.com/not-an-agent")

      assert {:error, {:bad_from, ^bad_uri}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "cc",
                   name: "x",
                   cwd: System.tmp_dir!(),
                   with_pty: false,
                   from: bad_uri
                 },
                 admin_ctx
               )
    end
  end

  describe "Ezagent.Workspace.create_agent/3 — end-to-end direct-spawn (codex r1 MEDIUM-6 / r2 MEDIUM-1)" do
    setup do
      # Codex PR #330 r2 MEDIUM-1: explicitly start :ezagent_domain_session
      # so the `agent` SpawnRegistry scheme is registered. Without this
      # the test would skip in CI's per-app test runs.
      {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

      case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
        :ok -> :ok
        {:error, {:already_registered, _attr}} -> :ok
      end

      :ok
    end

    @tag :integration
    test "curl flavor — actually spawns the agent + returns {:ok, %{agent_uri}} + live in KindRegistry",
         %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      # Bootstrap guard (codex r2 MEDIUM-1): even after starting the
      # chat domain, the `agent` scheme might be absent if SpawnRegistry
      # wasn't initialised yet (e.g. EtsOwner timing). In that narrow
      # window, skip explicitly rather than accept any spawn failure
      # shape — the original test body accepted `{:error, {:spawn_failed, _}}`
      # which made it pass even when no agent was actually spawned.
      # SpawnRegistry registers schemes; agent URIs have scheme `entity`.
      if not function_exported?(Ezagent.SpawnRegistry, :registered_schemes, 0) or
           "entity" not in Ezagent.SpawnRegistry.registered_schemes() do
        IO.puts(:stderr, "SKIP: entity spawn fn not registered (test bootstrap incomplete)")
        :ok
      else
        name = "ee-#{System.unique_integer([:positive])}"
        expected_uri = Ezagent.URI.agent(ws_name, name)

        # Hard requirement: dispatch must return {:ok, _} AND the agent
        # MUST be alive in KindRegistry afterward. Per codex r2 MEDIUM-1
        # — close the original coverage gap fully.
        assert {:ok, %{agent_uri: agent_uri, template_name: nil}} =
                 Workspace.create_agent(
                   workspace_uri,
                   %{flavor: "curl", name: name, cwd: "", with_pty: false},
                   admin_ctx
                 )

        assert agent_uri == expected_uri
        assert {:ok, "curl"} = Ezagent.UriQuery.resolve(:flavor, agent_uri)

        # The agent Kind must be alive in KindRegistry — this is the
        # invariant the original test was supposed to cover. Without
        # this assertion the test was vacuous on spawn failures.
        assert {:ok, _pid} = Ezagent.KindRegistry.lookup(agent_uri),
               "agent should be alive in KindRegistry after create_agent returned :ok"

        # PR-6+7 (codex round-3 P1-1) REGRESSION — a curl agent created via the
        # generic direct-spawn path must be a FULLY-WORKING curl agent, not a
        # bare Entity.Agent. Pre-fix `direct_spawn_flavor_agent/2` spawned with
        # NO :behaviors, so the agent captured the BASE (non-curl) set: no
        # :curl_agent slice, no flavor field, no reset/configure/sync_result. The
        # fix threads the flavor's :instance_behaviors (curl_behaviors/0).
        # `Kind.spawn/2` (inside create_agent) awaits :ready, so the slice is
        # materialized by the time create_agent returned {:ok, _}.

        # (1) the :curl_agent slice materialized (proves Behavior.CurlAgent is in
        # this instance's effective set) AND its create/1 wrote the durable
        # flavor field.
        assert {:ok, curl_slice} = Ezagent.Kind.get_slice(agent_uri, :curl_agent),
               "curl agent created via create_agent/3 has NO :curl_agent slice — " <>
                 "the direct-spawn path did not thread curl_behaviors/0 (codex r3 P1-1)"

        assert curl_slice.flavor == "curl"
        assert curl_slice.conversation == []

        # (2) the curl public actions resolve to Behavior.CurlAgent on this Kind.
        assert {:ok, Ezagent.ActionSet.CurlAgent} =
                 Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Agent, :reset_conversation)

        # (3) the base credential slice is present (api_keys is in the curl set).
        assert {:ok, api_keys} = Ezagent.Kind.get_slice(agent_uri, :api_keys)
        assert is_map(api_keys)
      end
    end

    @tag :integration
    test "curl direct-spawn ingests create-time config into the durable curl slice",
         %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      if not function_exported?(Ezagent.SpawnRegistry, :registered_schemes, 0) or
           "entity" not in Ezagent.SpawnRegistry.registered_schemes() do
        IO.puts(:stderr, "SKIP: entity spawn fn not registered (test bootstrap incomplete)")
        :ok
      else
        name = "curl-config-#{System.unique_integer([:positive])}"
        expected_uri = Ezagent.URI.agent(ws_name, name)

        assert {:ok, %{agent_uri: agent_uri, template_name: nil}} =
                 Workspace.create_agent(
                   workspace_uri,
                   %{
                     flavor: "curl",
                     name: name,
                     cwd: "",
                     with_pty: false,
                     provider: "openai",
                     api_url: "https://api.openai.com/v1/chat/completions",
                     model: "gpt-4o",
                     max_history: 7
                   },
                   admin_ctx
                 )

        assert agent_uri == expected_uri
        assert {:ok, curl_slice} = Ezagent.Kind.get_slice(agent_uri, :curl_agent)
        assert curl_slice.provider == "openai"
        assert curl_slice.api_url == "https://api.openai.com/v1/chat/completions"
        assert curl_slice.model == "gpt-4o"
        assert curl_slice.max_history == 7

        _ = Ezagent.Kind.terminate(agent_uri)
        assert {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri})
        assert {:ok, rehydrated} = Ezagent.Kind.get_slice(agent_uri, :curl_agent)

        assert rehydrated.provider == "openai"
        assert rehydrated.api_url == "https://api.openai.com/v1/chat/completions"
        assert rehydrated.model == "gpt-4o"
        assert rehydrated.max_history == 7
      end
    end

    @tag :integration
    test "curl direct-spawn rejects invalid schema config through Template.validate/1",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      assert {:error,
              {:spawn_failed, {:invalid_flavor_config, "curl", {:bad_api_url, "ftp://bad"}}}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "curl",
                   name: "curl-invalid-#{System.unique_integer([:positive])}",
                   cwd: "",
                   with_pty: false,
                   flavor_config: %{
                     "provider" => "openai",
                     "api_url" => "ftp://bad",
                     "model" => "gpt-4o"
                   }
                 },
                 admin_ctx
               )
    end

    @tag :integration
    test "flavor config rejects keys not declared by config_schema/0",
         %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      assert {:error, {:unknown_flavor_config_keys, "curl", ["not_a_schema_key"]}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{
                   flavor: "curl",
                   name: "curl-unknown-#{System.unique_integer([:positive])}",
                   cwd: "",
                   with_pty: false,
                   flavor_config: %{"not_a_schema_key" => "do-not-store"}
                 },
                 admin_ctx
               )
    end

    @tag :integration
    test "native flavor (NO :instance_behaviors) still direct-spawns unchanged",
         %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
      # PR-6+7 — a flavor that declares no :instance_behaviors thunk direct-spawns
      # with :behaviors OMITTED, so the Kind's nil-capture default set applies.
      # This pins that the curl fix did not perturb the generic direct-spawn path.
      # (py-agent P4: was the deleted `np` dedicated-Kind flavor; re-pointed to
      # `native`, the surviving direct-spawn flavor with the same no-thunk shape.)
      if not function_exported?(Ezagent.SpawnRegistry, :registered_schemes, 0) or
           "entity" not in Ezagent.SpawnRegistry.registered_schemes() or
           :error == Ezagent.AgentFlavorRegistry.lookup("native") do
        IO.puts(
          :stderr,
          "SKIP: entity scheme / native flavor not registered (bootstrap incomplete)"
        )

        :ok
      else
        name = "native-#{System.unique_integer([:positive])}"
        expected_uri = Ezagent.URI.agent(ws_name, name)

        assert {:ok, %{agent_uri: agent_uri, template_name: nil}} =
                 Workspace.create_agent(
                   workspace_uri,
                   %{flavor: "native", name: name, cwd: "", with_pty: false},
                   admin_ctx
                 )

        assert agent_uri == expected_uri
        assert {:ok, "native"} = Ezagent.UriQuery.resolve(:flavor, agent_uri)
        assert {:ok, _pid} = Ezagent.KindRegistry.lookup(agent_uri)
        # native is NOT a curl agent — no :curl_agent slice pollution. (Kind.spawn
        # inside create_agent awaited :ready, so the slice set is settled.)
        assert {:ok, nil} = Ezagent.Kind.get_slice(agent_uri, :curl_agent)
      end
    end

    @tag :integration
    test "creator receives an agent-scoped Manage cap after direct-spawn create_agent", %{
      ws_name: ws_name,
      workspace_uri: workspace_uri
    } do
      if not function_exported?(Ezagent.SpawnRegistry, :registered_schemes, 0) or
           "entity" not in Ezagent.SpawnRegistry.registered_schemes() do
        IO.puts(:stderr, "SKIP: entity spawn fn not registered (test bootstrap incomplete)")
        :ok
      else
        creator_uri =
          URI.new!("entity://#{ws_name}/user/agent-creator-#{System.unique_integer([:positive])}")

        create_cap =
          Ezagent.Capability.cap(
            :workspace,
            Ezagent.ActionSet.Workspace,
            :create_agent,
            workspace_uri,
            workspace_uri
          )

        create_cap = signed_cap!(workspace_uri, creator_uri, create_cap)

        {:ok, _pid} =
          Ezagent.Kind.spawn(User, %{
            uri: creator_uri,
            initial_caps: MapSet.new([create_cap])
          })

        name = "managed-#{System.unique_integer([:positive])}"

        assert {:ok, %{agent_uri: agent_uri, template_name: nil}} =
                 Workspace.create_agent(
                   workspace_uri,
                   %{flavor: "curl", name: name, cwd: "", with_pty: false},
                   %{caller: creator_uri, caps: Ezagent.Identity.list_caps_for(creator_uri)}
                 )

        assert creator_has_manage_cap?(creator_uri, :agent, agent_uri, workspace_uri)
      end
    end
  end

  defp creator_has_manage_cap?(creator_uri, kind, instance_uri, workspace_uri) do
    creator_uri
    |> Ezagent.Identity.list_caps_for()
    |> Enum.any?(fn
      %Ezagent.Capability{} = cap ->
        cap.kind == kind and
          cap.behavior == Ezagent.ActionSet.Manage and
          cap.action == :any and
          URI.to_string(cap.instance) == URI.to_string(instance_uri) and
          URI.to_string(cap.workspace_uri) == URI.to_string(workspace_uri) and
          URI.to_string(cap.granted_by) == URI.to_string(User.admin_uri())

      _ ->
        false
    end)
  end

  defp terminate_agent(agent_uri) do
    _ = Ezagent.PendingDelivery.flush(agent_uri)

    case Ezagent.KindRegistry.lookup(agent_uri) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid), do: Ezagent.Kind.terminate(agent_uri)

      _ ->
        :ok
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
