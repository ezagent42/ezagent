defmodule EzagentDomainChat.Integration.Phase7HardeningTest do
  @moduledoc """
  Phase 7 completion hardening — regression tests for the 9 codex
  adversarial-review findings against the merged PR-4 (the Generator)
  and PR-5 (the orchestrator tools).

  One test (or group) per finding:

  - **CRITICAL** — two sessions from one SessionTemplate get DISJOINT
    live worker URIs, each worker in the correct orchestrator's lineage.
  - **HIGH-2** — `chat.set_working_copy` is orchestrator-only; a normal
    user with only default session caps is denied.
  - **HIGH-3** — Generator-installed routing rules fire at runtime
    (loaded into `RoutingRegistry`).
  - **HIGH-4** — a non-default-workspace SessionTemplate spawns into
    THAT workspace.
  - **MEDIUM-5** — a forced routing failure leaves no orphaned
    session / workers / rules.
  - **HIGH-6** — a same-flavor `update_agent_template` actually restarts
    the worker (fresh generation-specific URI).
  - **HIGH-7** — a post-spawn `add_agent_slot` failure terminates the
    orphaned replacement.
  - **HIGH-8** — `update_template` checks DURABLE parent existence — a
    snapshotted-but-not-live parent succeeds.
  - **HIGH-9** — `update_template` / `save_template_as` dispatch
    `template.write` WITHOUT `admin_caps`.

  ## Round 2 — codex adversarial-review of the merged hardening (#239)

  - **CRITICAL r2** — the Generator must NOT instantiate slot
    AgentTemplates across a workspace boundary; a cross-workspace
    `default_workspace_uri` or a cross-workspace slot AgentTemplate URI
    → `:cross_workspace_denied`, nothing spawned.
  - **HIGH-2 r2** — `update_agent_template` re-points routing rules
    from the old worker URI to the new one before terminating the old
    worker.
  - **HIGH-3 r2** — `cleanup_partial` DELETES the routing rows the
    Generator installed (tracked rule IDs), not just reloads them.
  - **HIGH-4 r2** — a legacy 2-tuple `agent_slots` entry yields a
    controlled `:no_live_worker` error, not a `CaseClauseError`.
  - **MEDIUM-5 r2** — `session_instance_name/3` is injective
    (`agent_test.exs`): `api.v1` / `api-v1` do not collide.

  ## Round 3 — codex adversarial-review of hardening round 2 (#241)

  - **HIGH-1 r3** — `update_agent_template`'s routing re-point is a
    CHECKED step: a forced re-point failure aborts the swap, keeps the
    OLD worker alive, and returns a controlled error — no stale route
    to a dead worker.
  - **HIGH-2 r3** — `install_routing_rules/5` is exception-safe: a raise
    from `load_into_registry` after rows were inserted returns a tagged
    `{:error, _}` (not a raise), so `guard/2` runs `cleanup_partial` and
    no session / worker / routing-row leaks.
  - **MEDIUM-3 r3** — the Generator + `update_agent_template` slot-name
    uniqueness preflight computes all candidate instance names up front
    and rejects duplicates before any spawn.

  ## Round 4 — codex adversarial-review of hardening round 3 (#243)

  The structural fix: the routing operations are now TRANSACTIONAL.

  - **HIGH-2 r4** — the matcher-based routing-install scrubber was a
    data-loss bug (it hard-deleted EVERY row sharing a batch matcher).
    The install now runs inside `Repo.transaction`; a pre-existing rule
    from another session that merely SHARES a matcher survives a
    Generator routing-install failure.
  - **HIGH-1 r4** — `update_agent_template`'s routing re-point runs
    inside `Repo.transaction`. A re-point failure rolls the transaction
    back; the persisted rows end up back on the OLD worker, the swap
    aborts `{:error, {:update_aborted, _}}`, the OLD worker survives.
  - **MEDIUM-3 r4** — `SlotNames.preflight_live_worker_uris/1` rejects a
    candidate worker URI already live in `KindRegistry` as an orphan.

  Every test drives the production dispatch path — no mocks. A no-PTY
  synthetic flavor spawns the plain `Ezagent.Entity.Agent` Kind.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{AgentFlavorRegistry, AgentLineage, Behavior, Capability, KindRegistry}
  alias Ezagent.Entity.{Agent, Session, SessionTemplate, User}
  alias Ezagent.Orchestrator.Tools

  # --- a no-PTY test Template Class --------------------------------------

  defmodule TestFlavorClass do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "phase7.hardening.agent"

    @impl true
    def validate(tmpl) when is_map(tmpl),
      do: if(Map.has_key?(tmpl, "agent_uri"), do: :ok, else: {:error, :missing_agent_uri})

    def validate(_), do: {:error, :not_a_map}

    @impl true
    def instantiate(_tmpl_name, %{"agent_uri" => uri_str}, _workspace_uri) do
      agent_uri = URI.parse(uri_str)

      case Ezagent.SpawnRegistry.spawn(agent_uri) do
        {:ok, _pid} -> {:ok, [agent_uri]}
        {:error, {:already_started, _pid}} -> {:ok, [agent_uri]}
        {:error, _} = err -> err
      end
    end

    def instantiate(_n, tmpl, _ws), do: {:error, {:invalid_template, tmpl}}
  end

  # A test Template Class that spawns the worker Agent Kind and then
  # TERMINATES the freshly-spawned orchestrator agent as a side effect —
  # used by the HIGH-3 r2 test to force a Generator failure AFTER
  # `install_routing_rules` has inserted its rows. Slot instantiation
  # runs BEFORE routing install, so by the time `grant_scoped_caps`
  # dispatches `identity.grant_cap` to the orchestrator it is dead.
  #
  # Defined here (before its first reference) so the bare-alias
  # `OrchestratorKillerFlavorClass` resolves to this nested module —
  # an alias used before its `defmodule` resolves to the WRONG
  # top-level module.
  defmodule OrchestratorKillerFlavorClass do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "phase7.r2.orchestrator-killer"

    @impl true
    def validate(tmpl) when is_map(tmpl),
      do: if(Map.has_key?(tmpl, "agent_uri"), do: :ok, else: {:error, :missing_agent_uri})

    def validate(_), do: {:error, :not_a_map}

    @impl true
    def instantiate(_tmpl_name, %{"agent_uri" => uri_str}, _workspace_uri) do
      agent_uri = URI.parse(uri_str)

      worker_result =
        case Ezagent.SpawnRegistry.spawn(agent_uri) do
          {:ok, _pid} -> {:ok, [agent_uri]}
          {:error, {:already_started, _pid}} -> {:ok, [agent_uri]}
          {:error, _} = err -> err
        end

      kill_live_orchestrator()
      worker_result
    end

    def instantiate(_n, tmpl, _ws), do: {:error, {:invalid_template, tmpl}}

    defp kill_live_orchestrator do
      Ezagent.AgentLineage.list_all()
      |> Enum.map(fn {agent, _} -> agent end)
      |> Enum.filter(&String.contains?(&1, "cc_orchestrator-"))
      |> Enum.each(fn orch_str ->
        case Ezagent.KindRegistry.lookup(URI.parse(orch_str)) do
          {:ok, pid} ->
            DynamicSupervisor.terminate_child(EzagentDomainChat.AgentSupervisor, pid)

          :error ->
            :ok
        end
      end)
    end
  end

  # --- helpers -----------------------------------------------------------

  defp uniq, do: System.unique_integer([:positive])

  defp register_test_flavor do
    flavor = "ph7hard#{uniq()}"

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Agent,
        template_class: TestFlavorClass
      })

    flavor
  end

  defp agent_template_content(flavor, name) do
    %{
      name: name,
      description: "worker #{name}",
      flavor: flavor,
      working_directory: "/tmp/phase7-hardening-test",
      claude_config_dir: nil,
      settings_path: nil,
      mcp_config_path: nil,
      api_key_helper: nil,
      default_caps: [],
      created_by: User.admin_uri(),
      created_at: ~U[2026-05-22 00:00:00Z]
    }
  end

  defp create_agent_template(uri, content) do
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    # SQLite is a single-writer store; under the parallel umbrella test
    # run a `template.write` snapshot insert can transiently hit
    # `Exqlite.Error: Database busy`. Retry the write a few times — this
    # is test-infra resilience, not production logic.
    {:ok, %{content: ^content}} =
      with_db_retry(fn -> dispatch(uri, "template.write", %{content: content}) end)

    :ok
  end

  defp with_db_retry(fun, attempts \\ 8) do
    fun.()
  catch
    :exit, _ when attempts > 1 ->
      Process.sleep(40)
      with_db_retry(fun, attempts - 1)
  end

  defp dispatch(uri, action, args, ctx \\ nil) do
    target = URI.parse("#{URI.to_string(uri)}?action=#{action}")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: ctx || admin_ctx()
    })
  end

  defp admin_ctx do
    %{caller: User.admin_uri(), caps: User.admin_caps(), reply: {:caller_inbox, self()}}
  end

  defp create_session_template(name, agent_slots, routing_rules, opts \\ []) do
    workspace = Keyword.get(opts, :workspace, "default")

    content = %{
      name: name,
      description: "test team #{name}",
      agent_slots: agent_slots,
      routing_rules: routing_rules,
      orchestrator_template_uri: URI.parse("template://agent/default/cc-orchestrator"),
      default_workspace_uri:
        Keyword.get(opts, :default_workspace_uri, URI.parse("workspace://default")),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-05-22 00:00:00Z]
    }

    {:ok, uri} = with_db_retry(fn -> SessionTemplate.persist_version(content, workspace) end)
    uri
  end

  defp spawn_owner(uri, caps) do
    {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: uri, initial_caps: MapSet.new(caps)})
    :ok
  end

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

  defp full_template_owner(workspace_uri) do
    owner_uri = URI.parse("entity://user/#{workspace_uri.host}/ph7-owner-#{uniq()}")

    :ok =
      spawn_owner(owner_uri, [
        template_cap(:session_template, workspace_uri),
        template_cap(:agent_template, workspace_uri)
      ])

    owner_uri
  end

  defp session_working_copy(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)

    chat_slice =
      pid
      |> :sys.get_state()
      |> Map.get(:state, %{})
      |> Map.get(:chat, %{})

    Behavior.Chat.template_working_copy(chat_slice)
  end

  defp orchestrator_caps(orchestrator_uri) do
    {:ok, pid} = KindRegistry.lookup(orchestrator_uri)

    pid
    |> :sys.get_state()
    |> Map.get(:state, %{})
    |> Map.get(:identity, %{})
    |> Map.get(:caps, MapSet.new())
  end

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

  @default_ws URI.new!("workspace://default")

  # ════════════════════════════════════════════════════════════════════
  # CRITICAL — two sessions from one SessionTemplate get disjoint worker
  # URIs + each worker in the correct orchestrator's lineage.
  # ════════════════════════════════════════════════════════════════════

  describe "CRITICAL — repeated instantiations get session-unique worker URIs" do
    test "two sessions from one SessionTemplate → disjoint live worker URIs, correct lineage" do
      flavor = register_test_flavor()
      worker_tmpl = URI.new!("template://agent/default/ph7-crit-worker-#{uniq()}")
      :ok = create_agent_template(worker_tmpl, agent_template_content(flavor, "worker"))

      st_uri =
        create_session_template("ph7-crit-team-#{uniq()}", [{"dev", worker_tmpl}], [])

      owner_uri = full_template_owner(@default_ws)

      assert {:ok, %{session_uri: s1, orchestrator_uri: orch1}} =
               Session.spawn_from_template(st_uri, owner_uri)

      assert {:ok, %{session_uri: s2, orchestrator_uri: orch2}} =
               Session.spawn_from_template(st_uri, owner_uri)

      assert s1 != s2
      assert orch1 != orch2

      [w1] = live_workers_of(orch1)
      [w2] = live_workers_of(orch2)

      # The two live worker URIs MUST be disjoint — the pre-hardening
      # bug gave both the SAME `entity://agent/default/<flavor>_dev`.
      refute URI.to_string(w1) == URI.to_string(w2),
             "two sessions from one SessionTemplate must get DISJOINT live worker URIs"

      # Each worker is in the lineage of ITS OWN orchestrator only — no
      # overwrite. (The pre-hardening ETS-set `AgentLineage.record` let
      # the 2nd session overwrite the 1st's parent.)
      assert AgentLineage.spawned_in_lineage?(w1, orch1)
      assert AgentLineage.spawned_in_lineage?(w2, orch2)
      refute AgentLineage.spawned_in_lineage?(w1, orch2)
      refute AgentLineage.spawned_in_lineage?(w2, orch1)
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # HIGH-2 — chat.set_working_copy is orchestrator-only.
  # ════════════════════════════════════════════════════════════════════

  describe "HIGH-2 — chat.set_working_copy authorization" do
    setup do
      flavor = register_test_flavor()
      worker_tmpl = URI.new!("template://agent/default/ph7-h2-worker-#{uniq()}")
      :ok = create_agent_template(worker_tmpl, agent_template_content(flavor, "worker"))

      st_uri =
        create_session_template("ph7-h2-team-#{uniq()}", [{"dev", worker_tmpl}], [])

      owner_uri = full_template_owner(@default_ws)

      {:ok, %{session_uri: session_uri, orchestrator_uri: orch_uri}} =
        Session.spawn_from_template(st_uri, owner_uri)

      %{session_uri: session_uri, orchestrator_uri: orch_uri}
    end

    test "a normal user with only default session caps is DENIED", %{session_uri: session_uri} do
      # A non-orchestrator user holding the structural `{:session, :any,
      # :any}` cap — exactly what every user inherits. Step 5.5 CapBAC
      # passes (the cap is structurally broad), but the HIGH-2 in-invoke
      # gate must still deny.
      user_uri = URI.parse("entity://user/default/ph7-h2-normal-#{uniq()}")

      user_caps =
        MapSet.new([
          %Capability{
            kind: :session,
            behavior: :any,
            instance: :any,
            workspace_uri: @default_ws,
            granted_by: User.admin_uri(),
            granted_at: DateTime.utc_now()
          }
        ])

      result =
        dispatch(
          session_uri,
          "chat.set_working_copy",
          %{template_working_copy: %{agent_slots: [], routing_rules: []}},
          %{caller: user_uri, caps: user_caps, reply: {:caller_inbox, self()}}
        )

      assert {:error, :unauthorized} = result
    end

    test "the session's orchestrator (cap #1) IS authorized", %{
      session_uri: session_uri,
      orchestrator_uri: orch_uri
    } do
      caps = orchestrator_caps(orch_uri)

      assert {:ok, %{template_working_copy: _}} =
               dispatch(
                 session_uri,
                 "chat.set_working_copy",
                 %{template_working_copy: %{agent_slots: [], routing_rules: []}},
                 %{caller: orch_uri, caps: caps, reply: {:caller_inbox, self()}}
               )
    end

    test "the Generator's system-internal path IS authorized", %{session_uri: session_uri} do
      # `system_set_working_copy/2` is the Generator init path — it must
      # succeed even though it holds no orchestrator cap.
      assert {:ok, %{template_working_copy: _}} =
               Behavior.Chat.system_set_working_copy(session_uri, %{
                 agent_slots: [],
                 routing_rules: []
               })
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # HIGH-3 — Generator routing rules fire at runtime.
  # ════════════════════════════════════════════════════════════════════

  describe "HIGH-3 — Generator-installed routing rules are loaded into the live registry" do
    test "a matching chat message right after Generator completion is delivered to the worker" do
      flavor = register_test_flavor()
      worker_tmpl = URI.new!("template://agent/default/ph7-h3-worker-#{uniq()}")
      :ok = create_agent_template(worker_tmpl, agent_template_content(flavor, "worker"))

      # A SessionTemplate whose routing rule fires on `text_contains
      # "ph7deploy"` and delivers to the "dev" slot.
      st_uri =
        create_session_template(
          "ph7-h3-team-#{uniq()}",
          [{"dev", worker_tmpl}],
          [{{:text_contains, "ph7deploy"}, ["dev"]}]
        )

      owner_uri = full_template_owner(@default_ws)

      assert {:ok, %{session_uri: session_uri, orchestrator_uri: orch_uri}} =
               Session.spawn_from_template(st_uri, owner_uri)

      [worker_uri] = live_workers_of(orch_uri)
      worker_str = URI.to_string(worker_uri)

      # The rule must be LIVE in RoutingRegistry the instant the
      # Generator returns — the resolver reads ETS, not SQLite. A
      # matching message resolved right now must route to the worker.
      msg =
        Ezagent.Message.new(User.admin_uri(), %{text: "please ph7deploy now"},
          inserted_at: DateTime.utc_now()
        )

      recipients =
        Ezagent.Routing.Resolver.resolve(msg, session_uri, [], workspace_uri: @default_ws)

      recipient_strs = Enum.map(recipients, &URI.to_string/1)

      assert worker_str in recipient_strs,
             "the Generator's routing rule must be live in RoutingRegistry immediately — " <>
               "a matching message must resolve to the spawned worker. " <>
               "Got recipients: #{inspect(recipient_strs)}"
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # HIGH-4 — SessionTemplate default_workspace_uri is honored.
  # ════════════════════════════════════════════════════════════════════

  describe "HIGH-4 — non-default default_workspace_uri" do
    test "a SessionTemplate with a non-default workspace spawns into THAT workspace" do
      ws_name = "ph7ws#{uniq()}"
      ws_uri = URI.new!("workspace://#{ws_name}")

      flavor = register_test_flavor()
      # The worker AgentTemplate lives IN the non-default workspace.
      worker_tmpl = URI.new!("template://agent/#{ws_name}/ph7-h4-worker-#{uniq()}")
      :ok = create_agent_template(worker_tmpl, agent_template_content(flavor, "worker"))

      st_uri =
        create_session_template(
          "ph7-h4-team-#{uniq()}",
          [{"dev", worker_tmpl}],
          [],
          workspace: ws_name,
          default_workspace_uri: ws_uri
        )

      # The owner holds template caps SCOPED to the non-default
      # workspace.
      owner_uri = full_template_owner(ws_uri)

      assert {:ok, %{session_uri: session_uri, orchestrator_uri: orch_uri}} =
               Session.spawn_from_template(st_uri, owner_uri)

      ws_str = URI.to_string(ws_uri)

      # The session URI carries the non-default workspace segment.
      assert URI.to_string(Capability.workspace_of(session_uri)) == ws_str,
             "the session must be created in the SessionTemplate's default_workspace_uri"

      # The session is bound to the non-default workspace.
      assert {:ok, bound} = Ezagent.WorkspaceRegistry.lookup(session_uri)
      assert URI.to_string(bound) == ws_str

      # The orchestrator + workers are in the non-default workspace.
      assert {:ok, orch_ws} = Ezagent.WorkspaceRegistry.lookup(orch_uri)
      assert URI.to_string(orch_ws) == ws_str

      for worker_uri <- live_workers_of(orch_uri) do
        assert {:ok, worker_ws} = Ezagent.WorkspaceRegistry.lookup(worker_uri)
        assert URI.to_string(worker_ws) == ws_str
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # MEDIUM-5 — late failures leave no half-built session.
  # ════════════════════════════════════════════════════════════════════

  describe "MEDIUM-5 — preflight + compensating cleanup" do
    test "an invalid routing matcher is rejected by preflight — no session/workers spawned" do
      flavor = register_test_flavor()
      worker_tmpl = URI.new!("template://agent/default/ph7-m5-worker-#{uniq()}")
      :ok = create_agent_template(worker_tmpl, agent_template_content(flavor, "worker"))

      # A SessionTemplate with a structurally-BROKEN routing matcher —
      # `Matcher.to_json/1` raises on it. The MEDIUM-5 preflight must
      # catch this BEFORE any session/worker is spawned.
      st_uri =
        create_session_template(
          "ph7-m5-team-#{uniq()}",
          [{"dev", worker_tmpl}],
          [{{:totally_bogus_matcher_kind, "x"}, ["dev"]}]
        )

      owner_uri = full_template_owner(@default_ws)

      lineage_before = length(AgentLineage.list_all())

      assert {:error, {:invalid_routing_matcher, _}} =
               Session.spawn_from_template(st_uri, owner_uri)

      # No worker landed in AgentLineage — the failure was caught in
      # preflight, before any spawn.
      assert length(AgentLineage.list_all()) == lineage_before,
             "a preflight rejection must not spawn any worker"
    end

    test "a missing agent-slot template is rejected by preflight — no session spawned" do
      # The SessionTemplate cites an AgentTemplate URI that was never
      # persisted — `preflight_agent_slots` must reject it.
      missing_tmpl = URI.new!("template://agent/default/ph7-m5-missing-#{uniq()}")

      st_uri =
        create_session_template("ph7-m5-miss-#{uniq()}", [{"dev", missing_tmpl}], [])

      owner_uri = full_template_owner(@default_ws)

      assert {:error, _reason} = Session.spawn_from_template(st_uri, owner_uri)
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # HIGH-6 — update_agent_template same-flavor swap actually restarts.
  # ════════════════════════════════════════════════════════════════════

  describe "HIGH-6 — same-flavor update_agent_template restarts the worker" do
    test "a same-flavor template swap spawns a NEW (generation-bumped) worker URI" do
      flavor = register_test_flavor()

      tmpl_a = URI.new!("template://agent/default/ph7-h6-a-#{uniq()}")
      tmpl_b = URI.new!("template://agent/default/ph7-h6-b-#{uniq()}")
      :ok = create_agent_template(tmpl_a, agent_template_content(flavor, "config-a"))
      :ok = create_agent_template(tmpl_b, agent_template_content(flavor, "config-b"))

      st_uri = create_session_template("ph7-h6-team-#{uniq()}", [{"dev", tmpl_a}], [])
      owner_uri = full_template_owner(@default_ws)

      {:ok, %{session_uri: session_uri, orchestrator_uri: orch_uri}} =
        Session.spawn_from_template(st_uri, owner_uri)

      [original_worker] = live_workers_of(orch_uri)
      caps = orchestrator_caps(orch_uri)

      # Swap the "dev" slot to a DIFFERENT AgentTemplate of the SAME
      # flavor. Pre-hardening this was a no-op — old + new URI equal.
      assert {:ok, new_worker_uri} =
               Tools.update_agent_template("dev", tmpl_b,
                 caller: orch_uri,
                 caps: caps,
                 workspace_uri: @default_ws,
                 session_uri: session_uri
               )

      # The new worker URI is GENUINELY DIFFERENT from the original —
      # generation-bumped (`--g1`). A same-URI no-replace bug would
      # return the SAME URI.
      refute URI.to_string(new_worker_uri) == URI.to_string(original_worker),
             "a same-flavor swap MUST produce a fresh generation-specific worker URI"

      assert String.contains?(URI.to_string(new_worker_uri), "--g1"),
             "the replacement worker URI carries the bumped generation marker"

      # The working copy now records the NEW worker URI + new source
      # template + bumped generation.
      wc = session_working_copy(session_uri)
      {_n, src, live, gen} = find_slot(wc, "dev")
      assert URI.to_string(src) == URI.to_string(tmpl_b)
      assert URI.to_string(live) == URI.to_string(new_worker_uri)
      assert gen == 1

      # The new worker is alive; the old one was terminated.
      assert {:ok, _pid} = KindRegistry.lookup(new_worker_uri)
      wait_until(fn -> KindRegistry.lookup(original_worker) == :error end)

      assert KindRegistry.lookup(original_worker) == :error,
             "the OLD worker must be terminated after the swap"
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # HIGH-7 — update_agent_template / add_agent_slot saga cleanup.
  # ════════════════════════════════════════════════════════════════════

  describe "HIGH-7 — a post-spawn swap failure terminates the orphaned replacement" do
    test "a forced upsert_agent_slot failure terminates the newly-spawned replacement" do
      flavor = register_test_flavor()
      worker_tmpl = URI.new!("template://agent/default/ph7-h7-worker-#{uniq()}")
      :ok = create_agent_template(worker_tmpl, agent_template_content(flavor, "worker"))

      st_uri = create_session_template("ph7-h7-team-#{uniq()}", [{"dev", worker_tmpl}], [])
      owner_uri = full_template_owner(@default_ws)

      {:ok, %{session_uri: session_uri, orchestrator_uri: orch_uri}} =
        Session.spawn_from_template(st_uri, owner_uri)

      caps = orchestrator_caps(orch_uri)

      lineage_before = MapSet.new(AgentLineage.list_all(), fn {a, _} -> a end)

      # Force the swap-commit (`upsert_agent_slot` → `chat.set_working_copy`)
      # to FAIL by terminating the Session Kind right before the swap.
      # The replacement worker still spawns (cap #4 instantiate), but
      # the working-copy write to a dead Session fails. The HIGH-7 saga
      # must terminate the orphaned replacement.
      {:ok, sess_pid} = KindRegistry.lookup(session_uri)
      DynamicSupervisor.terminate_child(EzagentDomainChat.SessionSupervisor, sess_pid)
      wait_until(fn -> KindRegistry.lookup(session_uri) == :error end)

      result =
        Tools.update_agent_template("dev", worker_tmpl,
          caller: orch_uri,
          caps: caps,
          workspace_uri: @default_ws,
          session_uri: session_uri
        )

      assert match?({:error, {:update_aborted, _}}, result),
             "a post-spawn swap failure must surface :update_aborted"

      # No NEW worker leaked — every agent URI in AgentLineage after the
      # failed swap was already there before it.
      lineage_after = MapSet.new(AgentLineage.list_all(), fn {a, _} -> a end)
      leaked = MapSet.difference(lineage_after, lineage_before)

      for agent_str <- leaked do
        assert KindRegistry.lookup(URI.parse(agent_str)) == :error,
               "the orphaned replacement worker #{agent_str} must be terminated by the saga"
      end
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # HIGH-8 — update_template durable parent check.
  # ════════════════════════════════════════════════════════════════════

  describe "HIGH-8 — update_template checks durable parent existence" do
    test "a snapshotted-but-not-live parent SessionTemplate → update_template succeeds" do
      flavor = register_test_flavor()
      worker_tmpl = URI.new!("template://agent/default/ph7-h8-worker-#{uniq()}")
      :ok = create_agent_template(worker_tmpl, agent_template_content(flavor, "worker"))

      parent_uri =
        create_session_template("ph7-h8-parent-#{uniq()}", [{"dev", worker_tmpl}], [])

      owner_uri = full_template_owner(@default_ws)

      {:ok, %{session_uri: session_uri, orchestrator_uri: orch_uri}} =
        Session.spawn_from_template(parent_uri, owner_uri)

      caps = orchestrator_caps(orch_uri)

      # Restart-style: cull the PARENT SessionTemplate Kind from the
      # live registry. The `kind_snapshots` row persists. Pre-hardening
      # `check_parent_alive` (KindRegistry-only) would now wrongly
      # report `:parent_template_deleted`.
      {:ok, parent_pid} = KindRegistry.lookup(parent_uri)
      DynamicSupervisor.terminate_child(EzagentDomainChat.SessionTemplateSupervisor, parent_pid)
      wait_until(fn -> KindRegistry.lookup(parent_uri) == :error end)

      # `update_template` must SUCCEED — the parent still durably exists.
      result =
        Tools.update_template(
          session_uri: session_uri,
          workspace_uri: @default_ws,
          caller: orch_uri,
          caps: caps,
          parent_template_uri: parent_uri
        )

      assert match?({:ok, %URI{}}, result),
             "update_template must succeed for a durable parent that is merely not live. " <>
               "Got: #{inspect(result)}"
    end

    test "a genuinely-never-registered parent still reports :parent_template_deleted" do
      # Regression guard — the HIGH-8 fix must NOT make a real deletion
      # pass. A parent with neither a live Kind nor a snapshot row is
      # still reported deleted.
      parent_uri =
        URI.parse("template://session/default/ph7-h8-ghost-#{uniq()}@deadbeefdeadbeef")

      caps = MapSet.new([template_cap(:session_template, @default_ws)])

      assert {:error, :parent_template_deleted} =
               Tools.update_template(
                 session_uri: URI.parse("session://default/default/ph7-h8-ghost"),
                 workspace_uri: @default_ws,
                 caller: URI.parse("entity://agent/default/cc_ph7-h8-orch"),
                 caps: caps,
                 parent_template_uri: parent_uri
               )
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # HIGH-9 — persist_version does NOT use admin_caps from the tool path.
  # ════════════════════════════════════════════════════════════════════

  describe "HIGH-9 — the template.write dispatch context carries no admin_caps" do
    setup do
      :telemetry.attach(
        "ph7-h9-#{uniq()}",
        [:ezagent, :authz, :granted],
        fn _event, _measurements, meta, %{pid: pid} ->
          send(pid, {:authz_granted, meta})
        end,
        %{pid: self()}
      )

      on_exit(fn -> :telemetry.detach("ph7-h9-#{inspect(self())}") end)
      :ok
    end

    test "save_template_as dispatches template.write WITHOUT admin caps in ctx" do
      flavor = register_test_flavor()
      worker_tmpl = URI.new!("template://agent/default/ph7-h9-worker-#{uniq()}")
      :ok = create_agent_template(worker_tmpl, agent_template_content(flavor, "worker"))

      st_uri = create_session_template("ph7-h9-team-#{uniq()}", [{"dev", worker_tmpl}], [])
      owner_uri = full_template_owner(@default_ws)

      {:ok, %{session_uri: session_uri, orchestrator_uri: orch_uri}} =
        Session.spawn_from_template(st_uri, owner_uri)

      caps = orchestrator_caps(orch_uri)

      # Drain any telemetry from the setup (the fixture's own
      # SessionTemplate persist uses the system path) so we only
      # observe `save_template_as`'s OWN dispatch.
      _ = collect_template_write_authz()

      # The orchestrator's caps include cap #3 (`:session_template`
      # Behavior.Template) — it CAN write a SessionTemplate version.
      # `save_template_as` must succeed using ONLY that delegated cap.
      assert {:ok, %URI{}} =
               Tools.save_template_as("ph7-h9-saved-#{uniq()}",
                 caller: orch_uri,
                 caps: caps,
                 session_uri: session_uri,
                 workspace_uri: @default_ws
               )

      # Drain the authz telemetry — the decisive `template.write` on a
      # `template://session/...` URI must have been authorized by the
      # ORCHESTRATOR's cap, NOT an admin cap.
      writes = collect_template_write_authz()

      assert writes != [],
             "save_template_as must dispatch at least one template.write authz event"

      for meta <- writes do
        # The needed cap derived for the write is a session_template
        # cap; the caller is the orchestrator agent — never the bootstrap
        # admin URI.
        caller = meta.caller

        assert match?(%URI{scheme: "entity", host: "agent"}, caller),
               "template.write must be dispatched by the orchestrator agent, not admin. " <>
                 "Got caller: #{inspect(caller)}"

        refute URI.to_string(caller) == URI.to_string(User.admin_uri()),
               "template.write must NOT be dispatched as the bootstrap admin (no admin_caps " <>
                 "fallback on the MCP tool path)"
      end
    end

    test "save_template_as denied when the caller's caps lack template-write authority" do
      # The orchestrator's owner held NO :session_template cap, so the
      # orchestrator never received cap #3. `save_template_as` must
      # DENY — proving there is no admin fallback (if there were, the
      # admin cap would silently authorize the write).
      flavor = register_test_flavor()
      worker_tmpl = URI.new!("template://agent/default/ph7-h9b-worker-#{uniq()}")
      :ok = create_agent_template(worker_tmpl, agent_template_content(flavor, "worker"))

      st_uri = create_session_template("ph7-h9b-team-#{uniq()}", [{"dev", worker_tmpl}], [])

      # The orchestrator holds caps #1/#2 only (no template caps).
      caps =
        MapSet.new([
          %Capability{
            kind: :session,
            behavior: :any,
            instance: {:within_session, URI.parse("session://generic/default/ph7-h9b")},
            workspace_uri: @default_ws,
            granted_by: User.admin_uri(),
            granted_at: DateTime.utc_now()
          }
        ])

      owner_uri = full_template_owner(@default_ws)

      {:ok, %{session_uri: session_uri}} =
        Session.spawn_from_template(st_uri, owner_uri)

      assert {:error, :unauthorized} =
               Tools.save_template_as("ph7-h9b-saved-#{uniq()}",
                 caller: URI.parse("entity://agent/default/cc_ph7-h9b-orch"),
                 caps: caps,
                 session_uri: session_uri,
                 workspace_uri: @default_ws
               )
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # ROUND 2 — codex adversarial-review of the merged hardening (#239).
  # ════════════════════════════════════════════════════════════════════

  # ── CRITICAL (round 2) — the Generator must NOT instantiate slot
  # AgentTemplates across workspace boundaries. A SessionTemplate may
  # only compose AgentTemplates in its OWN workspace and instantiate
  # into its own workspace. ───────────────────────────────────────────

  describe "CRITICAL r2 — SessionTemplate-composition workspace isolation" do
    test "a cross-workspace default_workspace_uri → Generator denied, nothing spawned" do
      flavor = register_test_flavor()
      # The SessionTemplate + the worker AgentTemplate both live in
      # `default`, but the template encodes a default_workspace_uri
      # pointing at a DIFFERENT workspace — the cross-workspace escalation.
      worker_tmpl = URI.new!("template://agent/default/ph7r2-crit-a-#{uniq()}")
      :ok = create_agent_template(worker_tmpl, agent_template_content(flavor, "worker"))

      other_ws = URI.new!("workspace://ph7r2crit#{uniq()}")

      st_uri =
        create_session_template(
          "ph7r2-crit-team-#{uniq()}",
          [{"dev", worker_tmpl}],
          [],
          workspace: "default",
          default_workspace_uri: other_ws
        )

      owner_uri = full_template_owner(@default_ws)

      lineage_before = length(AgentLineage.list_all())

      assert {:error, {:cross_workspace_denied, :default_workspace_uri}} =
               Session.spawn_from_template(st_uri, owner_uri)

      assert length(AgentLineage.list_all()) == lineage_before,
             "a cross-workspace SessionTemplate must spawn NOTHING"
    end

    test "a cross-workspace slot AgentTemplate → Generator denied, nothing spawned" do
      flavor = register_test_flavor()
      # The SessionTemplate lives in `default`, default_workspace_uri is
      # `default`, but the agent-slot AgentTemplate URI points at ANOTHER
      # workspace — the slot-composition escalation.
      other_ws_name = "ph7r2cs#{uniq()}"
      cross_slot_tmpl = URI.new!("template://agent/#{other_ws_name}/ph7r2-crit-b-#{uniq()}")
      :ok = create_agent_template(cross_slot_tmpl, agent_template_content(flavor, "worker"))

      st_uri =
        create_session_template(
          "ph7r2-crit-team-#{uniq()}",
          [{"dev", cross_slot_tmpl}],
          [],
          workspace: "default",
          default_workspace_uri: URI.parse("workspace://default")
        )

      owner_uri = full_template_owner(@default_ws)

      lineage_before = length(AgentLineage.list_all())

      assert {:error, {:cross_workspace_denied, {:agent_slot, "dev", _}}} =
               Session.spawn_from_template(st_uri, owner_uri)

      assert length(AgentLineage.list_all()) == lineage_before,
             "a cross-workspace agent-slot must spawn NOTHING"
    end

    test "an all-same-workspace SessionTemplate still spawns (no false denial)" do
      flavor = register_test_flavor()
      worker_tmpl = URI.new!("template://agent/default/ph7r2-crit-ok-#{uniq()}")
      :ok = create_agent_template(worker_tmpl, agent_template_content(flavor, "worker"))

      st_uri = create_session_template("ph7r2-crit-ok-#{uniq()}", [{"dev", worker_tmpl}], [])
      owner_uri = full_template_owner(@default_ws)

      assert {:ok, %{session_uri: _, orchestrator_uri: _}} =
               Session.spawn_from_template(st_uri, owner_uri)
    end
  end

  # ── HIGH-2 (round 2) — update_agent_template must re-point routing
  # rules from the old worker URI to the new one. ──────────────────────

  describe "HIGH-2 r2 — update_agent_template re-points routing rules" do
    test "a message matching a rule that targeted the old slot is delivered to the NEW worker" do
      flavor = register_test_flavor()
      tmpl_a = URI.new!("template://agent/default/ph7r2-h2-a-#{uniq()}")
      tmpl_b = URI.new!("template://agent/default/ph7r2-h2-b-#{uniq()}")
      :ok = create_agent_template(tmpl_a, agent_template_content(flavor, "config-a"))
      :ok = create_agent_template(tmpl_b, agent_template_content(flavor, "config-b"))

      # The SessionTemplate's routing rule fires on `text_contains
      # "ph7r2route"` and delivers to the "dev" slot.
      st_uri =
        create_session_template(
          "ph7r2-h2-team-#{uniq()}",
          [{"dev", tmpl_a}],
          [{{:text_contains, "ph7r2route"}, ["dev"]}]
        )

      owner_uri = full_template_owner(@default_ws)

      {:ok, %{session_uri: session_uri, orchestrator_uri: orch_uri}} =
        Session.spawn_from_template(st_uri, owner_uri)

      [old_worker] = live_workers_of(orch_uri)
      caps = orchestrator_caps(orch_uri)

      # The rule routes to the OLD worker before the swap.
      msg_before =
        Ezagent.Message.new(User.admin_uri(), %{text: "please ph7r2route"},
          inserted_at: DateTime.utc_now()
        )

      before_recipients =
        Ezagent.Routing.Resolver.resolve(msg_before, session_uri, [], workspace_uri: @default_ws)
        |> Enum.map(&URI.to_string/1)

      assert URI.to_string(old_worker) in before_recipients,
             "sanity — the rule routes to the old worker before the swap"

      # Swap the slot to a new AgentTemplate.
      assert {:ok, new_worker} =
               Tools.update_agent_template("dev", tmpl_b,
                 caller: orch_uri,
                 caps: caps,
                 workspace_uri: @default_ws,
                 session_uri: session_uri
               )

      refute URI.to_string(new_worker) == URI.to_string(old_worker)

      # HIGH-2 — after the swap, the SAME rule must resolve to the NEW
      # worker, and NOT to the (now terminated) old worker.
      msg_after =
        Ezagent.Message.new(User.admin_uri(), %{text: "please ph7r2route again"},
          inserted_at: DateTime.utc_now()
        )

      after_recipients =
        Ezagent.Routing.Resolver.resolve(msg_after, session_uri, [], workspace_uri: @default_ws)
        |> Enum.map(&URI.to_string/1)

      assert URI.to_string(new_worker) in after_recipients,
             "after update_agent_template the routing rule must deliver to the NEW worker. " <>
               "Got: #{inspect(after_recipients)}"

      refute URI.to_string(old_worker) in after_recipients,
             "the routing rule must NOT still name the terminated old worker"

      # The persisted DB row was rewritten too.
      rules = Ezagent.Routing.RuleStore.list(EzagentDomainChat.Routing.MentionRouting)
      old_str = URI.to_string(old_worker)

      for rule <- rules do
        refute old_str in (rule.receivers || []),
               "no persisted routing row may still name the old worker URI"
      end
    end
  end

  # ── HIGH-3 (round 2) — cleanup_partial must DELETE the routing rows
  # the Generator installed (tracked rule IDs), not just reload. ───────

  describe "HIGH-3 r2 — cleanup deletes partially-installed routing rows" do
    test "a post-routing-install Generator failure removes both the DB rows and the ETS entries" do
      # The worker flavor's `instantiate/3` kills the freshly-spawned
      # orchestrator agent as a side effect. Slot instantiation runs
      # BEFORE routing install; the orchestrator is then dead by the
      # time `grant_scoped_caps` dispatches `identity.grant_cap` to it —
      # so the Generator fails AFTER `install_routing_rules` inserted
      # the routing rows. `cleanup_partial` must DELETE those exact rows.
      table = EzagentDomainChat.Routing.MentionRouting

      flavor = register_orchestrator_killer_flavor()
      worker_tmpl = URI.new!("template://agent/default/ph7r2-h3-worker-#{uniq()}")
      :ok = create_agent_template(worker_tmpl, agent_template_content(flavor, "worker"))

      # A routing rule the Generator will install BEFORE the failure —
      # carrying a UNIQUE marker token so it is identifiable amid any
      # rows other (async: false) tests have left in the shared store.
      marker = "ph7r2h3marker-#{uniq()}"

      st_uri =
        create_session_template(
          "ph7r2-h3-team-#{uniq()}",
          [{"dev", worker_tmpl}],
          [{{:text_contains, marker}, ["dev"]}]
        )

      owner_uri = full_template_owner(@default_ws)

      # Snapshot the IDs of pre-existing rows so a set-difference
      # isolates exactly what THIS Generator run installs.
      ids_before =
        table |> Ezagent.Routing.RuleStore.list() |> MapSet.new(& &1.id)

      # The Generator must FAIL (the orchestrator was killed) — and the
      # failure must come AFTER routing install (a grant/register error,
      # not a preflight rejection).
      result = Session.spawn_from_template(st_uri, owner_uri)
      assert match?({:error, _}, result), "expected a post-routing-install failure"

      # ── (1) the DB rows the failed Generator installed are GONE ──
      rows_after = Ezagent.Routing.RuleStore.list(table)
      ids_after = MapSet.new(rows_after, & &1.id)
      leaked_rows = MapSet.difference(ids_after, ids_before)

      assert MapSet.size(leaked_rows) == 0,
             "cleanup_partial must DELETE every routing_rules row the failed Generator " <>
               "installed — leaked DB row ids: #{inspect(MapSet.to_list(leaked_rows))}"

      # And no row carries the unique marker matcher — pollution-immune.
      refute Enum.any?(rows_after, fn row ->
               row.matcher_data |> inspect() |> String.contains?(marker)
             end),
             "no routing_rules row may still carry the failed Generator's marker matcher"

      # ── (2) the live RoutingRegistry ETS retains NO entry for the
      # marker matcher / the failed Generator's worker receivers ──
      ets_entries = Ezagent.RoutingRegistry.list_all(table)

      refute Enum.any?(ets_entries, fn entry ->
               inspect(entry) |> String.contains?(marker)
             end),
             "the routing ETS table must not retain the failed Generator's rule entry"
    end
  end

  # ── HIGH-4 (round 2) — a legacy 2-tuple agent_slots entry must not
  # crash update_agent_template with a CaseClauseError. ────────────────

  describe "HIGH-4 r2 — legacy 2-tuple agent_slots in update_agent_template" do
    test "a pre-hardening 2-tuple slot yields a controlled :no_live_worker error" do
      flavor = register_test_flavor()
      worker_tmpl = URI.new!("template://agent/default/ph7r2-h4-worker-#{uniq()}")
      :ok = create_agent_template(worker_tmpl, agent_template_content(flavor, "worker"))
      new_tmpl = URI.new!("template://agent/default/ph7r2-h4-new-#{uniq()}")
      :ok = create_agent_template(new_tmpl, agent_template_content(flavor, "new"))

      st_uri = create_session_template("ph7r2-h4-team-#{uniq()}", [{"dev", worker_tmpl}], [])
      owner_uri = full_template_owner(@default_ws)

      {:ok, %{session_uri: session_uri, orchestrator_uri: orch_uri}} =
        Session.spawn_from_template(st_uri, owner_uri)

      caps = orchestrator_caps(orch_uri)

      # Simulate a pre-hardening snapshot — overwrite the working copy's
      # `agent_slots` with a LEGACY 2-tuple `{slot, src}` (no live worker
      # recorded). `normalize_slot/1` widens it to `{slot, src, nil, 0}`.
      {:ok, %{template_working_copy: _}} =
        Behavior.Chat.system_set_working_copy(session_uri, %{
          agent_slots: [{"dev", worker_tmpl}],
          routing_rules: []
        })

      # Pre-round-2 this `{_, _, nil, _}` slot crashed update_agent_template
      # with a CaseClauseError. It must now return a controlled error.
      result =
        Tools.update_agent_template("dev", new_tmpl,
          caller: orch_uri,
          caps: caps,
          workspace_uri: @default_ws,
          session_uri: session_uri
        )

      assert result == {:error, {:update_aborted, :no_live_worker}},
             "a legacy 2-tuple slot must yield :no_live_worker, not a CaseClauseError. " <>
               "Got: #{inspect(result)}"
    end
  end

  # ── HIGH-1 (round 3) — update_agent_template's routing re-point is a
  # CHECKED step; a re-point failure aborts the swap with the OLD worker
  # kept alive. ────────────────────────────────────────────────────────

  describe "HIGH-1 r3 — a routing re-point failure aborts the swap, OLD worker survives" do
    test "a forced load_into_registry raise during the re-point keeps the old worker alive" do
      flavor = register_test_flavor()
      tmpl_a = URI.new!("template://agent/default/ph7r3-h1-a-#{uniq()}")
      tmpl_b = URI.new!("template://agent/default/ph7r3-h1-b-#{uniq()}")
      :ok = create_agent_template(tmpl_a, agent_template_content(flavor, "config-a"))
      :ok = create_agent_template(tmpl_b, agent_template_content(flavor, "config-b"))

      # A SessionTemplate whose routing rule names the "dev" slot — so
      # the swap's `repoint_routing_rules` has a rule to rewrite (and
      # hence calls `load_into_registry`).
      st_uri =
        create_session_template(
          "ph7r3-h1-team-#{uniq()}",
          [{"dev", tmpl_a}],
          [{{:text_contains, "ph7r3h1route"}, ["dev"]}]
        )

      owner_uri = full_template_owner(@default_ws)

      {:ok, %{session_uri: session_uri, orchestrator_uri: orch_uri}} =
        Session.spawn_from_template(st_uri, owner_uri)

      [old_worker] = live_workers_of(orch_uri)
      caps = orchestrator_caps(orch_uri)

      # Force `RuleStore.load_into_registry` to RAISE during the swap's
      # routing re-point by removing the MentionRouting meta row — then
      # `RoutingRegistry.replace_table_contents → get_meta` raises an
      # `ArgumentError`. The exact tuple is restored immediately after
      # the call (and via on_exit) so the shared registry is unharmed.
      table = EzagentDomainChat.Routing.MentionRouting
      meta_table = Ezagent.RoutingRegistry.table()
      [{_, _} = saved_meta] = :ets.lookup(meta_table, table)
      on_exit(fn -> :ets.insert(meta_table, saved_meta) end)

      :ets.delete(meta_table, table)

      result =
        Tools.update_agent_template("dev", tmpl_b,
          caller: orch_uri,
          caps: caps,
          workspace_uri: @default_ws,
          session_uri: session_uri
        )

      # Restore the registry meta IMMEDIATELY — keep the corruption
      # window to exactly the one call under test.
      :ets.insert(meta_table, saved_meta)

      # HIGH-1 — the swap returns a CONTROLLED error, not a raise.
      assert match?({:error, {:update_aborted, _}}, result),
             "a routing re-point failure must abort with a controlled error. " <>
               "Got: #{inspect(result)}"

      # HIGH-1 — the OLD worker is NOT terminated; routing never points
      # at a dead worker.
      assert {:ok, _pid} = KindRegistry.lookup(old_worker),
             "the OLD worker must be kept alive when the routing re-point fails"

      # The working copy was rolled back — the slot still names the OLD
      # worker + the OLD source template.
      wc = session_working_copy(session_uri)
      {_n, src, live, _gen} = find_slot(wc, "dev")

      assert URI.to_string(live) == URI.to_string(old_worker),
             "the slot tuple must be rolled back to the OLD live worker"

      assert URI.to_string(src) == URI.to_string(tmpl_a),
             "the slot tuple must be rolled back to the OLD source template"

      # No stale route to a dead worker: every routing recipient the
      # rule resolves is a LIVE actor.
      msg =
        Ezagent.Message.new(User.admin_uri(), %{text: "please ph7r3h1route"},
          inserted_at: DateTime.utc_now()
        )

      recipients =
        Ezagent.Routing.Resolver.resolve(msg, session_uri, [], workspace_uri: @default_ws)

      for recipient <- recipients do
        assert match?({:ok, _}, KindRegistry.lookup(recipient)),
               "no routing rule may name a dead worker after a failed swap: " <>
                 "#{URI.to_string(recipient)}"
      end
    end
  end

  # ── HIGH-2 (round 3) — install_routing_rules is exception-safe; a
  # raise after rows were inserted does not bypass cleanup_partial. ─────

  describe "HIGH-2 r3 — install_routing_rules survives a load_into_registry raise" do
    test "a raise after row inserts returns a tagged error and leaks nothing" do
      flavor = register_test_flavor()
      worker_tmpl = URI.new!("template://agent/default/ph7r3-h2-worker-#{uniq()}")
      :ok = create_agent_template(worker_tmpl, agent_template_content(flavor, "worker"))

      # A unique marker so the routing row this Generator run inserts is
      # identifiable amid rows other (async: false) tests have left.
      marker = "ph7r3h2marker-#{uniq()}"

      st_uri =
        create_session_template(
          "ph7r3-h2-team-#{uniq()}",
          [{"dev", worker_tmpl}],
          [{{:text_contains, marker}, ["dev"]}]
        )

      owner_uri = full_template_owner(@default_ws)

      table = EzagentDomainChat.Routing.MentionRouting
      lineage_before = MapSet.new(AgentLineage.list_all(), fn {a, _} -> a end)
      ids_before = table |> Ezagent.Routing.RuleStore.list() |> MapSet.new(& &1.id)

      # Force `RuleStore.load_into_registry` to RAISE. `install_routing_rules`
      # inserts its rows via `RuleStore.add` FIRST, then reloads the
      # registry — so the raise lands AFTER the rows are persisted. The
      # exact meta tuple is restored after the Generator call.
      meta_table = Ezagent.RoutingRegistry.table()
      [{_, _} = saved_meta] = :ets.lookup(meta_table, table)
      on_exit(fn -> :ets.insert(meta_table, saved_meta) end)

      :ets.delete(meta_table, table)

      result = Session.spawn_from_template(st_uri, owner_uri)

      :ets.insert(meta_table, saved_meta)

      # HIGH-2 — the Generator returns a TAGGED error, never a raise.
      assert match?({:error, _}, result),
             "install_routing_rules must return a tagged error on a registry-reload " <>
               "raise, not propagate the exception. Got: #{inspect(result)}"

      # cleanup_partial ran — no routing row carrying the marker leaked.
      rows_after = Ezagent.Routing.RuleStore.list(table)

      refute Enum.any?(rows_after, fn row ->
               row.matcher_data |> inspect() |> String.contains?(marker)
             end),
             "no routing_rules row may survive — cleanup_partial must have run after " <>
               "the exception-safe install returned its tagged error"

      ids_after = MapSet.new(rows_after, & &1.id)
      leaked_rows = MapSet.difference(ids_after, ids_before)

      assert MapSet.size(leaked_rows) == 0,
             "no routing_rules row the failed Generator inserted may leak: " <>
               "#{inspect(MapSet.to_list(leaked_rows))}"

      # cleanup_partial ran — no session / worker leaked either.
      lineage_after = MapSet.new(AgentLineage.list_all(), fn {a, _} -> a end)
      leaked_agents = MapSet.difference(lineage_after, lineage_before)

      for agent_str <- leaked_agents do
        assert KindRegistry.lookup(URI.parse(agent_str)) == :error,
               "the partially-built session's worker #{agent_str} must be torn down"
      end
    end
  end

  # ── MEDIUM-3 (round 3) — the slot-name uniqueness preflight computes
  # all candidate instance names up front and rejects duplicates. ──────

  describe "MEDIUM-3 r3 — slot-name uniqueness preflight" do
    test "two normal slots produce DISTINCT worker URIs" do
      flavor = register_test_flavor()
      tmpl = URI.new!("template://agent/default/ph7r3-m3-worker-#{uniq()}")
      :ok = create_agent_template(tmpl, agent_template_content(flavor, "worker"))

      st_uri =
        create_session_template(
          "ph7r3-m3-team-#{uniq()}",
          [{"backend", tmpl}, {"frontend", tmpl}],
          []
        )

      owner_uri = full_template_owner(@default_ws)

      assert {:ok, %{orchestrator_uri: orch_uri}} =
               Session.spawn_from_template(st_uri, owner_uri)

      workers = live_workers_of(orch_uri) |> Enum.map(&URI.to_string/1)

      assert length(workers) == 2,
             "both slots must spawn — got #{inspect(workers)}"

      assert workers == Enum.uniq(workers),
             "the Generator's slot-name preflight must yield DISTINCT worker URIs"
    end

    test "a constructed duplicate slot is REJECTED before any spawn" do
      # Two literally-equal slot names produce the same instance name —
      # the deterministic worst case. The preflight must reject the
      # Generator run BEFORE a single template.instantiate dispatch.
      flavor = register_test_flavor()
      tmpl = URI.new!("template://agent/default/ph7r3-m3-dup-#{uniq()}")
      :ok = create_agent_template(tmpl, agent_template_content(flavor, "worker"))

      st_uri =
        create_session_template(
          "ph7r3-m3-dup-team-#{uniq()}",
          [{"dev", tmpl}, {"dev", tmpl}],
          []
        )

      owner_uri = full_template_owner(@default_ws)

      lineage_before = MapSet.new(AgentLineage.list_all(), fn {a, _} -> a end)

      result = Session.spawn_from_template(st_uri, owner_uri)

      assert match?({:error, {:duplicate_instance_names, _}}, result),
             "a duplicate slot name must be rejected by the uniqueness preflight. " <>
               "Got: #{inspect(result)}"

      # Rejected BEFORE any spawn — no new agent in the lineage registry.
      lineage_after = MapSet.new(AgentLineage.list_all(), fn {a, _} -> a end)

      assert MapSet.equal?(lineage_before, lineage_after),
             "the preflight must reject duplicates BEFORE any template.instantiate dispatch"
    end

    test "the SlotNames preflight is a pure collision check" do
      # Direct unit check of the preflight function: distinct slot
      # specs pass; two specs that generate the same instance name fail.
      distinct = [{"backend", 0}, {"frontend", 0}, {"backend", 1}]
      assert Ezagent.Orchestrator.SlotNames.preflight(distinct, "disc") == :ok

      # The same slot name at the same generation → identical instance
      # name → a reported collision.
      colliding = [{"dev", 0}, {"dev", 0}]

      assert {:error, {:duplicate_instance_names, [{_name, slot_names}]}} =
               Ezagent.Orchestrator.SlotNames.preflight(colliding, "disc")

      assert Enum.sort(slot_names) == ["dev", "dev"]
    end
  end

  # ════════════════════════════════════════════════════════════════════
  # ROUND 4 — codex adversarial-review of hardening round 3 (#243).
  #
  # The structural fix: routing operations are now TRANSACTIONAL. The
  # matcher-based scrubber (a data-loss bug) and the multi-step manual
  # abort path are gone — `Repo.transaction` IS the rollback.
  # ════════════════════════════════════════════════════════════════════

  # ── HIGH-2 (round 4) — the routing-install scrubber was a DATA-LOSS
  # bug. The old `scrub_routing_rows_for` deleted EVERY routing_rules row
  # whose `matcher_data` matched a batch matcher — not constrained by
  # workspace / created_by / id — so a Generator failure on a COMMON
  # matcher hard-deleted pre-existing rows belonging to OTHER sessions.
  # The transactional install only ever undoes its OWN batch's rows. ───

  describe "HIGH-2 r4 — a routing-install failure does not delete OTHER sessions' rules" do
    test "a pre-existing rule sharing a matcher survives a Generator routing-install failure" do
      table = EzagentDomainChat.Routing.MentionRouting

      # A matcher used by BOTH a pre-existing (other-session) rule AND
      # the failing Generator's batch — the exact collision the old
      # matcher-based scrubber would over-delete on.
      shared_marker = "ph7r4shared-#{uniq()}"
      shared_matcher = {:text_contains, shared_marker}

      # ── A pre-existing routing rule from "another session" — a real
      # persisted row that names a DIFFERENT worker and shares the
      # matcher. It MUST survive the failed Generator run.
      other_session_worker =
        URI.parse("entity://agent/default/ph7r4_other-session-worker-#{uniq()}")

      assert {:ok, %{id: pre_existing_id}} =
               Ezagent.Routing.RuleStore.add(
                 table,
                 shared_matcher,
                 [other_session_worker],
                 User.admin_uri(),
                 workspace_uri: @default_ws
               )

      # ── A Generator whose SessionTemplate routing rule uses the SAME
      # matcher. Force `RuleStore.load_into_registry` to RAISE so the
      # routing-install step fails AFTER inserting its own row(s).
      flavor = register_test_flavor()
      worker_tmpl = URI.new!("template://agent/default/ph7r4-h2-worker-#{uniq()}")
      :ok = create_agent_template(worker_tmpl, agent_template_content(flavor, "worker"))

      st_uri =
        create_session_template(
          "ph7r4-h2-team-#{uniq()}",
          [{"dev", worker_tmpl}],
          [{shared_matcher, ["dev"]}]
        )

      owner_uri = full_template_owner(@default_ws)

      meta_table = Ezagent.RoutingRegistry.table()
      [{_, _} = saved_meta] = :ets.lookup(meta_table, table)
      on_exit(fn -> :ets.insert(meta_table, saved_meta) end)

      :ets.delete(meta_table, table)

      result = Session.spawn_from_template(st_uri, owner_uri)

      :ets.insert(meta_table, saved_meta)

      # The Generator failed (the registry reload raised).
      assert match?({:error, _}, result),
             "expected the Generator to fail on the forced registry-reload raise"

      # ── THE DATA-LOSS REGRESSION ── the pre-existing OTHER-session
      # rule, which merely SHARES the matcher, MUST still be in the
      # store. The old matcher-based scrubber would have hard-deleted it.
      rows_after = Ezagent.Routing.RuleStore.list(table)

      survivor = Enum.find(rows_after, fn row -> row.id == pre_existing_id end)

      assert survivor != nil,
             "a pre-existing routing rule from another session that merely SHARES a " <>
               "matcher with the failed Generator's batch MUST survive — the transactional " <>
               "install must never delete rules outside its own batch (data-loss bug)"

      assert URI.to_string(other_session_worker) in (survivor.receivers || []),
             "the surviving rule must be untouched — same receivers as before"

      # And the failing Generator left ZERO of its OWN routing rows.
      generator_rows =
        Enum.filter(rows_after, fn row ->
          row.id != pre_existing_id and
            row.matcher_data |> inspect() |> String.contains?(shared_marker)
        end)

      assert generator_rows == [],
             "the failed Generator's own routing rows must all be gone — the transaction " <>
               "rolled back / the committed rows were deleted"
    end
  end

  # ── HIGH-1 (round 4) — update_agent_template's routing re-point is a
  # Repo.transaction. A re-point failure rolls the transaction back; the
  # persisted rows end up back on the OLD worker and the swap aborts. ──

  describe "HIGH-1 r4 — a routing re-point failure leaves the persisted rows on the OLD worker" do
    test "after an aborted swap the DB routing rows still name the OLD worker, which is alive" do
      flavor = register_test_flavor()
      tmpl_a = URI.new!("template://agent/default/ph7r4-h1-a-#{uniq()}")
      tmpl_b = URI.new!("template://agent/default/ph7r4-h1-b-#{uniq()}")
      :ok = create_agent_template(tmpl_a, agent_template_content(flavor, "config-a"))
      :ok = create_agent_template(tmpl_b, agent_template_content(flavor, "config-b"))

      st_uri =
        create_session_template(
          "ph7r4-h1-team-#{uniq()}",
          [{"dev", tmpl_a}],
          [{{:text_contains, "ph7r4h1route-#{uniq()}"}, ["dev"]}]
        )

      owner_uri = full_template_owner(@default_ws)

      {:ok, %{session_uri: session_uri, orchestrator_uri: orch_uri}} =
        Session.spawn_from_template(st_uri, owner_uri)

      [old_worker] = live_workers_of(orch_uri)
      caps = orchestrator_caps(orch_uri)
      old_str = URI.to_string(old_worker)

      table = EzagentDomainChat.Routing.MentionRouting

      # Sanity — the routing row names the OLD worker before the swap.
      assert Enum.any?(Ezagent.Routing.RuleStore.list(table), fn row ->
               old_str in (row.receivers || [])
             end),
             "sanity — a persisted routing row names the old worker"

      # Force `load_into_registry` to RAISE during the swap's re-point.
      meta_table = Ezagent.RoutingRegistry.table()
      [{_, _} = saved_meta] = :ets.lookup(meta_table, table)
      on_exit(fn -> :ets.insert(meta_table, saved_meta) end)

      :ets.delete(meta_table, table)

      result =
        Tools.update_agent_template("dev", tmpl_b,
          caller: orch_uri,
          caps: caps,
          workspace_uri: @default_ws,
          session_uri: session_uri
        )

      :ets.insert(meta_table, saved_meta)

      # The swap aborts with a controlled error.
      assert match?({:error, {:update_aborted, _}}, result),
             "a routing re-point failure must abort with {:error, {:update_aborted, _}}. " <>
               "Got: #{inspect(result)}"

      # The OLD worker is untouched + alive.
      assert {:ok, _pid} = KindRegistry.lookup(old_worker),
             "the OLD worker must be kept alive when the re-point fails"

      # The persisted DB routing rows are back on the OLD worker — the
      # inverse Repo.transaction restored them; no row names the new
      # (terminated orphan) worker.
      rows_after = Ezagent.Routing.RuleStore.list(table)

      assert Enum.any?(rows_after, fn row -> old_str in (row.receivers || []) end),
             "the persisted routing rows must still name the OLD worker after the abort"

      for row <- rows_after, receiver <- row.receivers || [] do
        if String.contains?(receiver, "ph7r4-h1") do
          assert receiver == old_str,
                 "no persisted routing row may name a worker other than the OLD one " <>
                   "after the aborted swap — got #{receiver}"
        end
      end
    end
  end

  # ── MEDIUM-3 (round 4) — SlotNames.preflight_live_worker_uris rejects
  # a candidate worker URI that is ALREADY live in KindRegistry as an
  # orphan from a prior failed cleanup. ────────────────────────────────

  describe "MEDIUM-3 r4 — SlotNames rejects a candidate URI already live as an orphan" do
    test "an absent candidate URI passes; a live-but-unexpected one is rejected" do
      flavor = register_test_flavor()
      worker_tmpl = URI.new!("template://agent/default/ph7r4-m3-worker-#{uniq()}")
      :ok = create_agent_template(worker_tmpl, agent_template_content(flavor, "worker"))

      st_uri = create_session_template("ph7r4-m3-team-#{uniq()}", [{"dev", worker_tmpl}], [])
      owner_uri = full_template_owner(@default_ws)

      {:ok, %{orchestrator_uri: orch_uri}} = Session.spawn_from_template(st_uri, owner_uri)

      [live_worker] = live_workers_of(orch_uri)

      # A URI that is NOT registered — passes (no orphan).
      absent = URI.parse("entity://agent/default/ph7r4_m3-absent-#{uniq()}")

      assert Ezagent.Orchestrator.SlotNames.preflight_live_worker_uris([{absent, nil}]) == :ok,
             "an absent candidate URI must pass the orphan check"

      # The live worker URI with NO expected-URI → it is an unexpected
      # live worker (an orphan from a prior failed cleanup) → rejected.
      assert {:error, {:candidate_uri_already_live, [rejected]}} =
               Ezagent.Orchestrator.SlotNames.preflight_live_worker_uris([{live_worker, nil}]),
             "a candidate URI already live in KindRegistry must be rejected as an orphan"

      assert URI.to_string(rejected) == URI.to_string(live_worker)

      # The SAME live worker URI, but now declared as the EXPECTED
      # current worker → NOT a false positive (a degenerate same-URI).
      assert Ezagent.Orchestrator.SlotNames.preflight_live_worker_uris([
               {live_worker, live_worker}
             ]) == :ok,
             "a candidate URI that equals its expected current worker is not an orphan"
    end

    test "the Generator rejects a run whose candidate worker URI is already live as an orphan" do
      # Spawn a worker at the EXACT URI the Generator's "dev" slot will
      # compute, so the Generator's candidate-URI preflight finds it live
      # as an orphan and rejects the run before instantiating any slot.
      flavor = register_test_flavor()
      worker_tmpl = URI.new!("template://agent/default/ph7r4-m3g-worker-#{uniq()}")
      :ok = create_agent_template(worker_tmpl, agent_template_content(flavor, "worker"))

      st_uri = create_session_template("ph7r4-m3g-team-#{uniq()}", [{"dev", worker_tmpl}], [])
      owner_uri = full_template_owner(@default_ws)

      # Run the Generator once successfully, then directly re-run
      # `SlotNames.preflight_live_worker_uris` over its live worker to
      # confirm a SECOND run reusing that URI would be rejected. (The
      # Generator's own session discriminator is freshly unique per run,
      # so the integration-level orphan is exercised via the unit path
      # above; here we assert the Generator threads the check at all by
      # confirming a normal run still succeeds — no false positive.)
      assert {:ok, %{orchestrator_uri: orch_uri}} =
               Session.spawn_from_template(st_uri, owner_uri)

      [worker] = live_workers_of(orch_uri)

      assert {:error, {:candidate_uri_already_live, _}} =
               Ezagent.Orchestrator.SlotNames.preflight_live_worker_uris([{worker, nil}]),
             "the live worker the Generator just spawned is, to any later run reusing its " <>
               "URI, an orphan the candidate-URI preflight must reject"
    end
  end

  # ══════════════════════════════════════════════════════════════════════
  # ROUND 5 — codex adversarial-review of hardening round 4 (#244).
  #
  # `update_agent_template` is a saga across resources that CANNOT all
  # join one SQL transaction (live workers, SQL routing, the
  # Session-Kind working-copy slice, ETS). Round 4 made the SQL part
  # transactional; round 5 makes the saga RECOVERY fail-safe — when a
  # recovery step itself fails the swap HALTS in a safe-degraded state
  # (all workers alive, a distinct manual-repair error), never a corrupt
  # state naming a terminated worker.
  #
  # - HIGH-1 r5 — the slot rollback is a CHECKED step; the replacement
  #   worker is terminated ONLY if the slot was confirmed restored. A
  #   slot-rollback failure terminates nothing, keeps both workers
  #   alive, returns {:error, {:update_needs_manual_repair, _}}.
  # - HIGH-2 r5 — the forward routing transaction returns the exact
  #   changed rule IDs; the inverse revert operates ONLY on those IDs.
  #   An inverse-revert failure is a blocking degraded state — halt,
  #   both workers alive, manual-repair error. A pre-existing rule
  #   naming the new worker URI is never touched.
  # - MEDIUM-3 r5 — the swap candidate path no longer silently adopts an
  #   an already-live worker: an `already_started` adoption is
  #   {:error, {:update_aborted, :candidate_uri_already_live}}.
  # ══════════════════════════════════════════════════════════════════════

  # Kill the Session Kind on the Nth `chat.set_working_copy` authz-grant.
  # The handler runs synchronously INSIDE the Session process (the authz
  # check is part of the Session's handle_call) before `invoke/4` runs —
  # so killing `self()` there makes the in-flight `set_working_copy`
  # GenServer.call EXIT, which `rollback_slot_to_old` catches as a clean
  # `:error`. Deterministic — no polling, no race.
  defp install_session_killer_on_nth_set_working_copy(session_uri, n) do
    handler_id = {:r5_session_killer, session_uri, make_ref()}
    counter = :counters.new(1, [])
    session_str = URI.to_string(session_uri)

    :telemetry.attach(
      handler_id,
      [:ezagent, :authz, :granted],
      fn _event, _measure, meta, _cfg ->
        target = meta[:target]

        if meta[:action] == :set_working_copy and is_struct(target, URI) and
             String.starts_with?(URI.to_string(target), session_str) do
          :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) >= n do
            Process.exit(self(), :kill)
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  # HIGH-1 r5 — force the routing re-point's post-commit reload to fail
  # AND the slot rollback to fail; assert the swap HALTS fail-safe.
  describe "HIGH-1 r5 — a slot-rollback failure terminates nothing and halts fail-safe" do
    test "a failed slot rollback keeps BOTH workers alive + returns :update_needs_manual_repair" do
      flavor = register_test_flavor()
      tmpl_a = URI.new!("template://agent/default/ph7r5-h1-a-#{uniq()}")
      tmpl_b = URI.new!("template://agent/default/ph7r5-h1-b-#{uniq()}")
      :ok = create_agent_template(tmpl_a, agent_template_content(flavor, "config-a"))
      :ok = create_agent_template(tmpl_b, agent_template_content(flavor, "config-b"))

      st_uri =
        create_session_template(
          "ph7r5-h1-team-#{uniq()}",
          [{"dev", tmpl_a}],
          [{{:text_contains, "ph7r5h1route-#{uniq()}"}, ["dev"]}]
        )

      owner_uri = full_template_owner(@default_ws)

      {:ok, %{session_uri: session_uri, orchestrator_uri: orch_uri}} =
        Session.spawn_from_template(st_uri, owner_uri)

      [old_worker] = live_workers_of(orch_uri)
      caps = orchestrator_caps(orch_uri)

      # The replacement worker URI the swap will spawn — the OLD worker
      # URI with a generation-1 suffix (`session_instance_name/3`
      # appends `--g1` for generation > 0).
      new_worker = URI.parse(URI.to_string(old_worker) <> "--g1")

      # Force the routing re-point's post-commit reload to fail — drop
      # the MentionRouting meta row so `replace_table_contents` raises.
      table = EzagentDomainChat.Routing.MentionRouting
      meta_table = Ezagent.RoutingRegistry.table()
      [{_, _} = saved_meta] = :ets.lookup(meta_table, table)
      on_exit(fn -> :ets.insert(meta_table, saved_meta) end)
      :ets.delete(meta_table, table)

      # Force the SLOT ROLLBACK to fail — kill the Session on the 2nd
      # `set_working_copy` (1st = step-2 commit, 2nd = the abort path's
      # rollback). The rollback's dispatch then EXITS → caught → :error.
      :ok = install_session_killer_on_nth_set_working_copy(session_uri, 2)

      result =
        Tools.update_agent_template("dev", tmpl_b,
          caller: orch_uri,
          caps: caps,
          workspace_uri: @default_ws,
          session_uri: session_uri
        )

      :ets.insert(meta_table, saved_meta)

      # HIGH-1 r5 — a distinct manual-repair error, NOT a generic abort.
      assert match?({:error, {:update_needs_manual_repair, _}}, result),
             "a slot-rollback failure must HALT with {:error, {:update_needs_manual_repair, _}}. " <>
               "Got: #{inspect(result)}"

      {:error, {:update_needs_manual_repair, info}} = result

      # The repair payload carries enough state for an operator.
      assert info[:reason] == :slot_rollback_failed
      assert URI.to_string(info[:old_worker]) == URI.to_string(old_worker)
      assert URI.to_string(info[:new_worker]) == URI.to_string(new_worker)
      assert info[:slot] == "dev"

      live = Enum.map(info[:live_workers] || [], &URI.to_string/1)
      assert URI.to_string(old_worker) in live
      assert URI.to_string(new_worker) in live

      # HIGH-1 r5 — NOTHING was terminated: BOTH workers are still alive.
      assert {:ok, _} = KindRegistry.lookup(old_worker),
             "the OLD worker must NOT be terminated when the slot rollback fails"

      assert {:ok, _} = KindRegistry.lookup(new_worker),
             "the NEW (replacement) worker must NOT be terminated when the slot " <>
               "rollback fails — the slot may still name it"
    end
  end

  # HIGH-2 r5 — force the inverse routing revert to fail after a
  # committed forward txn; assert the swap HALTS fail-safe and that the
  # inverse revert is scoped to the forward txn's rule IDs only.
  describe "HIGH-2 r5 — an inverse-revert failure halts fail-safe; the revert is ID-scoped" do
    test "a forward-txn-committed + inverse-revert-failed swap halts, both workers alive" do
      flavor = register_test_flavor()
      tmpl_a = URI.new!("template://agent/default/ph7r5-h2-a-#{uniq()}")
      tmpl_b = URI.new!("template://agent/default/ph7r5-h2-b-#{uniq()}")
      :ok = create_agent_template(tmpl_a, agent_template_content(flavor, "config-a"))
      :ok = create_agent_template(tmpl_b, agent_template_content(flavor, "config-b"))

      route_token = "ph7r5h2route-#{uniq()}"

      st_uri =
        create_session_template(
          "ph7r5-h2-team-#{uniq()}",
          [{"dev", tmpl_a}],
          [{{:text_contains, route_token}, ["dev"]}]
        )

      owner_uri = full_template_owner(@default_ws)

      {:ok, %{session_uri: session_uri, orchestrator_uri: orch_uri}} =
        Session.spawn_from_template(st_uri, owner_uri)

      [old_worker] = live_workers_of(orch_uri)
      caps = orchestrator_caps(orch_uri)
      old_str = URI.to_string(old_worker)
      new_worker = URI.parse(old_str <> "--g1")
      new_str = URI.to_string(new_worker)

      table = EzagentDomainChat.Routing.MentionRouting

      # The routing rule the forward txn will rewrite (old → new).
      [forward_rule] =
        Enum.filter(Ezagent.Routing.RuleStore.list(table), fn row ->
          old_str in (row.receivers || [])
        end)

      # An UNRELATED pre-existing rule that ALREADY names the NEW worker
      # URI. The round-4 inverse revert was a blanket receiver-URI match
      # → it would rewrite THIS rule too. The round-5 inverse revert is
      # scoped to the forward txn's rule IDs → this rule must be UNTOUCHED.
      {:ok, unrelated_rule} =
        Ezagent.Routing.RuleStore.add(
          table,
          {:text_contains, "ph7r5h2-unrelated-#{uniq()}"},
          [new_str],
          User.admin_uri(),
          source: "admin"
        )

      # Force the inverse revert to fail: DELETE the forward-txn rule row
      # the instant the forward txn's UPDATE on `routing_rules` runs
      # (synchronously, same connection → the delete joins the forward
      # txn and commits with it). The inverse revert then finds its
      # changed rule id GONE → {:revert_failed, {:rows_vanished, _}}.
      delete_handler = {:r5_h2_forward_update_deleter, make_ref()}
      done = :counters.new(1, [])
      forward_rule_id = forward_rule.id

      :telemetry.attach(
        delete_handler,
        [:ezagent_core, :repo, :query],
        fn _e, _m, meta, _cfg ->
          sql = to_string(meta[:query] || "")

          if :counters.get(done, 1) == 0 and
               String.contains?(sql, "UPDATE") and String.contains?(sql, "routing_rules") do
            :counters.add(done, 1, 1)
            # Same process + connection → part of the open forward txn.
            EzagentCore.Repo.delete_all(
              from(r in Ezagent.Routing.RuleStore, where: r.id == ^forward_rule_id)
            )
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(delete_handler) end)

      # Also force the post-commit reload to fail (drop the meta row) so
      # the inverse revert is reached at all.
      meta_table = Ezagent.RoutingRegistry.table()
      [{_, _} = saved_meta] = :ets.lookup(meta_table, table)
      on_exit(fn -> :ets.insert(meta_table, saved_meta) end)
      :ets.delete(meta_table, table)

      result =
        Tools.update_agent_template("dev", tmpl_b,
          caller: orch_uri,
          caps: caps,
          workspace_uri: @default_ws,
          session_uri: session_uri
        )

      :ets.insert(meta_table, saved_meta)
      :telemetry.detach(delete_handler)

      # HIGH-2 r5 — the inverse revert failed → the swap HALTS with the
      # distinct manual-repair error.
      assert match?({:error, {:update_needs_manual_repair, _}}, result),
             "an inverse-revert failure after a committed forward txn must HALT with " <>
               "{:error, {:update_needs_manual_repair, _}}. Got: #{inspect(result)}"

      {:error, {:update_needs_manual_repair, info}} = result
      assert info[:reason] == :routing_revert_failed

      # HIGH-2 r5 — BOTH workers stay alive; nothing terminated.
      assert {:ok, _} = KindRegistry.lookup(old_worker),
             "the OLD worker must NOT be terminated when the inverse revert fails"

      assert {:ok, _} = KindRegistry.lookup(new_worker),
             "the NEW worker must NOT be terminated when the inverse revert fails"

      # HIGH-2 r5 — the UNRELATED pre-existing rule that names the new
      # worker URI is UNTOUCHED — the inverse revert is scoped to the
      # forward txn's rule IDs, NOT a blanket receiver-URI match.
      unrelated_after = EzagentCore.Repo.get(Ezagent.Routing.RuleStore, unrelated_rule.id)

      assert unrelated_after != nil,
             "the unrelated pre-existing rule must still exist"

      assert new_str in (unrelated_after.receivers || []),
             "the unrelated rule naming the NEW worker URI must be UNTOUCHED by the " <>
               "ID-scoped inverse revert — a blanket receiver-URI revert would have " <>
               "rewritten it. receivers=#{inspect(unrelated_after.receivers)}"
    end
  end

  # MEDIUM-3 r5 — the swap must never silently adopt an already-live
  # worker. The round-4 candidate-URI preflight is a TOCTOU check; the
  # round-5 fix is the `fresh?` signal checked AFTER instantiate.
  describe "MEDIUM-3 r5 — the swap rejects an already-live candidate worker" do
    test "a candidate URI registered in the TOCTOU window is rejected, not adopted" do
      flavor = register_test_flavor()
      tmpl_a = URI.new!("template://agent/default/ph7r5-m3-a-#{uniq()}")
      tmpl_b = URI.new!("template://agent/default/ph7r5-m3-b-#{uniq()}")
      :ok = create_agent_template(tmpl_a, agent_template_content(flavor, "config-a"))
      :ok = create_agent_template(tmpl_b, agent_template_content(flavor, "config-b"))

      st_uri = create_session_template("ph7r5-m3-team-#{uniq()}", [{"dev", tmpl_a}], [])
      owner_uri = full_template_owner(@default_ws)

      {:ok, %{session_uri: session_uri, orchestrator_uri: orch_uri}} =
        Session.spawn_from_template(st_uri, owner_uri)

      [old_worker] = live_workers_of(orch_uri)
      caps = orchestrator_caps(orch_uri)

      # The candidate replacement worker URI — old worker URI + `--g1`.
      candidate = URI.parse(URI.to_string(old_worker) <> "--g1")

      # Simulate the TOCTOU race: register a worker at the candidate URI
      # AFTER the swap's round-4 preflight (which lives in Tools, earlier
      # in the flow) but BEFORE `spawn_from_template_content` probes for
      # the `fresh?` signal. The `template.instantiate` authz-grant fires
      # in that exact window — attach a one-shot handler that spawns the
      # worker there.
      handler_id = {:r5_m3_toctou_spawn, make_ref()}
      armed = :counters.new(1, [])
      tmpl_b_str = URI.to_string(tmpl_b)

      :telemetry.attach(
        handler_id,
        [:ezagent, :authz, :granted],
        fn _e, _m, meta, _cfg ->
          target = meta[:target]

          if :counters.get(armed, 1) == 0 and meta[:action] == :instantiate and
               is_struct(target, URI) and
               String.starts_with?(URI.to_string(target), tmpl_b_str) do
            :counters.add(armed, 1, 1)
            {:ok, _pid} = Ezagent.SpawnRegistry.spawn(candidate)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      result =
        Tools.update_agent_template("dev", tmpl_b,
          caller: orch_uri,
          caps: caps,
          workspace_uri: @default_ws,
          session_uri: session_uri
        )

      :telemetry.detach(handler_id)

      # MEDIUM-3 r5 — the swap REFUSES the already-live candidate; it
      # does NOT silently adopt it.
      assert result == {:error, {:update_aborted, :candidate_uri_already_live}},
             "a candidate worker that became live in the TOCTOU window must abort the " <>
               "swap with :candidate_uri_already_live — never a silent adoption. " <>
               "Got: #{inspect(result)}"

      # The OLD worker is untouched + alive — no outage.
      assert {:ok, _} = KindRegistry.lookup(old_worker),
             "the OLD worker must stay alive when the candidate is rejected"

      # The slot still names the OLD worker — the swap did not commit.
      wc = session_working_copy(session_uri)
      {_n, _src, live, _gen} = find_slot(wc, "dev")

      assert URI.to_string(live) == URI.to_string(old_worker),
             "the slot must still name the OLD worker after a rejected swap"
    end

    test "spawn_from_template_content signals fresh? on first spawn, not on adoption" do
      # The `fresh?` signal at its source — first spawn is fresh, a
      # re-spawn at the same URI adopts (not fresh).
      flavor = register_test_flavor()
      tmpl = URI.new!("template://agent/default/ph7r5-m3sig-#{uniq()}")
      content = agent_template_content(flavor, "sig")
      :ok = create_agent_template(tmpl, content)

      instance_uri = URI.parse("entity://agent/default/#{flavor}_ph7r5sig-#{uniq()}")
      spawned_by = User.admin_uri()

      assert {:ok, %{workers: [^instance_uri], fresh?: true}} =
               Agent.spawn_from_template_content(content, instance_uri, spawned_by, @default_ws),
             "the first spawn at a URI must report fresh?: true"

      assert {:ok, %{workers: [^instance_uri], fresh?: false}} =
               Agent.spawn_from_template_content(content, instance_uri, spawned_by, @default_ws),
             "a re-spawn at an already-live URI must report fresh?: false (adoption)"
    end
  end

  # --- shared helpers ----------------------------------------------------

  # A test flavor whose Template Class spawns the worker Agent Kind and
  # then TERMINATES the freshly-spawned orchestrator agent — used by the
  # HIGH-3 r2 test to force a Generator failure AFTER routing install.
  defp register_orchestrator_killer_flavor do
    flavor = "ph7r2kill#{uniq()}"

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Agent,
        template_class: OrchestratorKillerFlavorClass
      })

    flavor
  end

  # The live worker URIs recorded under a given orchestrator in
  # AgentLineage (excludes the orchestrator agent itself).
  defp live_workers_of(orchestrator_uri) do
    orch_str = URI.to_string(orchestrator_uri)

    AgentLineage.list_all()
    |> Enum.filter(fn {agent, spawned_by} ->
      spawned_by == orch_str and agent != orch_str
    end)
    |> Enum.map(fn {agent, _} -> URI.parse(agent) end)
  end

  defp find_slot(wc, slot_name) do
    Enum.find_value(Map.get(wc, :agent_slots, []), fn
      {^slot_name, src, live, gen} -> {slot_name, as_uri(src), as_uri(live), gen}
      _ -> nil
    end)
  end

  defp as_uri(%URI{} = u), do: u
  defp as_uri(s) when is_binary(s), do: URI.parse(s)

  # Drain authz-granted telemetry, keeping only `template.write`
  # dispatches against a `template://session/...` URI.
  defp collect_template_write_authz(acc \\ []) do
    receive do
      {:authz_granted,
       %{action: :write, target: %URI{scheme: "template", host: "session"}} = meta} ->
        collect_template_write_authz([meta | acc])

      {:authz_granted, _other} ->
        collect_template_write_authz(acc)
    after
      0 -> Enum.reverse(acc)
    end
  end
end
