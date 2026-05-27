defmodule Ezagent.Behavior.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.Workspace, as: WB

  describe "init_slice/1" do
    test "defaults to empty MapSet + empty templates + empty rules" do
      slice = WB.init_slice(%{})
      assert MapSet.size(slice.members) == 0
      assert slice.session_templates == %{}
      assert slice.routing_rules == []
    end

    test "accepts members as list and converts to MapSet" do
      slice =
        WB.init_slice(%{
          members: [
            URI.parse("entity://user/system/admin"),
            URI.parse("entity://agent/team-alpha/test_x")
          ]
        })

      assert MapSet.size(slice.members) == 2
    end

    test "accepts members as MapSet directly" do
      uris = MapSet.new([URI.parse("entity://user/system/admin")])
      slice = WB.init_slice(%{members: uris})
      assert slice.members == uris
    end
  end

  describe "member actions" do
    test "list_members returns all member URIs" do
      slice =
        WB.init_slice(%{
          members: [
            URI.parse("entity://user/system/admin"),
            URI.parse("entity://agent/team-alpha/test_x")
          ]
        })

      assert {:ok, ^slice, %{members: members}} = WB.invoke(:list_members, slice, %{}, %{})
      assert length(members) == 2
    end

    test "add_member inserts a new URI" do
      slice = WB.init_slice(%{})
      uri = URI.parse("entity://user/system/admin")

      assert {:ok, new_slice} = WB.invoke(:add_member, slice, %{member: uri}, %{})
      assert MapSet.member?(new_slice.members, uri)
    end

    test "remove_member drops the URI" do
      uri = URI.parse("entity://user/system/admin")
      slice = WB.init_slice(%{members: [uri]})

      assert {:ok, new_slice} = WB.invoke(:remove_member, slice, %{member: uri}, %{})
      assert MapSet.size(new_slice.members) == 0
    end
  end

  describe "add_member workspace-prefix invariant (task #55)" do
    # SPEC v3 §3 — entity URIs are `entity://<type>/<workspace>/<name>`.
    # Workspace's member set MAY ONLY contain entities whose URI prefix
    # matches the workspace (Allen 2026-05-27 directive).
    #
    # The structural check lives in `:add_member` so dispatch-level
    # callers (LV forms, mix tasks, CLI, RPC) all get the same gate.

    test "accepts same-prefix user member" do
      workspace_uri = URI.parse("workspace://h2oslabs")
      member_uri = URI.parse("entity://user/h2oslabs/alice")
      slice = WB.init_slice(%{})

      ctx = %{self_uri: workspace_uri}

      assert {:ok, new_slice} = WB.invoke(:add_member, slice, %{member: member_uri}, ctx)
      assert MapSet.member?(new_slice.members, member_uri)
    end

    test "accepts same-prefix agent member" do
      workspace_uri = URI.parse("workspace://h2oslabs")
      member_uri = URI.parse("entity://agent/h2oslabs/cc_main")
      slice = WB.init_slice(%{})

      ctx = %{self_uri: workspace_uri}

      assert {:ok, new_slice} = WB.invoke(:add_member, slice, %{member: member_uri}, ctx)
      assert MapSet.member?(new_slice.members, member_uri)
    end

    test "rejects cross-prefix user member" do
      workspace_uri = URI.parse("workspace://h2oslabs")
      # The exact violator empirically observed in the h2oslabs row
      # 2026-05-27 02:47 — `entity://user/system/linyilun` inside
      # `workspace://h2oslabs` is a cross-prefix leak.
      member_uri = URI.parse("entity://user/system/linyilun")
      slice = WB.init_slice(%{})

      ctx = %{self_uri: workspace_uri}

      assert {:error, {:cross_workspace_member_not_permitted, ^member_uri, ^workspace_uri}} =
               WB.invoke(:add_member, slice, %{member: member_uri}, ctx)

      # Slice must be untouched on rejection — no half-applied state.
      assert MapSet.size(slice.members) == 0
    end

    test "rejects cross-prefix agent member" do
      workspace_uri = URI.parse("workspace://team-alpha")
      member_uri = URI.parse("entity://agent/system/cc_main")
      slice = WB.init_slice(%{})

      ctx = %{self_uri: workspace_uri}

      assert {:error, {:cross_workspace_member_not_permitted, ^member_uri, ^workspace_uri}} =
               WB.invoke(:add_member, slice, %{member: member_uri}, ctx)
    end

    test "rejects non-entity member (system://)" do
      workspace_uri = URI.parse("workspace://system")
      member_uri = URI.parse("system://workspace-loader")
      slice = WB.init_slice(%{})

      ctx = %{self_uri: workspace_uri}

      assert {:error, {:non_entity_member, ^member_uri, ^workspace_uri}} =
               WB.invoke(:add_member, slice, %{member: member_uri}, ctx)
    end

    test "accepts when ctx.self_uri is missing (unit test surface)" do
      # Preserves the legacy test surface in this file's earlier
      # describe block — `invoke/4` with empty ctx still works for
      # unit tests that drive the action directly. The structural
      # production gate runs through `Kind.Server` which always
      # populates `self_uri`.
      member_uri = URI.parse("entity://user/system/admin")
      slice = WB.init_slice(%{})

      assert {:ok, new_slice} = WB.invoke(:add_member, slice, %{member: member_uri}, %{})
      assert MapSet.member?(new_slice.members, member_uri)
    end
  end

  describe "add_member URI canonicalization (task #55 codex r2 HIGH-1)" do
    # Pre-fix: `String.split(rest, "/", parts: 2)` accepted 3+ segment
    # entity URIs, trailing slashes, and query strings — the latter
    # two slipping through because `parts: 2` globbed everything past
    # the workspace segment into `entity_name` regardless of shape.
    # Plus the validator only checked `scheme: "entity"`, never that
    # `host in ["user", "agent"]`. Post-fix: canonicalize via
    # `Ezagent.URI.parse!/1` + `Ezagent.URI.instance/1` + host
    # allowlist.

    test "rejects 4-segment entity URI (extra path segment)" do
      workspace_uri = URI.parse("workspace://h2oslabs")
      # 4-segment: entity://user/h2oslabs/alice/extra. Hand-construct
      # via URI struct so the test isn't masked by `URI.parse/1`'s own
      # tolerance (production paths typically arrive from RPC / form
      # submit as user-controlled strings).
      member_uri = %URI{
        scheme: "entity",
        host: "user",
        authority: "user",
        path: "/h2oslabs/alice/extra"
      }

      slice = WB.init_slice(%{})
      ctx = %{self_uri: workspace_uri}

      assert {:error, {:bad_member_uri, ^member_uri}} =
               WB.invoke(:add_member, slice, %{member: member_uri}, ctx)
    end

    test "rejects entity URI with trailing slash" do
      workspace_uri = URI.parse("workspace://h2oslabs")
      member_uri = %URI{
        scheme: "entity",
        host: "user",
        authority: "user",
        path: "/h2oslabs/alice/"
      }

      slice = WB.init_slice(%{})
      ctx = %{self_uri: workspace_uri}

      assert {:error, {:bad_member_uri, ^member_uri}} =
               WB.invoke(:add_member, slice, %{member: member_uri}, ctx)
    end

    test "rejects entity URI with query string (action=) that masks the prefix check" do
      workspace_uri = URI.parse("workspace://h2oslabs")
      # `entity://user/system/alice?action=identity.grant_cap` —
      # cross-prefix with the query string. Pre-fix the validator
      # didn't strip the query → false-negative on the prefix check.
      # Post-fix `instance/1` strips ?query so the cross-prefix is
      # caught.
      member_uri = URI.parse("entity://user/system/alice?action=identity.grant_cap")

      slice = WB.init_slice(%{})
      ctx = %{self_uri: workspace_uri}

      # After instance/1 strips ?action, the URI's workspace segment is
      # `system`, the workspace's name is `h2oslabs` → cross-workspace.
      assert {:error, {:cross_workspace_member_not_permitted, ^member_uri, ^workspace_uri}} =
               WB.invoke(:add_member, slice, %{member: member_uri}, ctx)
    end

    test "rejects entity URI with non-user, non-agent host segment" do
      workspace_uri = URI.parse("workspace://h2oslabs")
      # `entity://something_weird/h2oslabs/alice` — SPEC v3 §3.3 says
      # the type axis is `user | agent`; pre-fix the validator only
      # matched `scheme: "entity"`, never the host. Post-fix the host
      # allowlist rejects.
      member_uri = %URI{
        scheme: "entity",
        host: "something_weird",
        authority: "something_weird",
        path: "/h2oslabs/alice"
      }

      slice = WB.init_slice(%{})
      ctx = %{self_uri: workspace_uri}

      assert {:error, {:bad_member_uri, ^member_uri}} =
               WB.invoke(:add_member, slice, %{member: member_uri}, ctx)
    end

    test "rejects 2-segment entity URI (missing workspace segment)" do
      # `entity://user/alice` — pre-SPEC-v3 shape that should not be
      # admitted. parse!/1 rejects (workspace segment required).
      workspace_uri = URI.parse("workspace://h2oslabs")
      member_uri = %URI{scheme: "entity", host: "user", authority: "user", path: "/alice"}

      slice = WB.init_slice(%{})
      ctx = %{self_uri: workspace_uri}

      assert {:error, {:bad_member_uri, ^member_uri}} =
               WB.invoke(:add_member, slice, %{member: member_uri}, ctx)
    end
  end

  describe "session_template actions" do
    test "add_template + list_templates round-trip" do
      slice = WB.init_slice(%{})
      tmpl = %{members: ["entity://user/system/admin"], routing_rules: []}

      {:ok, slice2} = WB.invoke(:add_template, slice, %{name: "main", template: tmpl}, %{})

      assert {:ok, ^slice2, %{templates: %{"main" => ^tmpl}}} =
               WB.invoke(:list_templates, slice2, %{}, %{})
    end

    test "remove_template drops by name" do
      slice = WB.init_slice(%{session_templates: %{"foo" => %{}}})
      {:ok, slice2} = WB.invoke(:remove_template, slice, %{name: "foo"}, %{})
      assert slice2.session_templates == %{}
    end
  end

  describe "routing_rules actions" do
    test "set + list round-trip" do
      slice = WB.init_slice(%{})
      rules = [%{matcher: %{type: "always"}, receivers: ["session://default/system/main"]}]

      {:ok, slice2} = WB.invoke(:set_routing_rules, slice, %{rules: rules}, %{})

      assert {:ok, ^slice2, %{rules: ^rules}} =
               WB.invoke(:list_routing_rules, slice2, %{}, %{})
    end
  end

  describe "instantiate (north-star action)" do
    test "returns child list with one entry per member" do
      uris = [
        URI.parse("entity://user/system/admin"),
        URI.parse("entity://agent/team-alpha/test_cc-builder")
      ]

      slice = WB.init_slice(%{members: uris})

      assert {:ok, ^slice, %{children: children}} =
               WB.invoke(:instantiate, slice, %{}, %{})

      assert length(children) == 2

      assert Enum.all?(children, fn {tag, %URI{}} -> tag == :member end)
    end

    test "empty workspace instantiates to empty child list" do
      slice = WB.init_slice(%{})
      assert {:ok, ^slice, %{children: []}} = WB.invoke(:instantiate, slice, %{}, %{})
    end
  end

  describe "Behavior contract" do
    test "actions/0 lists all 11 actions" do
      # SPEC 2026-05-25-agent-create-cli-gui-parity added `:create_agent`
      # as the 10th action — unified entry for CLI + LV agent creation.
      # SPEC 2026-05-26-session-create-orchestrator-unified Gap C added
      # `:create_session` as the 11th (PR #408 unified CLI + LV).
      # Codex PR #356 r1 CRIT fix: `:create_user` was briefly added here
      # and then moved out to `Ezagent.Behavior.WorkspaceUserAdmin` to
      # give it a distinct cap subject (the Capability struct has no
      # action axis, so co-locating privileged actions with
      # member-management ones is an escalation surface).
      assert WB.actions() == [
               :list_members,
               :add_member,
               :remove_member,
               :list_templates,
               :add_template,
               :remove_template,
               :list_routing_rules,
               :set_routing_rules,
               :instantiate,
               :create_agent,
               :create_session
             ]
    end

    test "required_caps/0 has an entry per action" do
      caps = WB.required_caps()

      for action <- WB.actions() do
        assert Map.has_key?(caps, action),
               "required_caps/0 missing #{action} — dispatch step 5.5 would crash"
      end
    end

    test "state_slice/0 is :workspace" do
      assert WB.state_slice() == :workspace
    end

    test "interface/0 covers every action in actions/0" do
      iface = WB.interface()

      for action <- WB.actions() do
        assert Map.has_key?(iface, action), "interface/0 missing #{action}"
      end
    end
  end
end
