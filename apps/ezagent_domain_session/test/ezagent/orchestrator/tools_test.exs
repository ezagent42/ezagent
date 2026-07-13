defmodule Ezagent.Orchestrator.ToolsTest do
  @moduledoc """
  Orchestrator MCP tool-surface invariant test.

  team-routing-unification §3.8 (PR-8) rewrote the surface: the four slot
  tools (`add_agent_slot` / `remove_agent_slot` / `update_agent_template` /
  `write_matcher`) are RETIRED (clean cutover) and replaced by member +
  rule-set oriented tools (`add_managed_member` / `remove_member` /
  `define_rule_set_rule` / `define_prompt_template` / `define_legend`). The
  three template tools (`update_template` / `save_template_as` /
  `list_templates`) are retained.

  This test pins the NEW surface + the authority-creep locks (no `:fork`,
  Decision #141; no `:grant_cap`, Decision #137) + that every declared tool
  has a wired body (missing required ctx surfaces `{:error, {:missing_opt,
  _}}`, never `:not_implemented_yet`).
  """

  use ExUnit.Case, async: true

  alias Ezagent.Orchestrator.Tools

  @expected [
    :add_managed_member,
    :add_participant,
    :update_member_template,
    :remove_member,
    :define_rule_set_rule,
    :define_prompt_template,
    :define_legend,
    :update_template,
    :save_template_as,
    # spec-3 Phase 3: session-level, ledger-tracked re-point to a new template @hash
    :migrate_session,
    :list_templates
  ]

  test "the orchestrator tools are exactly the §3.8 member/rule-set + template set" do
    actual = Tools.tool_names()

    assert MapSet.new(actual) == MapSet.new(@expected),
           "Orchestrator tools diverged from the §3.8 surface. Expected: #{inspect(@expected)}, " <>
             "got: #{inspect(actual)}"
  end

  test "session preflight uses the runtime full behavior/action predicate" do
    session_uri = URI.new!("session://system/generic/full-preflight")
    workspace_uri = URI.new!("workspace://system")

    join_cap = %Ezagent.Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: :join,
      instance: {:within_session, session_uri},
      workspace_uri: workspace_uri,
      granted_by: URI.new!("entity://system/user/admin"),
      granted_at: DateTime.utc_now()
    }

    assert :ok = Tools.preflight_within_session_cap([join_cap], session_uri, :join)

    assert {:error, :unauthorized} =
             Tools.preflight_within_session_cap([join_cap], session_uri, :leave)

    assert {:error, :unauthorized} =
             Tools.preflight_within_session_cap([join_cap], session_uri, :any)
  end

  test "the slot tools are RETIRED (§3.8 clean cutover)" do
    for retired <- [:add_agent_slot, :remove_agent_slot, :update_agent_template, :write_matcher] do
      refute Tools.tool?(retired),
             "Slot tool #{inspect(retired)} is still declared — §3.8 retires it. The " <>
               "orchestrator builds teams via members + rule-sets now."
    end
  end

  test "orchestrator does NOT have a `fork` tool (Decision #141 lock)" do
    refute Tools.tool?(:fork),
           "Orchestrator MUST NOT have a `fork` tool. Fork is a SessionTemplate " <>
             "registry operation; orchestrator uses update_template / save_template_as " <>
             "for in-session template evolution. Decision #141."
  end

  test "orchestrator does NOT have a `grant_cap` tool (Decision #137)" do
    refute Tools.tool?(:grant_cap),
           "Orchestrator MUST NOT have a `grant_cap` tool — cap delegation happens " <>
             "via scope-tuple caps the Generator grants at spawn (Decision #137)."
  end

  test "each declared tool has an implementation function" do
    for tool_name <- Tools.tool_names() do
      assert function_exported?(Tools, tool_name, 0) or
               function_exported?(Tools, tool_name, 1) or
               function_exported?(Tools, tool_name, 2) or
               function_exported?(Tools, tool_name, 3) or
               function_exported?(Tools, tool_name, 4),
             "Tool #{inspect(tool_name)} is declared in tool_names/0 but has no " <>
               "corresponding function — declaration without implementation is a " <>
               "contract violation"
    end
  end

  test "invoke/2 dispatches by tool name; unknown tools surface :unknown_tool error" do
    assert {:error, {:unknown_tool, :totally_made_up}} =
             Tools.invoke(:totally_made_up, [])
  end

  describe "every tool has a wired, dispatch-routed body (missing ctx → :missing_opt)" do
    # Each tool requires the orchestrator's caller context. A tool without
    # it surfaces `{:error, {:missing_opt, _}}` — proving the body is wired
    # through dispatch (NOT a stub).
    test "add_managed_member surfaces :missing_opt for required ctx" do
      assert {:error, {:missing_opt, :caller}} =
               Tools.add_managed_member(
                 URI.new!("template://system/agent/x"),
                 "role-x",
                 true,
                 []
               )
    end

    test "add_participant surfaces :missing_opt for required ctx" do
      assert {:error, {:missing_opt, :caller}} =
               Tools.add_participant("entity://system/user/operator", "operator", [])
    end

    test "manifest import is a separate local/operator-only entry" do
      assert {:error, :local_operator_required} =
               Ezagent.Orchestrator.Tools.Participants.import_participant_manifest(
                 "/etc/passwd",
                 "operator",
                 []
               )
    end

    test "remove_member surfaces :missing_opt for required ctx" do
      assert {:error, {:missing_opt, :caller}} = Tools.remove_member("role-x", [])
    end

    test "update_member_template surfaces :missing_opt for required ctx (PR-6)" do
      assert {:error, {:missing_opt, :caller}} =
               Tools.update_member_template(
                 "role-x",
                 URI.new!("template://system/agent/t2"),
                 []
               )
    end

    test "define_rule_set_rule surfaces :missing_opt without ctx" do
      assert {:error, {:missing_opt, :caller}} =
               Tools.define_rule_set_rule({:mention, "x"}, "role-x", rule_set: "rs")
    end

    test "define_prompt_template surfaces :missing_opt without ctx" do
      assert {:error, {:missing_opt, :caller}} =
               Tools.define_prompt_template("name", "tpl {body}", [])
    end

    test "define_legend surfaces :missing_opt without ctx" do
      assert {:error, {:missing_opt, :caller}} =
               Tools.define_legend("legend", ["role-x"], "rs", true, [])
    end

    test "list_templates surfaces :missing_opt without caps (cap-gated read)" do
      assert {:error, {:missing_opt, :caps}} = Tools.list_templates()
    end

    test "update_template surfaces :missing_opt for session_uri" do
      assert {:error, {:missing_opt, :session_uri}} = Tools.update_template([])
    end

    test "save_template_as surfaces :missing_opt without session_uri" do
      assert {:error, {:missing_opt, :session_uri}} = Tools.save_template_as("x", [])
    end

    test "no tool returns :not_implemented_yet" do
      results = [
        {:list_templates, Tools.list_templates()},
        {:add_managed_member,
         Tools.add_managed_member(URI.new!("template://system/agent/x"), "role-x", true, [])},
        {:add_participant, Tools.add_participant("entity://system/user/operator", "role-x", [])},
        {:update_member_template,
         Tools.update_member_template("role-x", URI.new!("template://system/agent/t2"), [])},
        {:remove_member, Tools.remove_member("role-x", [])},
        {:define_rule_set_rule,
         Tools.define_rule_set_rule({:mention, "x"}, "role-x", rule_set: "rs")},
        {:define_prompt_template, Tools.define_prompt_template("n", "t {body}", [])},
        {:define_legend, Tools.define_legend("l", ["role-x"], "rs", true, [])},
        {:update_template, Tools.update_template([])},
        {:save_template_as, Tools.save_template_as("x", [])}
      ]

      for {name, result} <- results do
        refute match?({:error, :not_implemented_yet}, result),
               "Tool #{name} returns :not_implemented_yet. Got: #{inspect(result)}"
      end
    end
  end

  describe "codex M1 — define_rule_set_rule rejects a non-member role_name" do
    # With no live session at this URI, `read_members` is empty, so any
    # binary `receiver_role_name` that is NOT a magic token fails to resolve
    # to a current member → `{:unknown_member_role, _}`. Pre-fix a
    # URI-shaped string fell through to `Ezagent.URI.parse/1` and bound a
    # NON-MEMBER receiver (the M1 bypass).
    @ctx [
      caller: URI.new!("entity://system/agent/cc_orch-m1"),
      caps: MapSet.new(),
      workspace_uri: URI.new!("workspace://system"),
      session_uri: URI.new!("session://generic/system/no-such-m1")
    ]

    test "a dangling, URI-shaped role_name is rejected (not bound as a non-member)" do
      assert {:error, {:unknown_member_role, "entity://system/agent/not-a-member"}} =
               Tools.define_rule_set_rule(
                 {:mention, "x"},
                 "entity://system/agent/not-a-member",
                 [rule_set: "rs"] ++ @ctx
               )
    end

    test "a plain non-member role_name string is rejected" do
      assert {:error, {:unknown_member_role, "ghost-role"}} =
               Tools.define_rule_set_rule({:mention, "x"}, "ghost-role", [rule_set: "rs"] ++ @ctx)
    end
  end

  describe "codex M3 — define_prompt_template enforces {body}" do
    @ctx3 [
      caller: URI.new!("entity://system/agent/cc_orch-m3"),
      caps: MapSet.new(),
      session_uri: URI.new!("session://generic/system/no-such-m3")
    ]

    test "a template missing {body} is rejected before install" do
      assert {:error, :body_placeholder_required} =
               Tools.define_prompt_template("greet", "hello there", @ctx3)
    end
  end

  describe "update_member_template (PR-6 — member-template swap + regenerate)" do
    # The new tool reuses cap #1 ({:within_session, S}) authority — the same
    # check `add_managed_member` preflights. With NO matching cap, the tool
    # must fail closed BEFORE touching the (non-existent) member.
    @swap_ctx_unauth [
      caller: URI.new!("entity://system/agent/cc_orch-pr6"),
      caps: MapSet.new(),
      workspace_uri: URI.new!("workspace://system"),
      session_uri: URI.new!("session://system/generic/no-such-pr6")
    ]

    test "fails closed (:unauthorized) without the {:within_session, S} cap" do
      assert {:error, :unauthorized} =
               Tools.update_member_template(
                 "role-x",
                 URI.new!("template://system/agent/t2"),
                 @swap_ctx_unauth
               )
    end

    test "with the session cap but no live member, resolves to :unknown_member_role" do
      session_uri = URI.new!("session://system/generic/no-such-pr6")

      caps =
        MapSet.new([
          %Ezagent.Capability{
            kind: :session,
            behavior: :any,
            action: :any,
            instance: {:within_session, session_uri},
            workspace_uri: URI.new!("workspace://system"),
            granted_by: URI.new!("entity://system/user/admin"),
            granted_at: DateTime.utc_now()
          }
        ])

      opts = [
        caller: URI.new!("entity://system/agent/cc_orch-pr6"),
        caps: caps,
        workspace_uri: URI.new!("workspace://system"),
        session_uri: session_uri
      ]

      assert {:error, {:unknown_member_role, "ghost-role"}} =
               Tools.update_member_template(
                 "ghost-role",
                 URI.new!("template://system/agent/t2"),
                 opts
               )
    end
  end

  describe "in-flight template deletion semantics" do
    test "update_template returns :parent_template_deleted when parent hash is gone" do
      parent_uri = URI.new!("template://pr48-test/session/never-registered@deadbeefdeadbeef")
      ws = URI.new!("workspace://pr48-test")

      caps =
        MapSet.new([
          %Ezagent.Capability{
            kind: :session_template,
            behavior: Ezagent.ActionSet.Template,
            instance: {:within_workspace, ws},
            workspace_uri: ws,
            granted_by: URI.new!("entity://system/user/admin"),
            granted_at: DateTime.utc_now()
          }
        ])

      assert {:error, :parent_template_deleted} =
               Tools.update_template(
                 session_uri: URI.new!("session://pr48-test/default/pr48-test"),
                 workspace_uri: ws,
                 caller: URI.new!("entity://pr48-test/agent/test_pr48-orchestrator"),
                 caps: caps,
                 parent_template_uri: parent_uri
               )
    end

    test "save_template_as does NOT call check_parent_alive (design lock)" do
      source = File.read!("lib/ezagent/orchestrator/tools/templates.ex")

      [save_block | _] =
        Regex.scan(~r/def save_template_as.*?\n  end/s, source)
        |> Enum.map(&hd/1)

      refute String.contains?(save_block, "check_parent_alive"),
             "save_template_as MUST NOT call check_parent_alive — save-as is always " <>
               "allowed even when parent is deleted (it records the dead parent as lineage)"
    end
  end
end
