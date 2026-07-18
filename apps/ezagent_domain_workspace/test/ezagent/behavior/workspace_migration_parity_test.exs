defmodule Ezagent.ActionSet.WorkspaceMigrationParityTest do
  @moduledoc """
  Phase 2-c migration parity test (SPEC 2026-05-28 PR #445 §6.2).

  `Ezagent.ActionSet.Workspace` was migrated from the legacy
  `@behaviour Ezagent.ActionSet` + `invoke/4` contract to the new
  `use Ezagent.ActionSet` + per-action `handle_<action>/2` + effect
  grammar. This test pins the semantic surface so a regression
  during downstream Phase-2/3 work surfaces here, BEFORE the
  dispatch-level integration tests catch it (where the diff is
  harder to bisect).

  Coverage — one assertion per action body, organised by action:

    1. `:list_members`   — pure read; returns members list verbatim
    2. `:add_member`     — `{:set, :members, MapSet}` + grant-cap `:dispatch` effect
    3. `:remove_member`  — `{:set, :members, MapSet}`
    4. `:list_templates` — pure read
    5. `:add_template`   — `{:set, :session_templates, map}`
    6. `:remove_template` — `{:set, :session_templates, map}`
    7. `:list_routing_rules` — pure read
    8. `:set_routing_rules` — `{:set, :routing_rules, list}`
    9. `:instantiate`    — pure read (returns children list)
   10. `:create_session` — cross-domain DI lookup (`EzagentDomainInstanceMessage`)
                           via app-env override; verifies the dispatch
                           lands AND the result return shape matches
                           pre-migration behaviour.
   11. `:remove_cross_prefix_members` — classifies + `{:set, :members, MapSet}`

  `:create_agent` is exercised by the existing
  `test/integration/create_agent_dispatch_test.exs` against a live
  Workspace Kind (Template Registry, SpawnRegistry, etc — too much
  setup for a unit test). The legacy unit suite did not directly
  cover `:create_agent` either; we preserve that boundary.

  ## Why drive `handle_<action>/2` directly

  Each test drives the handler with a small ctx + the legacy slice
  shape, then applies the returned effects via
  `Ezagent.ActionSet.apply_effects/2`. This bypasses the runtime
  (no Kind.Server, no Router, no CapBAC, no PubSub) so the
  assertions focus on the HANDLER CONTRACT: given args + slice +
  ctx, what effects + result does the action produce? The runtime
  is tested separately in
  `apps/ezagent_core/test/ezagent/kind/runtime_new_contract_dispatch_test.exs`.

  ## Cross-domain dispatch coverage (`:create_session`)

  The handler calls `EzagentDomainInstanceMessage.SessionCreator.create_session/3` via a
  runtime app-env lookup. To exercise the cross-domain call WITHOUT
  booting the full chat application (heavy: requires `Repo`,
  `SystemPrincipal.Catalog`, plugin registrations…), we install a
  fake facade module via `Application.put_env(:ezagent_domain_workspace,
  :session_facade, FakeFacade)`. The fake module exposes the same
  `create_session/3` signature the real chat domain ships and lets
  us assert on the call ARGUMENTS (workspace_uri pass-through,
  caller pass-through, opts pass-through) — exactly the seams that
  would break if the migration silently dropped them.
  """

  # `async: false` + `DataCase` mirrors the existing workspace
  # behaviour test: the `:add_member` user-member path triggers
  # `ensure_member_kind_spawned/1` → `SpawnRegistry.spawn/1` →
  # `Kind.Snapshot.load_with_fallback/3` which queries the DB
  # (`workspaces` projection). Without the sandbox we crash with
  # `Ecto.Adapters.SQL.Sandbox.OwnershipError`.
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.Workspace, as: WB

  # ---------------------------------------------------------------
  # Fake `EzagentDomainInstanceMessage` facade — recorded calls go via
  # `Process.put({__MODULE__, :calls}, ...)` because each test runs
  # in its own process and the fake's calls accumulate per test.
  # ---------------------------------------------------------------
  defmodule FakeChatFacade do
    @moduledoc false

    def create_session(short_name, %URI{} = creator_uri, opts) do
      send(self(), {:fake_facade_called, short_name, creator_uri, opts})

      workspace_uri = Keyword.fetch!(opts, :workspace_uri)

      # Mirror the real facade's success return: {:ok, session_uri, meta}.
      session_uri =
        Ezagent.URI.new!("session://#{workspace_uri.host}/default/#{short_name}")

      _authority = Ezagent.Test.CapHelper.install_test_authority!(session_uri, :session)

      {:ok, session_uri, %{}}
    end
  end

  defmodule FakeChatFacadeFailure do
    @moduledoc false
    def create_session(_short_name, _creator_uri, _opts), do: {:error, :upstream_boom}
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:ezagent_domain_workspace, :session_facade)
    end)

    :ok
  end

  # ---------------------------------------------------------------
  # Helper: drive a handler + apply effects against a slice; return
  # the legacy-compatible result for assertion convenience. Mirrors
  # the helper in `workspace_test.exs` BUT keeps the dispatch list
  # so we can assert on it (the regular test helper consumed it).
  # ---------------------------------------------------------------
  # Lifecycle migration (SPEC 2026-05-29): `init_slice/1` → `create/1`.
  # The handler tests drive the FLAT durable slice (`:state` container);
  # this builds it via the author's `create/1` (returning `{:ok, state}`),
  # the SAME flat map the pre-Lifecycle `init_slice/1` produced. The
  # macro-emitted two-container `init_slice/1` shape is asserted in its own
  # test below.
  defp slice(args \\ %{}) do
    {:ok, state} = WB.create(args)
    state
  end

  defp dispatch(action, args, ctx, slice) do
    handler = String.to_atom("handle_#{action}")
    read = fn key, default -> Map.get(slice, key, default) end
    ctx_with_read = Map.put(ctx, :read, read)

    case apply(WB, handler, [args, ctx_with_read]) do
      {:ok, result, effects} when is_list(effects) ->
        case Ezagent.ActionSet.apply_effects(effects, slice) do
          {:ok, %{state: new_slice} = buckets} ->
            {:ok, %{result: result, slice: new_slice, buckets: buckets}}

          {:halt, reason, _partial} ->
            {:halt, reason}
        end

      {:error, _} = err ->
        err
    end
  end

  # ---------------------------------------------------------------
  # 1. :list_members — pure read
  # ---------------------------------------------------------------
  describe ":list_members" do
    test "returns the members MapSet as a list" do
      a = Ezagent.URI.new!("entity://system/user/alice")
      b = Ezagent.URI.new!("entity://team-alpha/agent/cc_bot")
      slice = slice(%{members: [a, b]})

      assert {:ok, %{result: %{members: members}, slice: ^slice}} =
               dispatch(:list_members, %{}, %{}, slice)

      # Order isn't guaranteed (MapSet) — compare as sets.
      assert MapSet.new(members) == MapSet.new([a, b])
    end

    test "returns empty list for empty workspace" do
      slice = slice(%{})

      assert {:ok, %{result: %{members: []}, slice: ^slice}} =
               dispatch(:list_members, %{}, %{}, slice)
    end
  end

  # ---------------------------------------------------------------
  # 2. :add_member — :set + :dispatch effect
  # ---------------------------------------------------------------
  describe ":add_member" do
    test "emits {:set, :members, MapSet} effect adding the URI" do
      uri = Ezagent.URI.new!("entity://system/user/admin")
      slice = slice(%{})
      # ctx without self_uri — bypasses prefix check (legacy unit-test
      # surface preserved in `validate_member_prefix/2`).
      ctx = %{}

      assert {:ok, %{slice: new_slice}} = dispatch(:add_member, %{member: uri}, ctx, slice)
      assert MapSet.member?(new_slice.members, uri)
    end

    test "rejects cross-prefix entity URI WITHOUT mutating slice" do
      workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
      member_uri = Ezagent.URI.new!("entity://other-ws/user/leaker")
      slice = slice(%{})
      ctx = %{self_uri: workspace_uri}

      assert {:error, {:cross_workspace_member_not_permitted, ^member_uri, ^workspace_uri}} =
               dispatch(:add_member, %{member: member_uri}, ctx, slice)
    end

    test "agent member: NO :dispatch effect (only users get the grant)" do
      workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_main")
      slice = slice(%{})
      ctx = %{self_uri: workspace_uri}

      assert {:ok, %{buckets: buckets}} =
               dispatch(:add_member, %{member: agent_uri}, ctx, slice)

      assert buckets.dispatches == [],
             "agent members never receive :create_session — no grant dispatch"
    end

    test "user member: emits {:dispatch, %Cmd{action: :grant_cap}} effect" do
      workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
      user_uri = Ezagent.URI.new!("entity://team-alpha/user/alice")
      # Pre-task-#46 `:add_member` pre-spawns the user Kind via
      # `SpawnRegistry.spawn/1` (idempotent + DB-backed). Seed the
      # user row so the spawn finds its projection (same pattern as
      # the existing `workspace_test.exs` add_member tests).
      {:ok, _} = Ezagent.Users.create(user_uri, nil, [])
      slice = slice(%{})
      _authority = install_test_authority!(workspace_uri, :workspace)
      ctx = %{self_uri: workspace_uri}

      assert {:ok, %{buckets: buckets}} =
               dispatch(:add_member, %{member: user_uri}, ctx, slice)

      assert [{:dispatch, %Ezagent.Cmd{} = cmd}] = buckets.dispatches
      # SPEC 2026-06-17 (grant chokepoint): the effect is now built by
      # `Ezagent.Identity.Grant.grant_cap_effect/3`, which pre-bakes the
      # `?action=identity.grant_cap` query onto the target (canonical
      # across all chokepoint wrappers). Router's `annotate_target_with_action`
      # is a no-op when already present, so the dispatch outcome is
      # IDENTICAL to the legacy plain-target form (behavior-preserving).
      assert cmd.target == Ezagent.URI.with_action(user_uri, :identity, :store_cap)
      assert cmd.action == :store_cap

      # The cap carried by the dispatch is the workspace.create_session
      # cap on the workspace URI. This is the "actual side-effect" the
      # legacy code achieved via inline Invocation.dispatch.
      assert %{cap: %Ezagent.Capability{} = cap} = cmd.args
      assert cap.kind == :workspace
      assert cap.behavior == Ezagent.ActionSet.Workspace
      assert cap.action == :create_session
      assert cap.instance == workspace_uri
      assert cap.workspace_uri == workspace_uri

      # Decision #154 (grant chokepoint): the entity `granted_by` is now
      # derived + stamped by the chokepoint — the documented admin
      # fallback (`entity://system/user/admin`), an ENTITY (no more the
      # non-entity `system://template-materialize`).
      assert cap.granted_by == Ezagent.Entity.User.admin_uri()
      assert %URI{scheme: "entity"} = cap.granted_by

      # The Cmd is a fire-and-forget cast (reply :ignore → Router
      # derives :cast mode — Task #46 invariant preserved).
      assert cmd.ctx.reply == :ignore
    end
  end

  # ---------------------------------------------------------------
  # 3. :remove_member — :set effect
  # ---------------------------------------------------------------
  describe ":remove_member" do
    test "emits {:set, :members, MapSet} effect dropping the URI" do
      uri = Ezagent.URI.new!("entity://system/user/admin")
      other = Ezagent.URI.new!("entity://system/user/bob")
      slice = slice(%{members: [uri, other]})

      assert {:ok, %{slice: new_slice}} =
               dispatch(:remove_member, %{member: uri}, %{}, slice)

      refute MapSet.member?(new_slice.members, uri)
      assert MapSet.member?(new_slice.members, other)
    end

    test "removing a non-member is a no-op" do
      uri = Ezagent.URI.new!("entity://system/user/ghost")
      slice = slice(%{})

      assert {:ok, %{slice: new_slice}} =
               dispatch(:remove_member, %{member: uri}, %{}, slice)

      assert MapSet.size(new_slice.members) == 0
    end
  end

  # ---------------------------------------------------------------
  # 4. :list_templates — pure read
  # ---------------------------------------------------------------
  describe ":list_templates" do
    test "returns the session_templates map verbatim" do
      tmpl = %{"class" => "cc.agent", "agent_uri" => "entity://x/agent/y"}
      slice = slice(%{session_templates: %{"cc.agent.demo" => tmpl}})

      assert {:ok, %{result: %{templates: tmpls}, slice: ^slice}} =
               dispatch(:list_templates, %{}, %{}, slice)

      assert tmpls == %{"cc.agent.demo" => tmpl}
    end
  end

  # ---------------------------------------------------------------
  # 5. :add_template — :set effect
  # ---------------------------------------------------------------
  describe ":add_template" do
    test "puts the template into the slice's session_templates" do
      slice = slice(%{})
      tmpl = %{"class" => "py.agent", "agent_uri" => "entity://x/agent/y"}

      assert {:ok, %{slice: new_slice}} =
               dispatch(:add_template, %{name: "py.demo", template: tmpl}, %{}, slice)

      assert new_slice.session_templates == %{"py.demo" => tmpl}
    end

    test "replaces an existing template under the same name (last-write-wins)" do
      tmpl_v1 = %{"v" => 1}
      tmpl_v2 = %{"v" => 2}
      slice = slice(%{session_templates: %{"x" => tmpl_v1}})

      assert {:ok, %{slice: new_slice}} =
               dispatch(:add_template, %{name: "x", template: tmpl_v2}, %{}, slice)

      assert new_slice.session_templates == %{"x" => tmpl_v2}
    end
  end

  # ---------------------------------------------------------------
  # 6. :remove_template — :set effect
  # ---------------------------------------------------------------
  describe ":remove_template" do
    test "drops the named template" do
      slice =
        slice(%{
          session_templates: %{"a" => %{"v" => 1}, "b" => %{"v" => 2}}
        })

      assert {:ok, %{slice: new_slice}} =
               dispatch(:remove_template, %{name: "a"}, %{}, slice)

      assert new_slice.session_templates == %{"b" => %{"v" => 2}}
    end
  end

  # ---------------------------------------------------------------
  # 7. :list_routing_rules — pure read
  # ---------------------------------------------------------------
  describe ":list_routing_rules" do
    test "returns the routing_rules list verbatim" do
      rules = [%{matcher: %{type: "always"}, receivers: ["session://x/default/x"]}]
      slice = slice(%{routing_rules: rules})

      assert {:ok, %{result: %{rules: ^rules}, slice: ^slice}} =
               dispatch(:list_routing_rules, %{}, %{}, slice)
    end
  end

  # ---------------------------------------------------------------
  # 8. :set_routing_rules — :set effect
  # ---------------------------------------------------------------
  describe ":set_routing_rules" do
    test "replaces the routing_rules list wholesale" do
      slice = slice(%{routing_rules: [%{old: true}]})
      new_rules = [%{shiny: 1}, %{shiny: 2}]

      assert {:ok, %{slice: new_slice}} =
               dispatch(:set_routing_rules, %{rules: new_rules}, %{}, slice)

      assert new_slice.routing_rules == new_rules
    end
  end

  # ---------------------------------------------------------------
  # 9. :instantiate — pure read
  # ---------------------------------------------------------------
  describe ":instantiate" do
    test "returns one {:member, URI} tuple per member and {:template, name, data} per template" do
      m1 = Ezagent.URI.new!("entity://system/user/admin")
      m2 = Ezagent.URI.new!("entity://team-alpha/agent/cc_bot")
      tmpl = %{"class" => "py.agent"}

      slice =
        slice(%{
          members: [m1, m2],
          session_templates: %{"x" => tmpl}
        })

      assert {:ok, %{result: %{children: children}, slice: ^slice}} =
               dispatch(:instantiate, %{}, %{}, slice)

      # 2 members + 1 template = 3 children. Members must come first
      # (the action body orders them that way so any session-template
      # member dependencies have spawned by the time the template
      # invokes — preserved from legacy semantics).
      assert length(children) == 3

      member_children = Enum.filter(children, &match?({:member, _}, &1))
      assert length(member_children) == 2

      assert {:template, "x", ^tmpl} = List.last(children)
    end
  end

  # ---------------------------------------------------------------
  # 10. :create_session — cross-domain dispatch via fake facade
  # ---------------------------------------------------------------
  describe ":create_session — cross-domain dispatch" do
    test "calls the configured session facade with the workspace + caller passed through" do
      Application.put_env(:ezagent_domain_workspace, :session_facade, FakeChatFacade)

      workspace_uri = Ezagent.URI.new!("workspace://team-alpha")

      caller =
        Ezagent.URI.new!("entity://team-alpha/user/alice-#{System.unique_integer([:positive])}")

      slice = slice(%{})

      {:ok, _pid} =
        Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: caller, initial_caps: MapSet.new()})

      ctx = %{self_uri: workspace_uri, caller: caller}

      assert {:ok, %{result: result, slice: ^slice}} =
               dispatch(
                 :create_session,
                 %{short_name: "main", template_name: "cc.orchestrator"},
                 ctx,
                 slice
               )

      # Cross-domain call landed with the expected args.
      assert_received {:fake_facade_called, "main", ^caller, opts}
      assert Keyword.fetch!(opts, :workspace_uri) == workspace_uri
      assert Keyword.fetch!(opts, :template_name) == "cc.orchestrator"

      # The returned shape matches the decoupled contract: create returns
      # only the usable session URI; role members are provisioned on route.
      assert %URI{} = result.session_uri
      assert URI.to_string(result.session_uri) == "session://team-alpha/default/main"
      refute Map.has_key?(result, :orchestrator_uri)
      refute Map.has_key?(result, :orchestrator_status)
      refute Map.has_key?(result, :orchestrator_error)
    end

    test "propagates a facade error as {:error, reason}" do
      Application.put_env(:ezagent_domain_workspace, :session_facade, FakeChatFacadeFailure)

      workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
      caller = Ezagent.URI.new!("entity://team-alpha/user/alice")
      slice = slice(%{})
      ctx = %{self_uri: workspace_uri, caller: caller}

      assert {:error, :upstream_boom} =
               dispatch(
                 :create_session,
                 %{short_name: "main", template_name: "cc.orchestrator"},
                 ctx,
                 slice
               )
    end

    test "rejects missing short_name BEFORE touching the facade" do
      # Install the success-facade and assert it is NEVER called when
      # arg validation rejects upstream — the legacy invariant
      # (validate then dispatch) carries forward.
      Application.put_env(:ezagent_domain_workspace, :session_facade, FakeChatFacade)

      workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
      caller = Ezagent.URI.new!("entity://team-alpha/user/alice")
      slice = slice(%{})
      ctx = %{self_uri: workspace_uri, caller: caller}

      assert {:error, :short_name_required} =
               dispatch(
                 :create_session,
                 %{template_name: "cc.orchestrator"},
                 ctx,
                 slice
               )

      refute_received {:fake_facade_called, _, _, _}
    end

    test "rejects missing template_name BEFORE touching the facade" do
      Application.put_env(:ezagent_domain_workspace, :session_facade, FakeChatFacade)

      workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
      caller = Ezagent.URI.new!("entity://team-alpha/user/alice")
      slice = slice(%{})
      ctx = %{self_uri: workspace_uri, caller: caller}

      assert {:error, :template_name_required} =
               dispatch(:create_session, %{short_name: "main"}, ctx, slice)

      refute_received {:fake_facade_called, _, _, _}
    end

    test "rejects missing caller (bad ctx) BEFORE touching the facade" do
      Application.put_env(:ezagent_domain_workspace, :session_facade, FakeChatFacade)

      workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
      slice = slice(%{})
      # no :caller key
      ctx = %{self_uri: workspace_uri}

      assert {:error, {:bad_caller, nil}} =
               dispatch(
                 :create_session,
                 %{short_name: "main", template_name: "cc.orchestrator"},
                 ctx,
                 slice
               )

      refute_received {:fake_facade_called, _, _, _}
    end

    test "errors when the configured facade isn't loaded" do
      # Pointing at a module that doesn't exist — exercises the DI
      # safety net `resolve_session_facade/0` in the action body.
      Application.put_env(:ezagent_domain_workspace, :session_facade, ThisModuleDoesNotExist)

      workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
      caller = Ezagent.URI.new!("entity://team-alpha/user/alice")
      slice = slice(%{})
      ctx = %{self_uri: workspace_uri, caller: caller}

      assert {:error, {:session_facade_unavailable, ThisModuleDoesNotExist}} =
               dispatch(
                 :create_session,
                 %{short_name: "main", template_name: "cc.orchestrator"},
                 ctx,
                 slice
               )
    end
  end

  # ---------------------------------------------------------------
  # 11. :remove_cross_prefix_members — classify + :set
  # ---------------------------------------------------------------
  describe ":remove_cross_prefix_members" do
    test "atomically removes cross-prefix entity members + emits :set effect" do
      workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
      violator = Ezagent.URI.new!("entity://other-ws/user/leaker")
      kept = Ezagent.URI.new!("entity://team-alpha/user/alice")

      slice = slice(%{members: [violator, kept]})
      ctx = %{self_uri: workspace_uri}

      assert {:ok, %{result: result, slice: new_slice}} =
               dispatch(:remove_cross_prefix_members, %{}, ctx, slice)

      assert result.removed == [violator]
      assert result.kept_count == 1
      assert MapSet.size(new_slice.members) == 1
      assert MapSet.member?(new_slice.members, kept)
    end

    test "errors when self_uri is missing" do
      slice = slice(%{members: [Ezagent.URI.new!("entity://x/user/y")]})

      assert {:error, {:missing_self_uri, nil}} =
               dispatch(:remove_cross_prefix_members, %{}, %{}, slice)
    end
  end

  # ---------------------------------------------------------------
  # Behavior contract surface — the macro-derived legacy callbacks
  # ---------------------------------------------------------------
  describe "Behavior contract surface (use Ezagent.ActionSet)" do
    test "new_style?/1 detects the migrated module" do
      assert Ezagent.ActionSet.new_style?(WB)
    end

    test "actions/0 lists the declared actions" do
      assert WB.actions() |> Enum.sort() ==
               [
                 :add_member,
                 :add_template,
                 :assign_role,
                 :create_agent,
                 :create_session,
                 :instantiate,
                 :list_agent_templates,
                 :list_members,
                 :list_routing_rules,
                 :list_session_templates,
                 :list_templates,
                 :remove_cross_prefix_members,
                 :remove_member,
                 :remove_template,
                 :set_routing_rules,
                 :unassign_role,
                 :write_session_templates
               ]
    end

    test "__action_spec__/1 returns spec for each action" do
      for action <- WB.actions() do
        spec = WB.__action_spec__(action)
        assert is_map(spec), "missing spec for #{action}"
        assert spec.name == action
        assert is_map(spec.args)
      end
    end

    test "required_caps/0 preserves the :workspace kind axis (Behavior override)" do
      for {action, cap} <- WB.required_caps() do
        assert cap.kind == :workspace, "wrong kind axis on cap for #{action}"
        assert cap.behavior == WB, "wrong module reference on cap for #{action}"
      end
    end

    test "interface/0 exposes every action with args + modes" do
      iface = WB.interface()

      for action <- WB.actions() do
        assert Map.has_key?(iface, action), "interface/0 missing #{action}"
        action_iface = iface[action]
        assert is_list(action_iface.modes)
        assert is_map(action_iface.args)
      end
    end

    test "state_slice/0 is :workspace" do
      assert WB.state_slice() == :workspace
    end

    test "init_slice/1 builds the two-container Lifecycle slice (create/1 under :state)" do
      # Lifecycle migration (SPEC 2026-05-29 §2.1 / §3): `init_slice/1` is
      # macro-emitted and wraps the author's `create/1` durable map under
      # the `:state` container; `transients` starts empty (Workspace holds
      # no process-bound resource).
      full = WB.init_slice(%{})
      assert %{state: state, transients: %{}} = full
      assert %MapSet{} = state.members
      assert state.session_templates == %{}
      assert state.routing_rules == []

      # create/1 itself returns the flat durable state directly.
      assert {:ok, ^state} = WB.create(%{})
    end

    test "data_owner/1 returns :any (workspace admin grants)" do
      assert WB.data_owner(Ezagent.URI.new!("workspace://anywhere")) == :any
    end
  end
end
