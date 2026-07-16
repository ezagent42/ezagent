defmodule Ezagent.ActionSet.WorkspaceTest do
  # Task #55 round-2 codex (2026-05-27) — `async: false` + `DataCase`
  # because the post-task-#46 `add_member` action now pre-spawns the
  # member's User Kind via `SpawnRegistry.spawn/1`, which expects the
  # user row in the DB. Tests that drive `:add_member` with a
  # non-admin URI must seed the user.
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.Workspace, as: WB

  # ---------------------------------------------------------------
  # Test helpers — bridge the new `use Ezagent.ActionSet` contract
  # (handler/2 + effects) back to the legacy `invoke/4` return
  # shape these tests originally expressed. Phase 2-c migration
  # (SPEC 2026-05-28 PR #445) replaced `def invoke(:action, slice,
  # args, ctx)` with `def handle_action(args, ctx)` returning
  # `{:ok, result, effects}`. The runtime applies effects against
  # the slice in `Ezagent.ActionSet.apply_effects/2`; we replicate
  # that here so the existing test assertions (which compare
  # slices + result maps) keep working without each test having to
  # learn the effect grammar.
  # ---------------------------------------------------------------

  # Lifecycle migration (SPEC 2026-05-29): `init_slice/1` is now
  # macro-emitted and returns the two-container `%{state: ..., transients:
  # %{}}` shape. The handler-driving tests below operate on the FLAT
  # durable slice (the `:state` container) — they read via `Map.get(slice,
  # key, ...)` and compare slices directly. This helper builds that flat
  # slice via the author's `create/1` (which returns `{:ok, state}`),
  # giving the SAME flat map the pre-Lifecycle `init_slice/1` did. The
  # `describe "create/1"` block below covers the slice-building contract
  # directly; this just keeps every action test driving the flat state.
  defp slice(args \\ %{}) do
    {:ok, state} = WB.create(args)
    state
  end

  defp invoke(action, slice, args, ctx) do
    handler = String.to_atom("handle_#{action}")
    read = fn key, default -> Map.get(slice, key, default) end
    ctx_with_read = Map.put(ctx, :read, read)

    case apply(WB, handler, [args, ctx_with_read]) do
      {:ok, result, effects} when is_list(effects) ->
        case Ezagent.ActionSet.apply_effects(effects, slice) do
          {:ok, %{state: new_slice}} ->
            cond do
              # No mutation + handler returned a result map → legacy
              # 3-tuple shape (`{:ok, slice, result}`).
              new_slice == slice and is_map(result) and result != %{} ->
                {:ok, new_slice, result}

              # Mutation + empty result map → legacy 2-tuple
              # (`{:ok, new_slice}`) — pre-migration `:add_member`,
              # `:remove_member`, `:add_template`, `:remove_template`,
              # `:set_routing_rules` returned this shape.
              new_slice != slice and (result == %{} or result == nil) ->
                {:ok, new_slice}

              # Mutation + result map → legacy 3-tuple
              # (`{:ok, new_slice, result}`) —
              # `:create_agent`, `:remove_cross_prefix_members`.
              new_slice != slice and is_map(result) ->
                {:ok, new_slice, result}

              # No mutation + empty result → bare `:ok`-ish shape;
              # tests don't exercise this branch on Workspace, but
              # surface it for completeness.
              true ->
                {:ok, new_slice, result}
            end

          {:halt, reason, _partial} ->
            {:error, {:halt, reason}}
        end

      {:ok, result} ->
        # Effect-less success — never produced by Workspace handlers
        # today (they all return effect lists, even if `[]`), but
        # mirror the runtime's accommodation.
        {:ok, slice, result}

      {:error, _} = err ->
        err
    end
  end

  describe "create/1 (was init_slice/1 — SPEC 2026-05-29 §3 mapping)" do
    # `init_slice/1` → `create/1` (Lifecycle migration). `create/1` returns
    # the FLAT durable `{:ok, state}`; the macro-emitted `init_slice/1`
    # wraps it in the two-container shape (asserted in the migration parity
    # test). These tests pin the SAME slice-building contract the
    # pre-Lifecycle `init_slice/1` had.
    test "defaults to empty MapSet + empty templates + empty rules" do
      assert {:ok, state} = WB.create(%{})
      assert MapSet.size(state.members) == 0
      assert state.session_templates == %{}
      assert state.routing_rules == []
    end

    test "accepts members as list and converts to MapSet" do
      assert {:ok, state} =
               WB.create(%{
                 members: [
                   Ezagent.URI.new!("entity://system/user/admin"),
                   Ezagent.URI.new!("entity://team-alpha/agent/test_x")
                 ]
               })

      assert MapSet.size(state.members) == 2
    end

    test "accepts members as MapSet directly" do
      uris = MapSet.new([Ezagent.URI.new!("entity://system/user/admin")])
      assert {:ok, state} = WB.create(%{members: uris})
      assert state.members == uris
    end

    test "init_slice/1 wraps create/1 in the two-container Lifecycle shape" do
      assert WB.init_slice(%{}) ==
               %{
                 state: %{members: MapSet.new(), session_templates: %{}, routing_rules: []},
                 transients: %{}
               }
    end
  end

  describe "member actions" do
    test "list_members returns all member URIs" do
      slice =
        slice(%{
          members: [
            Ezagent.URI.new!("entity://system/user/admin"),
            Ezagent.URI.new!("entity://team-alpha/agent/test_x")
          ]
        })

      assert {:ok, ^slice, %{members: members}} = invoke(:list_members, slice, %{}, %{})
      assert length(members) == 2
    end

    test "add_member inserts a new URI" do
      slice = slice(%{})
      uri = Ezagent.URI.new!("entity://system/user/admin")

      assert {:ok, new_slice} = invoke(:add_member, slice, %{member: uri}, %{})
      assert MapSet.member?(new_slice.members, uri)
    end

    test "remove_member drops the URI" do
      uri = Ezagent.URI.new!("entity://system/user/admin")
      slice = slice(%{members: [uri]})

      assert {:ok, new_slice} = invoke(:remove_member, slice, %{member: uri}, %{})
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
      workspace_uri = Ezagent.URI.new!("workspace://h2oslabs")
      member_uri = Ezagent.URI.new!("entity://h2oslabs/user/alice")
      # Task #46 (main) — `:add_member` pre-spawns the user Kind via
      # `SpawnRegistry.spawn/1`, which requires the row in DB. Seed
      # the user before driving the action.
      {:ok, _} = Ezagent.Users.create(member_uri, nil, [])
      slice = slice(%{})
      _authority = install_test_authority!(workspace_uri, :workspace)

      ctx = %{self_uri: workspace_uri}

      assert {:ok, new_slice} = invoke(:add_member, slice, %{member: member_uri}, ctx)
      assert MapSet.member?(new_slice.members, member_uri)
    end

    test "accepts same-prefix agent member" do
      workspace_uri = Ezagent.URI.new!("workspace://h2oslabs")
      member_uri = Ezagent.URI.new!("entity://h2oslabs/agent/cc_main")
      slice = slice(%{})

      ctx = %{self_uri: workspace_uri}

      assert {:ok, new_slice} = invoke(:add_member, slice, %{member: member_uri}, ctx)
      assert MapSet.member?(new_slice.members, member_uri)
    end

    test "rejects cross-prefix user member" do
      workspace_uri = Ezagent.URI.new!("workspace://h2oslabs")
      # The exact violator empirically observed in the h2oslabs row
      # 2026-05-27 02:47 — `entity://system/user/linyilun` inside
      # `workspace://h2oslabs` is a cross-prefix leak.
      member_uri = Ezagent.URI.new!("entity://system/user/linyilun")
      slice = slice(%{})

      ctx = %{self_uri: workspace_uri}

      assert {:error, {:cross_workspace_member_not_permitted, ^member_uri, ^workspace_uri}} =
               invoke(:add_member, slice, %{member: member_uri}, ctx)

      # Slice must be untouched on rejection — no half-applied state.
      assert MapSet.size(slice.members) == 0
    end

    test "rejects cross-prefix agent member" do
      workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
      member_uri = Ezagent.URI.new!("entity://system/agent/cc_main")
      slice = slice(%{})

      ctx = %{self_uri: workspace_uri}

      assert {:error, {:cross_workspace_member_not_permitted, ^member_uri, ^workspace_uri}} =
               invoke(:add_member, slice, %{member: member_uri}, ctx)
    end

    test "rejects non-entity member (system://)" do
      workspace_uri = Ezagent.URI.new!("workspace://system")
      member_uri = Ezagent.URI.new!("system://some-non-entity")
      slice = slice(%{})

      ctx = %{self_uri: workspace_uri}

      assert {:error, {:non_entity_member, ^member_uri, ^workspace_uri}} =
               invoke(:add_member, slice, %{member: member_uri}, ctx)
    end

    test "accepts when ctx.self_uri is missing (unit test surface)" do
      # Preserves the legacy test surface in this file's earlier
      # describe block — `invoke/4` with empty ctx still works for
      # unit tests that drive the action directly. The structural
      # production gate runs through `Kind.Server` which always
      # populates `self_uri`.
      member_uri = Ezagent.URI.new!("entity://system/user/admin")
      slice = slice(%{})

      assert {:ok, new_slice} = invoke(:add_member, slice, %{member: member_uri}, %{})
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
    # `Ezagent.URI.new!/1` + `Ezagent.URI.instance/1` + host
    # allowlist.

    test "rejects 4-segment entity URI (extra path segment)" do
      workspace_uri = Ezagent.URI.new!("workspace://h2oslabs")
      # 4-segment: entity://h2oslabs/user/alice/extra. Hand-construct
      # via URI struct so the test isn't masked by `URI.parse/1`'s own
      # tolerance (production paths typically arrive from RPC / form
      # submit as user-controlled strings).
      member_uri = %URI{
        scheme: "entity",
        host: "user",
        authority: "user",
        path: "/h2oslabs/alice/extra"
      }

      slice = slice(%{})
      ctx = %{self_uri: workspace_uri}

      assert {:error, {:bad_member_uri, ^member_uri}} =
               invoke(:add_member, slice, %{member: member_uri}, ctx)
    end

    test "rejects entity URI with trailing slash" do
      workspace_uri = Ezagent.URI.new!("workspace://h2oslabs")

      member_uri = %URI{
        scheme: "entity",
        host: "user",
        authority: "user",
        path: "/h2oslabs/alice/"
      }

      slice = slice(%{})
      ctx = %{self_uri: workspace_uri}

      assert {:error, {:bad_member_uri, ^member_uri}} =
               invoke(:add_member, slice, %{member: member_uri}, ctx)
    end

    test "rejects entity URI with query string (action=) that masks the prefix check" do
      workspace_uri = Ezagent.URI.new!("workspace://h2oslabs")
      # `entity://system/user/alice?action=identity.grant_cap` —
      # cross-prefix with the query string. Pre-fix the validator
      # didn't strip the query → false-negative on the prefix check.
      # Post-fix: the round-2 codex r2 follow-up rejects ANY member
      # URI carrying a query (regardless of prefix match) as
      # `:bad_member_uri`. Membership identity must be in instance
      # form (no query, no fragment).
      member_uri = Ezagent.URI.new!("entity://system/user/alice?action=identity.grant_cap")

      slice = slice(%{})
      ctx = %{self_uri: workspace_uri}

      assert {:error, {:bad_member_uri, ^member_uri}} =
               invoke(:add_member, slice, %{member: member_uri}, ctx)
    end

    test "rejects SAME-workspace entity URI with query (instance-form required) — codex r2 HIGH-1 follow-up" do
      workspace_uri = Ezagent.URI.new!("workspace://h2oslabs")
      # Same workspace, but with ?action= — pre-codex-r2 this fell
      # through the prefix check (after instance/1 stripped ?action,
      # the workspace segment matched), so the URI landed durable in
      # the slice + Store. Post-fix: rejected as bad_member_uri so the
      # original member_uri (still carrying the query) never reaches
      # persistence.
      member_uri = Ezagent.URI.new!("entity://h2oslabs/user/alice?action=anything")

      slice = slice(%{})
      ctx = %{self_uri: workspace_uri}

      assert {:error, {:bad_member_uri, ^member_uri}} =
               invoke(:add_member, slice, %{member: member_uri}, ctx)
    end

    test "rejects entity URI with #fragment (instance-form required)" do
      workspace_uri = Ezagent.URI.new!("workspace://h2oslabs")
      member_uri = Ezagent.URI.new!("entity://h2oslabs/user/alice#somewhere")

      slice = slice(%{})
      ctx = %{self_uri: workspace_uri}

      assert {:error, {:bad_member_uri, ^member_uri}} =
               invoke(:add_member, slice, %{member: member_uri}, ctx)
    end

    test "rejects entity URI with non-user, non-agent host segment" do
      workspace_uri = Ezagent.URI.new!("workspace://h2oslabs")
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

      slice = slice(%{})
      ctx = %{self_uri: workspace_uri}

      assert {:error, {:bad_member_uri, ^member_uri}} =
               invoke(:add_member, slice, %{member: member_uri}, ctx)
    end

    test "rejects 2-segment entity URI (missing workspace segment)" do
      # `entity://user/alice` — pre-SPEC-v3 shape that should not be
      # admitted. parse!/1 rejects (workspace segment required).
      workspace_uri = Ezagent.URI.new!("workspace://h2oslabs")
      member_uri = %URI{scheme: "entity", host: "user", authority: "user", path: "/alice"}

      slice = slice(%{})
      ctx = %{self_uri: workspace_uri}

      assert {:error, {:bad_member_uri, ^member_uri}} =
               invoke(:add_member, slice, %{member: member_uri}, ctx)
    end
  end

  describe "remove_cross_prefix_members (task #55 codex r2 HIGH-2)" do
    # Dispatch-owned cleanup action. Replaces the mix task's direct
    # `Store.update_members/2` write — that pattern raced concurrent
    # adds + left the slice stale until restart. New action body
    # runs under the Workspace Kind GenServer's serialized message
    # queue so classify-then-mutate is atomic.

    test "atomically removes cross-prefix entity members" do
      workspace_uri = Ezagent.URI.new!("workspace://h2oslabs")
      violator_user = Ezagent.URI.new!("entity://system/user/linyilun")
      violator_agent = Ezagent.URI.new!("entity://other-ws/agent/cc_main")
      legit_user = Ezagent.URI.new!("entity://h2oslabs/user/alice")
      legit_agent = Ezagent.URI.new!("entity://h2oslabs/agent/cc_demo")

      slice =
        slice(%{
          members: [violator_user, violator_agent, legit_user, legit_agent]
        })

      ctx = %{self_uri: workspace_uri}

      assert {:ok, new_slice, %{removed: removed, kept_count: 2}} =
               invoke(:remove_cross_prefix_members, slice, %{}, ctx)

      removed_strs = removed |> Enum.map(&URI.to_string/1) |> Enum.sort()

      assert removed_strs ==
               [URI.to_string(violator_agent), URI.to_string(violator_user)] |> Enum.sort()

      assert MapSet.size(new_slice.members) == 2
      assert MapSet.member?(new_slice.members, legit_user)
      assert MapSet.member?(new_slice.members, legit_agent)
      refute MapSet.member?(new_slice.members, violator_user)
      refute MapSet.member?(new_slice.members, violator_agent)
    end

    test "removes non-entity members (system://, workspace://) too" do
      workspace_uri = Ezagent.URI.new!("workspace://h2oslabs")
      bad_system = Ezagent.URI.new!("system://some-non-entity")
      legit = Ezagent.URI.new!("entity://h2oslabs/user/alice")

      slice = slice(%{members: [bad_system, legit]})
      ctx = %{self_uri: workspace_uri}

      assert {:ok, new_slice, %{removed: [^bad_system], kept_count: 1}} =
               invoke(:remove_cross_prefix_members, slice, %{}, ctx)

      assert MapSet.size(new_slice.members) == 1
      assert MapSet.member?(new_slice.members, legit)
    end

    test "clean workspace returns empty removed list + unchanged slice" do
      workspace_uri = Ezagent.URI.new!("workspace://h2oslabs")
      legit_a = Ezagent.URI.new!("entity://h2oslabs/user/alice")
      legit_b = Ezagent.URI.new!("entity://h2oslabs/agent/cc_demo")

      slice = slice(%{members: [legit_a, legit_b]})
      ctx = %{self_uri: workspace_uri}

      assert {:ok, ^slice, %{removed: [], kept_count: 2}} =
               invoke(:remove_cross_prefix_members, slice, %{}, ctx)
    end

    test "errors when ctx.self_uri is missing (production safety net)" do
      slice = slice(%{members: [Ezagent.URI.new!("entity://system/user/admin")]})

      assert {:error, {:missing_self_uri, nil}} =
               invoke(:remove_cross_prefix_members, slice, %{}, %{})
    end

    test "classifies SAME-workspace URI with ?query as violator — codex r2 HIGH-2 follow-up" do
      # Pre-codex-r2 the cleanup classifier used raw String.split that
      # IGNORED query strings, so a same-workspace URI carrying a
      # query (which the HIGH-1 add_member validator now rejects)
      # would be reported clean by the cleanup pass. Post-fix the
      # cleanup classifier shares the validator's logic — any URI the
      # validator would reject is also classified as a violator here.
      workspace_uri = Ezagent.URI.new!("workspace://h2oslabs")
      non_canonical = Ezagent.URI.new!("entity://h2oslabs/user/alice?action=foo")
      canonical_same = Ezagent.URI.new!("entity://h2oslabs/user/bob")

      slice = slice(%{members: [non_canonical, canonical_same]})
      ctx = %{self_uri: workspace_uri}

      assert {:ok, new_slice, %{removed: removed, kept_count: 1}} =
               invoke(:remove_cross_prefix_members, slice, %{}, ctx)

      assert removed == [non_canonical]
      assert MapSet.member?(new_slice.members, canonical_same)
      refute MapSet.member?(new_slice.members, non_canonical)
    end
  end

  describe "session_template actions" do
    test "add_template + list_templates round-trip" do
      slice = slice(%{})
      tmpl = %{members: ["entity://system/user/admin"], routing_rules: []}

      {:ok, slice2} = invoke(:add_template, slice, %{name: "main", template: tmpl}, %{})

      assert {:ok, ^slice2, %{templates: %{"main" => ^tmpl}}} =
               invoke(:list_templates, slice2, %{}, %{})
    end

    test "remove_template drops by name" do
      slice = slice(%{session_templates: %{"foo" => %{}}})
      {:ok, slice2} = invoke(:remove_template, slice, %{name: "foo"}, %{})
      assert slice2.session_templates == %{}
    end
  end

  describe "routing_rules actions" do
    test "set + list round-trip" do
      slice = slice(%{})
      rules = [%{matcher: %{type: "always"}, receivers: ["session://system/default/main"]}]

      {:ok, slice2} = invoke(:set_routing_rules, slice, %{rules: rules}, %{})

      assert {:ok, ^slice2, %{rules: ^rules}} =
               invoke(:list_routing_rules, slice2, %{}, %{})
    end
  end

  describe "instantiate (north-star action)" do
    test "returns child list with one entry per member" do
      uris = [
        Ezagent.URI.new!("entity://system/user/admin"),
        Ezagent.URI.new!("entity://team-alpha/agent/test_cc-builder")
      ]

      slice = slice(%{members: uris})

      assert {:ok, ^slice, %{children: children}} =
               invoke(:instantiate, slice, %{}, %{})

      assert length(children) == 2

      assert Enum.all?(children, fn {tag, %URI{}} -> tag == :member end)
    end

    test "empty workspace instantiates to empty child list" do
      slice = slice(%{})
      assert {:ok, ^slice, %{children: []}} = invoke(:instantiate, slice, %{}, %{})
    end
  end

  describe "Behavior contract" do
    test "actions/0 lists all actions" do
      # SPEC 2026-05-25-agent-create-cli-gui-parity added `:create_agent`
      # as the 10th action — unified entry for CLI + LV agent creation.
      # SPEC 2026-05-26-session-create-orchestrator-unified Gap C added
      # `:create_session` as the 11th (PR #408 unified CLI + LV).
      # Codex PR #356 r1 CRIT fix: `:create_user` was briefly added here
      # and then moved out to `Ezagent.ActionSet.WorkspaceUserAdmin` to
      # give it a distinct cap subject (the Capability struct has no
      # action axis, so co-locating privileged actions with
      # member-management ones is an escalation surface).
      # Task #55 round-2 codex HIGH-2 added `:remove_cross_prefix_members`
      # as the 12th — dispatch-owned cleanup of legacy violators.
      # Socialware P9 added `:assign_role` / `:unassign_role` for durable
      # workspace responsibility holder assignment.
      assert WB.actions() == [
               :list_members,
               :add_member,
               :remove_member,
               :assign_role,
               :unassign_role,
               :list_templates,
               :list_agent_templates,
               :list_session_templates,
               :write_session_templates,
               :add_template,
               :remove_template,
               :list_routing_rules,
               :set_routing_rules,
               :instantiate,
               :create_agent,
               :create_session,
               :remove_cross_prefix_members
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
