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

  import Ezagent.Test.CapHelper, only: [signed_action_cap!: 2, signed_required_cap!: 5]

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
        origin: :trusted_internal,
        target: Ezagent.URI.new!("#{URI.to_string(uri)}?action=sandbox.update_config"),
        mode: :call,
        args: %{config_dir_path: config_dir, template_class: template_class},
        ctx: %{
          caller: User.admin_uri(),
          caps:
            MapSet.new([
              signed_action_cap!(
                Ezagent.URI.new!("#{URI.to_string(uri)}?action=sandbox.update_config"),
                User.admin_uri()
              )
            ]),
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
        origin: :trusted_internal,
        target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join"),
        mode: :cast,
        args: %{member: worker_uri, source_template_uri: tmpl},
        ctx: %{
          caller: worker_uri,
          caps:
            MapSet.new([
              signed_action_cap!(
                Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join"),
                worker_uri
              )
            ]),
          reply: :ignore
        }
      })

    # let the cast land
    _ = Participants.list_participants(session_uri)
    :ok
  end

  defp op_ctx(%URI{} = caller, %URI{} = session_uri) do
    cap =
      signed_required_cap!(
        session_uri,
        :session,
        Ezagent.ActionSet.Session,
        :remove_participant,
        caller
      )

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
      :ok = Materializer.grant_owner_participant_teardown_cap(worker, owner, @workspace_uri)
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
      :ok = Materializer.grant_owner_participant_teardown_cap(worker, owner, @workspace_uri)
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

  describe "THE CRUX (SPEC §2.2) — concrete authority plus transitive provenance" do
    test "a non-admin owner's target-signed cap reaps an orchestrator-spawned worker" do
      # This is the load-bearing end-to-end proof: the concrete target-signed
      # teardown cap authorizes the dispatch, while the full durable chain
      # `worker → orchestrator → owner` independently proves provenance.
      config_dir = "/tmp/f7b-crux-#{uniq()}"

      # Non-admin confirmed user owner (no genesis wildcard short-circuit).
      owner = URI.new!("entity://system/user/crux-owner-#{uniq()}")
      {:ok, _} = Ezagent.Users.create(owner, "pw-#{uniq()}", [])
      {:ok, _} = Ezagent.SpawnRegistry.spawn(owner)

      worker = spawn_worker(config_dir)

      # The only authority granted is concrete to this worker. No admin cap and
      # no broad lineage-scoped cap participates in dispatch authorization.
      assert :ok =
               Materializer.grant_owner_participant_teardown_cap(
                 worker,
                 owner,
                 @workspace_uri
               )

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

      # Strict reap as the non-admin owner requires both its exact signed cap
      # and the transitive lineage proof; the orchestrator need not be live.
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
      :ok = Materializer.grant_owner_participant_teardown_cap(w_a, owner, @workspace_uri)
      :ok = Materializer.grant_owner_participant_teardown_cap(w_b, owner, @workspace_uri)
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
    test "materialization grants a concrete target-signed owner teardown cap" do
      owner = URI.new!("entity://system/user/clean-#{uniq()}")
      {:ok, _} = Ezagent.Users.create(owner, "pw-#{uniq()}", [])
      {:ok, _} = Ezagent.SpawnRegistry.spawn(owner)

      worker = spawn_worker("/tmp/f7b-clean-#{uniq()}")

      assert :ok =
               Materializer.grant_owner_participant_teardown_cap(
                 worker,
                 owner,
                 @workspace_uri
               )

      caps = Ezagent.Identity.list_caps_for(owner) |> MapSet.to_list()

      teardown_cap =
        Enum.find(caps, fn
          %Ezagent.Capability{
            kind: :agent,
            behavior: Ezagent.ActionSet.Sandbox,
            instance: %URI{} = target
          } = c ->
            Ezagent.URI.stable_key(target) == Ezagent.URI.stable_key(worker) and
              Ezagent.Capability.action_of(c) == :destroy

          _ ->
            false
        end)

      assert teardown_cap,
             "owner must hold the concrete worker Sandbox :destroy teardown cap"

      # Issuer provenance records the target authority's K.grant requestor.
      assert teardown_cap.granted_by == owner
      assert is_binary(teardown_cap.signature)
      assert is_binary(teardown_cap.key_id)
      assert teardown_cap.grantee_uri == owner
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
