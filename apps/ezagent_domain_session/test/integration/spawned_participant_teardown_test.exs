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
  alias Ezagent.Behavior.Session.Teardown
  alias Ezagent.Entity.{Agent, Session, User}
  alias Ezagent.Session.Participants
  alias EzagentDomainInstanceMessage.SessionCreator.Materializer

  @workspace_uri URI.new!("workspace://team-alpha")

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
  defp spawn_worker(config_dir) do
    uri = Ezagent.URI.new!("entity://team-alpha/agent/worker-#{uniq()}")
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: uri})
    :ok = Ezagent.WorkspaceRegistry.bind(uri, @workspace_uri)

    {:ok, _} =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.new!("#{URI.to_string(uri)}?action=sandbox.write_path"),
        mode: :call,
        args: %{config_dir_path: config_dir, template_class: __MODULE__.GcStubClass},
        ctx: %{
          caller: User.admin_uri(),
          caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
          reply: {:caller_inbox, self()}
        }
      })

    uri
  end

  # Join `worker` into `session` carrying the `:source_template_uri` spawn facet
  # (the provenance marker a managed member gets at spawn) under admin authority.
  defp join_spawned(session_uri, worker_uri) do
    tmpl = Ezagent.URI.new!("template://team-alpha/agent/worker-role")

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
        Ezagent.Behavior.Session,
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
      tries == 0 -> :still_alive
      KindRegistry.lookup(uri) == :error -> :gone
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
      join_spawned(session_uri, worker)
      _rule = add_routing_rule(session_uri, worker)

      assert worker in Participants.list_participants(session_uri)
      # lineage records the PARENT (spawned_by): worker -> owner.
      assert {:ok, owner} == AgentLineage.lookup(worker)
      assert session_rule_ids(session_uri) != []

      Phoenix.PubSub.subscribe(
        EzagentCore.PubSub,
        "test:f7b_gc:#{URI.to_string(worker)}"
      )

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

      # Strict reap: the dispatch runs under the OWNER's PERSISTED caps (empty of
      # the teardown cap) → sandbox.destroy is unauthorized → fail-closed.
      assert {:error, {:worker_teardown_failed, _}} =
               Teardown.reap_spawned_worker(worker, owner, :strict)

      # The worker MUST survive (no half-teardown) + lineage intact.
      assert {:ok, _pid} = KindRegistry.lookup(worker)
      assert {:ok, owner} == AgentLineage.lookup(worker)
    end
  end

  describe "dead-orchestrator / junk-session fallback (SPEC §2.4 / §4.2)" do
    test "best-effort reap with an absent owner cap falls back to Lifecycle.destroy" do
      config_dir = "/tmp/f7b-fallback-#{uniq()}"

      owner = URI.new!("entity://system/user/junk-#{uniq()}")
      {:ok, _} = Ezagent.Users.create(owner, "pw-#{uniq()}", [])
      {:ok, _} = Ezagent.SpawnRegistry.spawn(owner)

      worker = spawn_worker(config_dir)
      :ok = AgentLineage.record(worker, owner)

      # best_effort: owner cap absent → VM-internal Lifecycle.destroy primitive
      # reaps the worker anyway (legitimate, not a forged cap).
      assert :ok = Teardown.reap_spawned_worker(worker, owner, :best_effort)

      assert :gone = wait_until_gone(worker)
      assert :error == AgentLineage.lookup(worker)
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
      join_spawned(session_uri, w_a)
      join_spawned(session_uri, w_b)
      _ = add_routing_rule(session_uri, w_a)
      _ = add_routing_rule(session_uri, w_b)

      assert session_rule_ids(session_uri) != []

      Phoenix.PubSub.subscribe(EzagentCore.PubSub, "test:f7b_gc:#{URI.to_string(w_a)}")
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, "test:f7b_gc:#{URI.to_string(w_b)}")

      # Delete via the framework primitive `manage.delete` rides — i.e. the
      # generic Lifecycle.destroy/2, which fires Session.destroy/2 → cascade.
      # (Every delete path cascades, not just the UI handler.)
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
            behavior: Ezagent.Behavior.Sandbox,
            instance: {:spawned_by, %URI{} = p}
          } = c ->
            URI.to_string(p) == URI.to_string(owner) and
              Ezagent.Capability.action_of(c) == :destroy

          _ ->
            false
        end)

      assert teardown_cap, "owner must hold the {:spawned_by, owner} Sandbox :destroy teardown cap"

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
end
