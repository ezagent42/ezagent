defmodule EzagentDomainInstanceMessage.Integration.SpawnedParticipantTeardownTest do
  @moduledoc """
  F7 PR-B integration — spawned-worker teardown + the cap-model change
  (SPEC §2.2 / §3.2 / §4.1).

  Proves, against REAL spawned Agent Kinds + the durable `AgentLineage` table +
  a real routing rule:

    * removing a SPAWNED worker reaps it (worker Kind gone + `config_dir` GC'd +
      routing rows pruned + lineage forgotten) — NO ORPHAN;
    * delete-session cascades the reap to ALL spawned members;
    * the dead-orchestrator / junk-session fallback to `Lifecycle.destroy`
      reaps even when the owner teardown cap is absent;
    * an owner WITHOUT the teardown cap is DENIED in the strict remove path
      (fail-closed, the worker survives);
    * the granted teardown cap is #154-clean (`granted_by: owner`, no forged
      `{:spawned_by, orchestrator}` cap minted for the operator).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{AgentLineage, Invocation, KindRegistry}
  alias Ezagent.ActionSet.Session.Teardown
  alias Ezagent.Entity.{Agent, Session, User}
  alias Ezagent.Session.Participants
  alias EzagentDomainInstanceMessage.SessionCreator.Materializer

  # The `main` session lives in workspace://system; a worker spawned INTO a
  # session shares that session's workspace, so reaping it (session -> worker) is
  # same-workspace (step-5.6 isolation passes). Tests use the system workspace to
  # mirror that production topology.
  @workspace_uri URI.new!("workspace://system")

  defp uniq, do: System.unique_integer([:positive])

  setup do
    _ =
      EzagentDomainInstanceMessage.SessionCreator.create_session("main", User.admin_uri(),
        template_name: "default"
      )

    :ok
  end

  # A live Agent Kind hosting Sandbox, with a config_dir wired to a stub
  # Template Class that broadcasts on `destroy_config_dir/2` so the test can
  # observe the FS GC fire.
  defp spawn_worker(config_dir, template_class \\ __MODULE__.GcStubClass) do
    uri = Ezagent.URI.new!("entity://system/agent/worker-#{uniq()}")
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: uri})
    :ok = Ezagent.WorkspaceRegistry.bind(uri, @workspace_uri)

    {:ok, _} =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.new!("#{URI.to_string(uri)}?action=sandbox.update_config"),
        mode: :call,
        args: %{config_dir_path: config_dir, template_class: template_class},
        ctx: %{
          caller: User.admin_uri(),
          caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
          reply: {:caller_inbox, self()}
        }
      })

    uri
  end

  defp record_creation(agent_uri, spawned_by_uri) do
    Ezagent.Agent.CreationInventory.record(
      Ezagent.Agent.CreationInventory.new_attempt_id(),
      agent_uri,
      spawned_by_uri,
      @workspace_uri
    )
  end

  # Join `worker` into `session` carrying the `:source_template_uri` spawn facet
  # (the provenance marker a managed member gets at spawn) under admin authority.
  defp join_spawned(session_uri, worker_uri) do
    tmpl = Ezagent.URI.new!("template://system/agent/worker-role")

    :ok =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join"),
        mode: :cast,
        args: %{member: worker_uri, source_template_uri: tmpl},
        ctx: %{
          caller: worker_uri,
          caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
          reply: :ignore
        }
      })

    # let the cast land
    _ = Participants.list_participants(session_uri)
    :ok
  end

  defp op_ctx(%URI{} = caller, %URI{} = session_uri) do
    cap = %Ezagent.Capability{
      Ezagent.Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :remove_participant,
        Ezagent.URI.instance(session_uri),
        Ezagent.Capability.workspace_of(session_uri)
      )
      | granted_by: caller,
        granted_at: DateTime.utc_now()
    }

    %{caller: caller, caps: [cap]}
  end

  defp wait_until_gone(uri, tries \\ 60) do
    cond do
      tries == 0 ->
        :still_alive

      KindRegistry.lookup(uri) == :error ->
        :gone

      true ->
        Process.sleep(10)
        wait_until_gone(uri, tries - 1)
    end
  end

  # Insert a routing rule created_by the session naming the worker, so the prune
  # has something to remove.
  defp add_routing_rule(session_uri, worker_uri) do
    table = EzagentDomainInstanceMessage.Routing.MentionRouting

    {:ok, rule} =
      Ezagent.Routing.RuleStore.add(
        table,
        Ezagent.Routing.Matcher.always(),
        [URI.to_string(worker_uri)],
        session_uri,
        []
      )

    Ezagent.Routing.RuleStore.load_into_registry(table)
    rule
  end

  defp session_rule_ids(session_uri) do
    table = EzagentDomainInstanceMessage.Routing.MentionRouting
    session_str = URI.to_string(session_uri)

    table
    |> Ezagent.Routing.RuleStore.list()
    |> Enum.filter(fn r -> r.created_by == session_str end)
    |> Enum.map(& &1.id)
  end

  describe "remove a spawned worker — NO ORPHAN (SPEC §3.2)" do
    test "worker reaped + config_dir GC'd + routing pruned + lineage forgotten" do
      session_uri = Session.default_uri()
      owner = User.admin_uri()
      config_dir = "/tmp/f7b-worker-#{uniq()}"

      worker = spawn_worker(config_dir)
      # Durable lineage: worker -> owner (the chain spawned_in_lineage? walks).
      :ok = AgentLineage.record(worker, owner)
      :ok = record_creation(worker, owner)
      join_spawned(session_uri, worker)
      _rule = add_routing_rule(session_uri, worker)

      assert worker in Participants.list_participants(session_uri)
      # lineage records the PARENT (spawned_by): worker -> owner.
      assert {:ok, owner} == AgentLineage.lookup(worker)
      assert session_rule_ids(session_uri) != []

      Phoenix.PubSub.subscribe(EzagentCore.PubSub, "test:f7b_gc:#{URI.to_string(worker)}")
      # The membership-changes convergence topic — proves the reaped spawned
      # worker ALSO emits {:member_left} (no silent orphan even on the spawned
      # path; codex Q4 / SPEC §7).
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, "esr:session_membership:changes")

      # Remove via the SHARED entry the CLI + UI both call. admin == main owner
      # AND holds the create-time teardown cap, so the reap is authorized.
      assert {:ok, %{status: :removed, torn_down: :worker}} =
               Participants.remove_participant(session_uri, worker, op_ctx(owner, session_uri))

      # (a) config_dir was GC'd (the Sandbox handle_destroy FS cleanup fired).
      assert_receive {:gc_called, ^worker, ^config_dir}, 2_000
      # (b) the worker Kind process is gone (NO orphan process).
      assert :gone = wait_until_gone(worker)
      # (c) routing rows naming the worker were pruned.
      assert session_rule_ids(session_uri) == []
      # (d) lineage forgotten.
      assert :error == AgentLineage.lookup(worker)
      # (e) membership dropped.
      refute worker in Participants.list_participants(session_uri)
      # (f) {:member_left} convergence broadcast fired for the spawned worker.
      assert_receive {:session_membership_change, ^session_uri, {:member_left, ^worker}}, 2_000
    end

    test "config_dir cleanup FAILURE still drops the member (worker reaped → no zombie; codex Q4 follow-up)" do
      # Sandbox.handle_destroy rescues a raising destroy_config_dir and returns
      # {destroyed: true, cleanup: {:error, _}} — the worker process IS reaped but
      # the FS dir leaked. The membership teardown MUST still proceed (member
      # dropped + {:member_left}), NOT abort into a zombie referencing a dead
      # worker. The reap returns :worker; the leak is logged out-of-band.
      session_uri = Session.default_uri()
      owner = User.admin_uri()
      config_dir = "/tmp/f7b-cleanupfail-#{uniq()}"

      worker = spawn_worker(config_dir, __MODULE__.RaisingGcStubClass)
      :ok = AgentLineage.record(worker, owner)
      :ok = record_creation(worker, owner)
      join_spawned(session_uri, worker)

      assert worker in Participants.list_participants(session_uri)
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, "esr:session_membership:changes")

      assert {:ok,
              %{
                status: :removed,
                torn_down: :worker,
                cleanup: :pending,
                cleanup_obligation_id: obligation_id
              }} =
               Participants.remove_participant(session_uri, worker, op_ctx(owner, session_uri))

      assert is_integer(obligation_id)

      assert :gone = wait_until_gone(worker)
      refute worker in Participants.list_participants(session_uri)
      assert_receive {:session_membership_change, ^session_uri, {:member_left, ^worker}}, 2_000
      assert :error == AgentLineage.lookup(worker)
    end
  end

  describe "THE CRUX (SPEC §2.2) — non-admin owner cap reaps via TRANSITIVE lineage" do
    test "a non-admin owner's {:spawned_by, owner} cap reaps an orchestrator-spawned worker (two-hop, no admin, no cap #2)" do
      # This is the load-bearing end-to-end proof: the granted teardown cap (NOT
      # an admin wildcard) authorizes the reap, and it reaches the worker through
      # the FULL durable chain `worker → orchestrator → owner` (NOT a one-hop
      # shortcut). If the transitive walk or the cap instance/workspace match
      # were wrong, this fails while the admin/one-hop tests still pass.
      config_dir = "/tmp/f7b-crux-#{uniq()}"

      # Non-admin confirmed user owner (no genesis wildcard short-circuit).
      owner = URI.new!("entity://system/user/crux-owner-#{uniq()}")
      {:ok, _} = Ezagent.Users.create(owner, "pw-#{uniq()}", [])
      {:ok, _} = Ezagent.SpawnRegistry.spawn(owner)

      # The ONLY authority granted: the create-time {:spawned_by, owner} teardown
      # cap (granted_by: owner). No cap #2, no admin.
      assert :ok = Materializer.grant_owner_participant_teardown_cap(owner, @workspace_uri)

      worker = spawn_worker(config_dir)

      # TWO HOPS: orchestrator is NOT live (it crashed / never mattered) — only
      # the durable lineage rows exist. worker → orchestrator → owner.
      orchestrator = URI.new!("entity://system/agent/crux-orch-#{uniq()}")
      :ok = AgentLineage.record(orchestrator, owner)
      :ok = AgentLineage.record(worker, orchestrator)
      :ok = record_creation(worker, orchestrator)

      # Sanity: the transitive walk reaches the owner (the property the cap
      # match relies on); one hop (worker→orchestrator) does NOT reach owner.
      assert AgentLineage.spawned_in_lineage?(worker, owner)

      Phoenix.PubSub.subscribe(EzagentCore.PubSub, "test:f7b_gc:#{URI.to_string(worker)}")

      # Strict reap, AS the non-admin owner: step-5.5 resolves the owner's
      # {:spawned_by, owner} cap, which matches the worker via the transitive
      # lineage walk — authorized WITHOUT admin and WITHOUT the orchestrator's
      # cap #2 (which is moot — the orchestrator isn't even live).
      assert {:ok, %{termination: :destroyed, cleanup: :complete}} =
               Teardown.reap_spawned_worker(worker, owner, :strict)

      assert_receive {:gc_called, ^worker, ^config_dir}, 2_000
      assert :gone = wait_until_gone(worker)
      assert :error == AgentLineage.lookup(worker)
    end
  end

  describe "owner WITHOUT the teardown cap is DENIED (strict, fail-closed)" do
    test "a spawned worker survives when the owner lacks the destroy cap" do
      config_dir = "/tmp/f7b-denied-#{uniq()}"

      # A real confirmed user with NO teardown cap (never went through the
      # create-time grant for THIS worker's lineage root).
      owner = URI.new!("entity://system/user/nocaps-#{uniq()}")
      {:ok, _} = Ezagent.Users.create(owner, "pw-#{uniq()}", [])
      {:ok, _} = Ezagent.SpawnRegistry.spawn(owner)

      worker = spawn_worker(config_dir)
      :ok = AgentLineage.record(worker, owner)
      :ok = record_creation(worker, owner)

      # Strict reap: the dispatch runs under the OWNER's PERSISTED caps (empty of
      # the teardown cap) → sandbox.destroy is unauthorized → fail-closed.
      assert {:error, {:worker_teardown_failed, _}} =
               Teardown.reap_spawned_worker(worker, owner, :strict)

      # The worker MUST survive (no half-teardown) + lineage intact.
      assert {:ok, _pid} = KindRegistry.lookup(worker)
      assert {:ok, owner} == AgentLineage.lookup(worker)
    end
  end

  describe "best-effort teardown preserves evidence without authority" do
    test "an absent owner cap cannot trigger an unverified VM destroy" do
      config_dir = "/tmp/f7b-fallback-#{uniq()}"

      owner = URI.new!("entity://system/user/junk-#{uniq()}")
      {:ok, _} = Ezagent.Users.create(owner, "pw-#{uniq()}", [])
      {:ok, _} = Ezagent.SpawnRegistry.spawn(owner)

      worker = spawn_worker(config_dir)
      :ok = AgentLineage.record(worker, owner)
      :ok = record_creation(worker, owner)

      assert {:error, {:worker_teardown_failed, _}} =
               Teardown.reap_spawned_worker(worker, owner, :best_effort)

      assert {:ok, _pid} = KindRegistry.lookup(worker)
      assert {:ok, ^owner} = AgentLineage.lookup(worker)
    end
  end

  describe "delete-session cascade reaps ALL spawned members (SPEC §4.1)" do
    test "Lifecycle.destroy(session) tears down every spawned worker + config_dir + routing + lineage" do
      session_uri = Session.default_uri()
      owner = User.admin_uri()

      cfg_a = "/tmp/f7b-cascade-a-#{uniq()}"
      cfg_b = "/tmp/f7b-cascade-b-#{uniq()}"
      w_a = spawn_worker(cfg_a)
      w_b = spawn_worker(cfg_b)
      :ok = AgentLineage.record(w_a, owner)
      :ok = AgentLineage.record(w_b, owner)
      :ok = record_creation(w_a, owner)
      :ok = record_creation(w_b, owner)
      join_spawned(session_uri, w_a)
      join_spawned(session_uri, w_b)
      _ = add_routing_rule(session_uri, w_a)
      _ = add_routing_rule(session_uri, w_b)

      assert session_rule_ids(session_uri) != []

      Phoenix.PubSub.subscribe(EzagentCore.PubSub, "test:f7b_gc:#{URI.to_string(w_a)}")
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, "test:f7b_gc:#{URI.to_string(w_b)}")

      # Delete via the generic Lifecycle.destroy/2 — the SAME primitive bare
      # `manage.delete` rides: `Manage.handle_delete` → `schedule_delete` →
      # `Ezagent.Lifecycle.destroy(self_uri, :manage_delete)` (manage.ex:87-119,
      # code-verified), which fires Session.destroy/2 → cascade_teardown. So
      # EVERY delete path cascades (not just the UI handler).
      :ok = Ezagent.Lifecycle.destroy(session_uri, :delete)

      assert_receive {:gc_called, ^w_a, ^cfg_a}, 2_000
      assert_receive {:gc_called, ^w_b, ^cfg_b}, 2_000
      assert :gone = wait_until_gone(w_a)
      assert :gone = wait_until_gone(w_b)
      assert session_rule_ids(session_uri) == []
      assert :error == AgentLineage.lookup(w_a)
      assert :error == AgentLineage.lookup(w_b)
    end
  end

  describe "#154-clean — the granted teardown cap has a real owner granter" do
    test "session create grants owner cap(:agent, Sandbox, :destroy, {:spawned_by, owner}) granted_by: owner" do
      owner = URI.new!("entity://system/user/clean-#{uniq()}")
      {:ok, _} = Ezagent.Users.create(owner, "pw-#{uniq()}", [])
      {:ok, _} = Ezagent.SpawnRegistry.spawn(owner)

      assert :ok = Materializer.grant_owner_participant_teardown_cap(owner, @workspace_uri)

      caps = Ezagent.Identity.list_caps_for(owner) |> MapSet.to_list()

      teardown_cap =
        Enum.find(caps, fn
          %Ezagent.Capability{
            kind: :agent,
            behavior: Ezagent.ActionSet.Sandbox,
            instance: {:spawned_by, %URI{} = p}
          } = c ->
            URI.to_string(p) == URI.to_string(owner) and
              Ezagent.Capability.action_of(c) == :destroy

          _ ->
            false
        end)

      assert teardown_cap,
             "owner must hold the {:spawned_by, owner} Sandbox :destroy teardown cap"

      # #154-clean: granted_by is the OWNER (the lineage root) — NOT a forged
      # {:spawned_by, orchestrator} cap minted for an operator.
      assert teardown_cap.granted_by == owner

      refute Enum.any?(caps, fn
               %Ezagent.Capability{instance: {:spawned_by, %URI{} = p}} = c ->
                 Ezagent.URI.type?(p, :agent) and c.granted_by != owner

               _ ->
                 false
             end),
             "no forged/unowned {:spawned_by, _} cap may be minted"
    end
  end

  # Stub Template Class — observes the config-dir GC (and confirms NO orphan).
  defmodule GcStubClass do
    def destroy_config_dir(%URI{} = agent_uri, config_dir) when is_binary(config_dir) do
      Phoenix.PubSub.broadcast(
        EzagentCore.PubSub,
        "test:f7b_gc:#{URI.to_string(agent_uri)}",
        {:gc_called, agent_uri, config_dir}
      )

      :ok
    end
  end

  # Stub whose FS cleanup RAISES — Sandbox.handle_destroy rescues it and returns
  # {destroyed: true, cleanup: {:error, _}} (worker still terminates).
  defmodule RaisingGcStubClass do
    def destroy_config_dir(%URI{} = _agent_uri, _config_dir) do
      raise RuntimeError, "simulated config_dir FS cleanup failure"
    end
  end
end
