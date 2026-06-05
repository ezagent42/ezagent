defmodule EzagentDomainInstanceMessage.Integration.RepairOrchestratorTest do
  @moduledoc """
  SPEC `docs/superpowers/specs/2026-05-31-orchestrator-startup-atomicity-and-slice-unwrap.md`
  §6 — `EzagentDomainInstanceMessage.repair_orchestrator/1,2` RE-MATERIALIZES the
  session working copy (writes `orchestrator_template_uri` (OTU) +
  `session_template_uri`) THEN runs the §5 atomic gate. This is what
  fixes existing nil-OTU sessions (`main`, `orch-feishu-7429`) that were
  created before the atomic flow set OTU, or whose orchestrator died.

  The old `:restart` path only re-dispatched `template.instantiate` +
  respawned the PTY — it NEVER set OTU. The regression these tests guard:
  after a repair the session's durable working copy MUST carry OTU
  (otherwise `McpServer.from_orchestrator_uri/1` can't rebuild the
  orchestrator context on the next bridge JOIN → `:orchestrator_not_registered`).

  test_mode note: in `:test` env the cc PtyServer short-circuits the real
  claude, so the §5 30s LIVE-join gate is bypassed (the synchronous
  `register_orchestrator_mcp_context` is the readiness signal). The true
  live gate is validated by the e2e, not this unit suite.
  """

  use ExUnit.Case, async: false

  alias Ezagent.{Invocation, KindRegistry}
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{Session, SessionTemplate, User}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    # Default template seed inside the checkout (idempotent) + admin alive.
    :ok = EzagentDomainInstanceMessage.Application.seed_default_session_template_now()
    _ = Ezagent.SpawnRegistry.spawn(User.admin_uri())
    :ok
  end

  describe "repair_orchestrator/1 — re-materializes OTU on a nil-OTU session" do
    test "after clearing OTU, repair restores it + returns :ready" do
      short = "repair-otu-#{System.unique_integer([:positive])}"

      {:ok, session_uri, create_meta} =
        EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(), template_name: "default")

      assert create_meta.orchestrator_status == :ready

      # Simulate the nil-OTU residue (`main` / `orch-feishu-7429`): wipe the
      # orchestrator_template_uri from the durable working copy.
      wc = Session.read_template_working_copy(session_uri)
      assert match?(%URI{}, Map.get(wc, :orchestrator_template_uri)),
             "precondition: a freshly-created session has OTU set"

      cleared = Map.put(wc, :orchestrator_template_uri, nil)
      {:ok, _} = Ezagent.Behavior.Chat.system_set_working_copy(session_uri, cleared)

      assert is_nil(
               Map.get(
                 Session.read_template_working_copy(session_uri),
                 :orchestrator_template_uri
               )
             ),
             "precondition: OTU is now nil (the bug state)"

      # The repair re-materializes OTU from the session's template.
      assert {:ok, ^session_uri, meta} =
               EzagentDomainInstanceMessage.repair_orchestrator(session_uri)

      assert match?(%URI{}, meta.orchestrator_uri)
      assert meta.orchestrator_status == :ready

      repaired_wc = Session.read_template_working_copy(session_uri)

      assert match?(%URI{}, Map.get(repaired_wc, :orchestrator_template_uri)),
             "repair_orchestrator MUST re-write orchestrator_template_uri (the §6 fix)"

      assert match?(%URI{}, Map.get(repaired_wc, :session_template_uri)),
             "repair_orchestrator MUST also re-write session_template_uri"
    end

    test "repair_orchestrator/2 with explicit workspace behaves identically" do
      short = "repair-ws-#{System.unique_integer([:positive])}"

      {:ok, session_uri, _meta} =
        EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(), template_name: "default")

      workspace_uri = Ezagent.URI.entity_workspace_uri(User.admin_uri())

      assert {:ok, ^session_uri, meta} =
               EzagentDomainInstanceMessage.repair_orchestrator(session_uri, workspace_uri)

      assert meta.orchestrator_status == :ready
    end
  end

  describe "repair_orchestrator guards" do
    test "a session URI with no resolvable workspace fails loud" do
      # `repair_orchestrator/2` with nil workspace is an explicit error.
      assert {:error, :repair_requires_workspace} =
               EzagentDomainInstanceMessage.repair_orchestrator(
                 Ezagent.URI.new!("session://system/default/whatever"),
                 nil
               )
    end
  end

  describe "repair must NOT destroy a live session on a re-materialization failure (codex cycle-2 MAJOR #3)" do
    test "a materialization failure during REPAIR leaves the session Kind alive + snapshot intact, sweeping only residue" do
      n = System.unique_integer([:positive])
      template_name = "repair-mat-fail-#{n}"
      role_name = "worker-#{n}"

      # An echo-flavor source AgentTemplate the team member is spawned from.
      source_template_uri = seed_echo_agent_template(n)

      # An ORCHESTRATED SessionTemplate (cc-orchestrator OTU) carrying ONE
      # spawned echo team member — so the repair path re-runs materialization.
      content = orchestrated_team_content(template_name, source_template_uri, role_name)
      _ = persist_session_template(content)

      short = "repair-mat-sess-#{n}"

      # Create the session — succeeds (status :ready), session Kind live.
      assert {:ok, session_uri, create_meta} =
               EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
                 template_name: template_name
               )

      assert create_meta.orchestrator_status == :ready
      assert {:ok, live_pid} = KindRegistry.lookup(session_uri)
      assert Process.alive?(live_pid)

      snapshot_before = KindSnapshot.get(URI.to_string(session_uri))
      assert snapshot_before != nil, "precondition: the live session has a snapshot"

      # Sabotage the source AgentTemplate so the NEXT materialization (during
      # repair) fails: overwrite its content to DROP the `flavor` field →
      # `source_template_flavor/1` returns {:source_template_missing_flavor,_}
      # at materialize time, BEFORE any member respawn (so no residue is even
      # created — the key assertion is the live session survives).
      :ok = overwrite_agent_template_without_flavor(source_template_uri)

      # REPAIR — re-materialization now FAILS.
      assert {:error, _reason} =
               EzagentDomainInstanceMessage.repair_orchestrator(session_uri)

      # ── the live session SURVIVED the failed repair ──────────────────────
      assert {:ok, still_pid} = KindRegistry.lookup(session_uri),
             "repair re-materialization failure must NOT terminate the live session Kind"

      assert Process.alive?(still_pid)
      assert still_pid == live_pid, "the SAME session process is intact (not re-spawned)"

      # snapshot row intact (not deleted by a rollback).
      assert KindSnapshot.get(URI.to_string(session_uri)) != nil,
             "the live session's snapshot must survive a failed repair (no teardown)"

      # the pre-existing materialized member is still a session member.
      slice = chat_slice(session_uri)
      member_uri = Ezagent.Behavior.Chat.role_name_to_uri(slice.members, role_name)

      assert match?(%URI{}, member_uri),
             "the pre-existing team member must remain joined after a failed repair"

      cleanup(session_uri)
      cleanup(member_uri)
      cleanup(create_meta.orchestrator_uri)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp chat_slice(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    %{state: %{chat: %{state: slice}}} = :sys.get_state(pid)
    slice
  end

  defp orchestrated_team_content(template_name, source_template_uri, role_name) do
    %{
      name: template_name,
      description: "orchestrated team for repair-failure test",
      orchestrator_template_uri:
        Ezagent.URI.new!(Ezagent.Orchestrator.CcOrchestratorSeed.template_uri()),
      default_workspace_uri: Ezagent.URI.new!("workspace://system"),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-06-01 00:00:00Z],
      members: [
        %{
          uri: nil,
          role_name: role_name,
          in_session_template: true,
          source_template_uri: source_template_uri
        }
      ],
      prompt_templates: %{},
      legends: %{},
      routing_rules: []
    }
  end

  defp persist_session_template(content) do
    hash = SessionTemplate.compute_version_hash(content)

    _ =
      KindSnapshot.delete(
        URI.to_string(SessionTemplate.build_uri(content.name, hash, workspace: "system"))
      )

    {:ok, uri} = SessionTemplate.persist_version_as_system(content, "system")
    uri
  end

  defp seed_echo_agent_template(n) do
    uri = Ezagent.URI.new!("template://system/agent/repair-seed-#{n}")
    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)
    :ok = write_agent_template_content(uri, %{flavor: "echo"})
    uri
  end

  defp overwrite_agent_template_without_flavor(%URI{} = uri) do
    # Re-write the SAME AgentTemplate Kind's content WITHOUT a flavor field.
    write_agent_template_content(uri, %{})
  end

  defp write_agent_template_content(%URI{} = uri, extra) when is_map(extra) do
    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)

    base = %{
      project_cwd: "/tmp",
      default_caps: [],
      created_by: User.admin_uri(),
      created_at: ~U[2026-06-01 00:00:00Z]
    }

    {:ok, _} =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.new!("#{URI.to_string(uri)}?action=template.write"),
        mode: :call,
        args: %{content: Map.merge(base, extra)},
        ctx: %{
          caller: User.admin_uri(),
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: {:caller_inbox, self()}
        }
      })

    :ok
  end

  defp cleanup(%URI{} = uri) do
    on_exit(fn ->
      case KindRegistry.lookup(uri) do
        {:ok, pid} -> if Process.alive?(pid), do: Process.exit(pid, :kill)
        :error -> :ok
      end
    end)
  end

  defp cleanup(_), do: :ok
end
