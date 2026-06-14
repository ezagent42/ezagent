defmodule Ezagent.Orchestrator.BuildWorkingCopyTest do
  @moduledoc """
  `Tools.build_working_copy/4` — the working-copy snapshot the
  `update_template` / `save_template_as` tools persist.

  team-routing-unification §3.8 (PR-8) rewrote it: it no longer reads the
  retired `template_working_copy.agent_slots`. A SessionTemplate now
  snapshots the live session's **members** (those with
  `in_session_template: true`), **prompt_templates**, **legends**, and the
  session's rule-set **routing_rules** (the PR-7 SessionTemplate content
  shape). `build_working_copy/4` is private; these tests exercise it through
  the public `save_template_as/2` tool, observing the version hash baked
  into the returned `template://session/...@<hash>` URI.

  THE GATE (carried over from PR-2): identical team config in two DIFFERENT
  sessions → `compute_version_hash/1` returns the SAME hash — proving
  `session_uri` is excluded from the hash input.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Behavior.Session, as: SessionBehavior
  alias Ezagent.Entity.SessionTemplate
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Orchestrator.Tools

  defp caps_3(workspace_uri) do
    MapSet.new([
      %Ezagent.Capability{
        kind: :session_template,
        behavior: Ezagent.Behavior.Template,
        instance: {:within_workspace, workspace_uri},
        workspace_uri: workspace_uri,
        granted_by: Ezagent.URI.new!("entity://system/user/admin"),
        granted_at: DateTime.utc_now()
      }
    ])
  end

  # A member-shaped live :chat slice: one in-session-template member with a
  # role_name + spawn-source facet, a named prompt template, and a legend.
  # The persistent fields `build_working_copy/4` snapshots.
  defp sample_chat_state do
    member_uri = Ezagent.URI.new!("entity://team-alpha/agent/echo_relay-cc")

    %{
      description: "two-agent team",
      members: %{
        member_uri => %{
          online: true,
          role_name: "relay-cc",
          in_session_template: true,
          source_template_uri: Ezagent.URI.new!("template://system/agent/cc-backend")
        }
      },
      prompt_templates: %{"telephone_hop" => "接龙：{body}"},
      legends: %{
        "传话游戏" => %{member_set: ["relay-cc"], bound_rule_set: "telephone", fold: true}
      },
      template_working_copy: %{
        orchestrator_template_uri: Ezagent.URI.new!("template://system/agent/cc-orchestrator")
      }
    }
  end

  # Spawn a Session Kind and stamp `chat_state` into its `:chat` slice's
  # persistent `:state` container.
  defp spawn_session_with_state(session_uri, chat_state) do
    :ok = KindSnapshot.delete(URI.to_string(session_uri))

    {:ok, pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors()
      })

    :sys.replace_state(pid, fn server_state ->
      chat_slice =
        get_in(server_state, [:state, SessionBehavior.state_slice()]) || %{state: %{}, transients: %{}}

      merged = Map.merge(Map.get(chat_slice, :state, %{}), chat_state)
      new_chat = Map.put(chat_slice, :state, merged)
      put_in(server_state, [:state, SessionBehavior.state_slice()], new_chat)
    end)

    on_exit(fn ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, pid)
      end
    end)

    pid
  end

  describe "build_working_copy/4 emits the member-shaped SessionTemplate content" do
    test "snapshots members (in_session_template) + prompt_templates + legends — not slots" do
      session_uri =
        Ezagent.URI.new!(
          "session://team-alpha/default/bwc-shape-#{System.unique_integer([:positive])}"
        )

      _pid = spawn_session_with_state(session_uri, sample_chat_state())

      assert {:ok, %URI{} = template_uri} =
               Tools.save_template_as("shape-team",
                 session_uri: session_uri,
                 workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
                 caller: Ezagent.URI.new!("entity://team-alpha/agent/cc_orch"),
                 caps: caps_3(Ezagent.URI.new!("workspace://team-alpha"))
               )

      assert template_uri.scheme == "template"
      assert template_uri.host == "team-alpha"
      assert Ezagent.URI.type?(template_uri, :session)

      [_name, uri_hash] =
        template_uri.path
        |> String.split("/", trim: true)
        |> List.last()
        |> String.split("@", parts: 2)

      expected = %{
        description: "two-agent team",
        members: [
          %{
            uri: Ezagent.URI.new!("entity://team-alpha/agent/echo_relay-cc"),
            role_name: "relay-cc",
            in_session_template: true,
            source_template_uri: Ezagent.URI.new!("template://system/agent/cc-backend")
          }
        ],
        prompt_templates: %{"telephone_hop" => "接龙：{body}"},
        legends: %{
          "传话游戏" => %{member_set: ["relay-cc"], bound_rule_set: "telephone", fold: true}
        },
        routing_rules: [],
        orchestrator_template_uri: Ezagent.URI.new!("template://system/agent/cc-orchestrator"),
        default_workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
        parent_template_uri: nil,
        created_by: Ezagent.URI.new!("entity://team-alpha/agent/cc_orch")
      }

      assert uri_hash == SessionTemplate.compute_version_hash(expected),
             "build_working_copy/4 must emit the member-shaped SessionTemplate content " <>
               "(members/prompt_templates/legends), not slot tuples. The URI hash diverged."
    end

    test "a Session with no team emits an empty member-shaped slice (no crash)" do
      session_uri =
        Ezagent.URI.new!(
          "session://team-alpha/default/bwc-empty-#{System.unique_integer([:positive])}"
        )

      :ok = KindSnapshot.delete(URI.to_string(session_uri))

      {:ok, pid} =
        Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
          uri: session_uri,
          behaviors: Ezagent.Entity.Session.behaviors()
        })

      on_exit(fn ->
        if Process.alive?(pid) do
          DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, pid)
        end
      end)

      assert {:ok, %URI{} = template_uri} =
               Tools.save_template_as("empty-team",
                 session_uri: session_uri,
                 workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
                 caller: Ezagent.URI.new!("entity://team-alpha/agent/cc_orch"),
                 caps: caps_3(Ezagent.URI.new!("workspace://team-alpha"))
               )

      [_name, uri_hash] =
        template_uri.path
        |> String.split("/", trim: true)
        |> List.last()
        |> String.split("@", parts: 2)

      empty = %{
        description: "",
        members: [],
        prompt_templates: %{},
        legends: %{},
        routing_rules: [],
        orchestrator_template_uri: Ezagent.URI.new!("template://system/agent/cc-orchestrator"),
        default_workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
        parent_template_uri: nil,
        created_by: Ezagent.URI.new!("entity://team-alpha/agent/cc_orch")
      }

      assert uri_hash == SessionTemplate.compute_version_hash(empty)
    end
  end

  describe "THE GATE — identical team config across sessions hashes identically" do
    test "two DIFFERENT sessions with an identical team → SAME version hash" do
      chat_state = sample_chat_state()

      session_a =
        Ezagent.URI.new!(
          "session://team-alpha/default/bwc-gate-a-#{System.unique_integer([:positive])}"
        )

      session_b =
        Ezagent.URI.new!(
          "session://team-alpha/default/bwc-gate-b-#{System.unique_integer([:positive])}"
        )

      _pid_a = spawn_session_with_state(session_a, chat_state)
      _pid_b = spawn_session_with_state(session_b, chat_state)

      caller = Ezagent.URI.new!("entity://team-alpha/agent/cc_orch")
      ws = Ezagent.URI.new!("workspace://team-alpha")
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
             "Two different sessions with an identical team produced DIFFERENT version " <>
               "hashes — `session_uri` leaked into the hash input. build_working_copy/4 " <>
               "MUST exclude session_uri + name from the hash-input map."

      assert URI.to_string(uri_a) == URI.to_string(uri_b)
    end
  end
end
