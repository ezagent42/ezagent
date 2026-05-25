defmodule Ezagent.Orchestrator.BuildWorkingCopyTest do
  @moduledoc """
  Phase 7 completion PR-2 (SPEC §2 "PR-2") — `Tools.build_working_copy/4`
  rewrite: it now emits a **template-shaped** working-copy slice read
  straight from the Session's durable `template_working_copy` field
  (`Ezagent.Behavior.Chat`), not from live `WorkspaceRegistry` /
  `RuleStore` state.

  `build_working_copy/4` is private; these tests exercise it through the
  public `update_template/1` + `save_template_as/2` tools, observing the
  version hash baked into the returned `template://session/...@<hash>`
  URI. The hash is computed by
  `Ezagent.Entity.SessionTemplate.compute_version_hash/1` over the
  template-shaped slice — so the URI hash is a faithful witness of what
  `build_working_copy/4` produced.

  THE GATE (SPEC §2 PR-2 test list): identical team config in two
  DIFFERENT sessions → `compute_version_hash/1` returns the SAME hash —
  proving `session_uri` is excluded from the hash input.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Behavior.Chat
  alias Ezagent.Entity.{Session, SessionTemplate}
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Orchestrator.Tools

  # Phase 7 completion PR-5 — `save_template_as`/`update_template` now
  # require the orchestrator's cap #3 (`:session_template`
  # `Behavior.Template`, `{:within_workspace, ws}`) at the tool
  # boundary. These build-working-copy tests only exercise the
  # hash-shape of `build_working_copy/4`, so they supply a workspace-
  # scoped cap-#3 set.
  defp caps_3(workspace_uri) do
    MapSet.new([
      %Ezagent.Capability{
        kind: :session_template,
        behavior: Ezagent.Behavior.Template,
        instance: {:within_workspace, workspace_uri},
        workspace_uri: workspace_uri,
        granted_by: URI.parse("entity://user/system/admin"),
        granted_at: DateTime.utc_now()
      }
    ])
  end

  # A live, template-SHAPED working copy: agent_slots carry
  # `template://agent` URIs (the durable source_agent_template_uri),
  # routing receivers are slot NAMES.
  defp sample_working_copy do
    %{
      agent_slots: [
        {"backend", URI.parse("template://agent/system/cc-backend")},
        {"frontend", URI.parse("template://agent/team-alpha/cc-frontend")}
      ],
      routing_rules: [{{:mention, "backend"}, ["backend"]}],
      orchestrator_template_uri: URI.parse("template://agent/system/cc-orchestrator"),
      default_workspace_uri: URI.parse("workspace://team-alpha"),
      description: "two-agent team"
    }
  end

  # Spawn a Session Kind and stamp `working_copy` into its `:chat`
  # slice's `template_working_copy` field (PR-2 has no Generator — PR-4
  # — so the slice is set directly via :sys.replace_state, mirroring
  # what the Generator/orchestrator tools will eventually do).
  defp spawn_session_with_working_copy(session_uri, working_copy) do
    :ok = KindSnapshot.delete(URI.to_string(session_uri))
    {:ok, pid} = Ezagent.Kind.spawn(Session, %{uri: session_uri})

    :sys.replace_state(pid, fn server_state ->
      chat_slice = get_in(server_state, [:state, Chat.state_slice()]) || %{}
      new_chat = Map.put(chat_slice, :template_working_copy, working_copy)
      put_in(server_state, [:state, Chat.state_slice()], new_chat)
    end)

    on_exit(fn ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(EzagentDomainChat.SessionSupervisor, pid)
      end
    end)

    pid
  end

  describe "build_working_copy/4 emits template-shaped slices (via save_template_as/2)" do
    test "emits template://agent URIs + slot-name routing — not live entity://agent URIs" do
      session_uri =
        URI.parse("session://default/team-alpha/bwc-shape-#{System.unique_integer([:positive])}")

      working_copy = sample_working_copy()
      _pid = spawn_session_with_working_copy(session_uri, working_copy)

      assert {:ok, %URI{} = template_uri} =
               Tools.save_template_as("shape-team",
                 session_uri: session_uri,
                 workspace_uri: URI.parse("workspace://team-alpha"),
                 caller: URI.parse("entity://agent/team-alpha/cc_orch"),
                 caps: caps_3(URI.parse("workspace://team-alpha"))
               )

      assert template_uri.scheme == "template"
      assert template_uri.host == "session"

      # The hash baked into the URI must equal compute_version_hash/1
      # over the TEMPLATE-shaped slice — agent_slots as
      # {slot_name, template://agent URI}, routing receivers as slot
      # names. If build_working_copy/4 still emitted live
      # entity://agent URIs (or live RuleStore-derived rows) the hash
      # would differ from this expectation.
      [_name, uri_hash] =
        template_uri.path
        |> String.split("/", trim: true)
        |> List.last()
        |> String.split("@", parts: 2)

      expected_slice = %{
        description: "two-agent team",
        agent_slots:
          Enum.sort([
            {"backend", URI.parse("template://agent/system/cc-backend")},
            {"frontend", URI.parse("template://agent/team-alpha/cc-frontend")}
          ]),
        orchestrator_template_uri: URI.parse("template://agent/system/cc-orchestrator"),
        routing_rules: [{{:mention, "backend"}, ["backend"]}],
        default_workspace_uri: URI.parse("workspace://team-alpha"),
        parent_template_uri: nil,
        created_by: URI.parse("entity://agent/team-alpha/cc_orch")
      }

      assert uri_hash == SessionTemplate.compute_version_hash(expected_slice),
             "build_working_copy/4 must emit a template-shaped slice — agent_slots " <>
               "as {slot_name, template://agent URI}, routing receivers as slot names. " <>
               "The URI hash diverged, meaning the slice shape is wrong."
    end

    test "a Session with no populated working copy emits an empty template-shaped slice" do
      # PR-2 graceful default — a Session whose :chat slice predates
      # PR-2 (no template_working_copy key) reads through
      # Chat.template_working_copy/1 → the empty default; the emitted
      # slice has empty agent_slots / routing_rules, not a crash.
      session_uri =
        URI.parse("session://default/team-alpha/bwc-empty-#{System.unique_integer([:positive])}")

      :ok = KindSnapshot.delete(URI.to_string(session_uri))
      {:ok, pid} = Ezagent.Kind.spawn(Session, %{uri: session_uri})

      on_exit(fn ->
        if Process.alive?(pid) do
          DynamicSupervisor.terminate_child(EzagentDomainChat.SessionSupervisor, pid)
        end
      end)

      assert {:ok, %URI{} = template_uri} =
               Tools.save_template_as("empty-team",
                 session_uri: session_uri,
                 workspace_uri: URI.parse("workspace://team-alpha"),
                 caller: URI.parse("entity://agent/team-alpha/cc_orch"),
                 caps: caps_3(URI.parse("workspace://team-alpha"))
               )

      [_name, uri_hash] =
        template_uri.path
        |> String.split("/", trim: true)
        |> List.last()
        |> String.split("@", parts: 2)

      empty_slice = %{
        description: "",
        agent_slots: [],
        orchestrator_template_uri: URI.parse("template://agent/system/cc-orchestrator"),
        routing_rules: [],
        default_workspace_uri: URI.parse("workspace://team-alpha"),
        parent_template_uri: nil,
        created_by: URI.parse("entity://agent/team-alpha/cc_orch")
      }

      assert uri_hash == SessionTemplate.compute_version_hash(empty_slice)
    end
  end

  describe "THE GATE — identical team config across sessions hashes identically" do
    test "two DIFFERENT sessions with an identical working copy → SAME version hash" do
      working_copy = sample_working_copy()

      session_a =
        URI.parse("session://default/team-alpha/bwc-gate-a-#{System.unique_integer([:positive])}")

      session_b =
        URI.parse("session://default/team-alpha/bwc-gate-b-#{System.unique_integer([:positive])}")

      _pid_a = spawn_session_with_working_copy(session_a, working_copy)
      _pid_b = spawn_session_with_working_copy(session_b, working_copy)

      caller = URI.parse("entity://agent/team-alpha/cc_orch")
      ws = URI.parse("workspace://team-alpha")
      caps = caps_3(ws)

      assert {:ok, uri_a} =
               Tools.save_template_as("gate-team",
                 session_uri: session_a,
                 workspace_uri: ws,
                 caller: caller,
                 caps: caps
               )

      assert {:ok, uri_b} =
               Tools.save_template_as("gate-team",
                 session_uri: session_b,
                 workspace_uri: ws,
                 caller: caller,
                 caps: caps
               )

      hash_a = uri_a.path |> String.split("@", parts: 2) |> List.last()
      hash_b = uri_b.path |> String.split("@", parts: 2) |> List.last()

      assert hash_a == hash_b,
             "Two different sessions with an identical team config produced " <>
               "DIFFERENT version hashes — `session_uri` (or `name`) leaked into " <>
               "the hash input. build_working_copy/4 MUST exclude session_uri + " <>
               "name from the hash-input map (SPEC §1.3)."

      # And the full URIs are identical (same name + same hash + same ws).
      assert URI.to_string(uri_a) == URI.to_string(uri_b)
    end
  end
end
