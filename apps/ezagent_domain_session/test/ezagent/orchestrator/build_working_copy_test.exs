defmodule Ezagent.Orchestrator.BuildWorkingCopyTest do
  @moduledoc """
  `Tools.build_working_copy/4` — the working-copy snapshot the
  `update_template` / `save_template_as` tools persist.

  team-routing-unification §3.8 (PR-8) rewrote it to remove the retired
  `template_working_copy.agent_slots`. P5 then moved team config out of
  SessionTemplate into the installed Socialware definition. A SessionTemplate
  now persists composition/lineage (`installs`, default workspace, parent),
  while `save_template_as/2` snapshots the live team into socialware-def data.

  THE GATE (carried over from PR-2): identical team config in two DIFFERENT
  sessions → identical composition hashes and socialware-def content, proving
  `session_uri` is excluded from both persisted surfaces.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Entity.SessionTemplate
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Orchestrator.Tools
  alias Ezagent.Socialware.DefinitionRegistry

  defp caps_3(workspace_uri) do
    MapSet.new([
      %Ezagent.Capability{
        kind: :session_template,
        behavior: Ezagent.ActionSet.Template,
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

  defp refute_moved_team_fields(content) do
    for key <- [
          :members,
          :prompt_templates,
          :legends,
          :routing_rules,
          :orchestrator_template_uri
        ] do
      refute Map.has_key?(content, key)
      refute Map.has_key?(content, Atom.to_string(key))
    end
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
        get_in(server_state, [:state, SessionBehavior.state_slice()]) ||
          %{state: %{}, transients: %{}}

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

  describe "build_working_copy/4 emits composition-only SessionTemplate content" do
    test "snapshots team config into socialware-def, not SessionTemplate" do
      ws = Ezagent.URI.new!("workspace://team-alpha")
      caller = Ezagent.URI.new!("entity://team-alpha/agent/cc_orch")

      session_uri =
        Ezagent.URI.new!(
          "session://team-alpha/default/bwc-shape-#{System.unique_integer([:positive])}"
        )

      _pid = spawn_session_with_state(session_uri, sample_chat_state())

      assert {:ok, %URI{} = template_uri} =
               Tools.save_template_as("shape-team",
                 session_uri: session_uri,
                 workspace_uri: ws,
                 caller: caller,
                 caps: caps_3(ws)
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
        default_workspace_uri: ws,
        parent_template_uri: nil,
        installs: ["shape-team"],
        name: "shape-team",
        created_by: caller
      }

      assert uri_hash == SessionTemplate.compute_version_hash(expected),
             "build_working_copy/4 must hash composition-only SessionTemplate content."

      assert {:ok, content} = Ezagent.Entity.Session.read_template_content(template_uri)
      assert content.installs == ["shape-team"]
      refute_moved_team_fields(content)

      assert {:ok, definition, _object} = DefinitionRegistry.lookup(ws, "shape-team")
      assert definition.prompt_templates == %{"telephone_hop" => "接龙：{body}"}

      assert definition.legends == %{
               "传话游戏" => %{
                 "member_set" => ["relay-cc"],
                 "bound_rule_set" => "telephone",
                 "fold" => true
               }
             }

      assert definition.routing_rules == []

      assert definition.orchestrator_template_uri ==
               Ezagent.URI.new!("template://system/agent/cc-orchestrator")

      assert [role] = definition.roles
      assert role.role_name == "relay-cc"
      assert role.fill == :agent
      assert role.recipe == "cc-backend"
      assert role.flavor == "cc"
    end

    test "a Session with no team emits composition-only content (no crash)" do
      ws = Ezagent.URI.new!("workspace://team-alpha")
      caller = Ezagent.URI.new!("entity://team-alpha/agent/cc_orch")

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
                 workspace_uri: ws,
                 caller: caller,
                 caps: caps_3(ws)
               )

      [_name, uri_hash] =
        template_uri.path
        |> String.split("/", trim: true)
        |> List.last()
        |> String.split("@", parts: 2)

      empty = %{
        description: "",
        default_workspace_uri: ws,
        parent_template_uri: nil,
        installs: ["empty-team"],
        name: "empty-team",
        created_by: caller
      }

      assert uri_hash == SessionTemplate.compute_version_hash(empty)

      assert {:ok, content} = Ezagent.Entity.Session.read_template_content(template_uri)
      assert content.installs == ["empty-team"]
      refute_moved_team_fields(content)

      assert {:ok, definition, _object} = DefinitionRegistry.lookup(ws, "empty-team")
      assert definition.roles == []
      assert definition.prompt_templates == %{}
      assert definition.legends == %{}
      assert definition.routing_rules == []
    end
  end

  describe "THE GATE — identical config across sessions persists identically" do
    test "two DIFFERENT sessions with an identical team → SAME template hash and socialware-def" do
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

      assert {:ok, definition, _object} = DefinitionRegistry.lookup(ws, "gate-team")
      assert definition.prompt_templates == %{"telephone_hop" => "接龙：{body}"}

      assert [%{role_name: "relay-cc", fill: :agent, recipe: "cc-backend", flavor: "cc"}] =
               definition.roles
    end
  end
end
