defmodule EzagentPluginKanban.Integration.KanbanTeamRelayBackTest do
  @moduledoc """
  S3 relay-back integration gate — proves the kanban Definition's
  content-triggered relay rule (the VERBATIM `routing_rules` shipped in the
  deploy-seed manifest YAML, loaded via `ShippedManifest.load!/2`) (a) installs into the live
  session route table at materialize and (b) routes a `__done__`-marked message to
  the pm role while a plain message does NOT. Content-triggered — no sender-lock,
  no instance URI.

  ## Materializes the REAL shipped team (active flavors swapped to a bare stub)

  The shipped kanban-team declares two active agent roles — `kanban-assistant`
  and `dev-together` — plus a passive `kanban-manager` board role. Both active
  roles materialize and join the session; the board materializes as an
  owner-resolvable data actor but remains outside membership, preserving RF-6.

  The ONLY deviation from the shipped body: this fixture swaps each slot's flavor
  `cc-headless` → a bare-spawn stub flavor (a `StubTemplate` that spawns a plain
  `Entity.Agent`, the `definition_agents_materialize_test` pattern), because a
  `cc-headless` spawn starts a Python Claude SDK sidecar (an S6 e2e concern, not a
  routing concern). role_name / recipe / the REAL relay `routing_rules` are the
  shipped ones — the fixture derives them from the shipped manifest YAML
  (`ShippedManifest.load!/2`), not hand-written. The full cc-headless team + SDK spawn is exercised by the S6
  browser e2e.

  Self-containment (spec §11): kanban test tree (NOT `apps/ezagent_domain_session/
  test/`), `EzagentCore.DataCase` (exposed downstream; the domain's own DataCase
  is not), domain started at setup — the `role_native_create_test` pattern.

  The load-bearing contrast with a sender-lock relay: materialize spawns the
  pm/dev members at RANDOM UUID URIs (#1180), yet the installed live rule still
  carries only the `text_contains "__done__"` matcher + a `{:role,
  "kanban-assistant"}` receiver — zero participant instance URI.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.AgentFlavorRegistry
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.Message
  alias Ezagent.Routing.{Matcher, Receiver, Resolver, RuleStore}
  alias Ezagent.Socialware.{Definition, DefinitionRegistry, ManifestResolver, ShippedManifest}
  alias EzagentDomainInstanceMessage.SessionCreator.TemplateTeam
  alias EzagentPluginKanban.Application

  @workspace Ezagent.URI.workspace(:system)
  @stub_flavor "kanban-relay-itest-bare"
  @itest_definition "kanban-team-relay-itest"

  # A bare Entity.Agent Template Class (no config dir, no SDK sidecar) — copied
  # from `definition_agents_materialize_test`'s StubTemplate. Lets a role slot
  # materialize as a plain agent that joins with its role facet, which is all the
  # relay ROUTING needs (the real cc-headless spawn is an S6 e2e concern).
  defmodule StubTemplate do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl Ezagent.Kind.Template
    def template_name, do: "kanban_relay_itest.stub"

    @impl Ezagent.Kind.Template
    def validate(%{"class" => "kanban_relay_itest.stub", "agent_uri" => agent_uri, "cwd" => cwd})
        when is_binary(agent_uri) and is_binary(cwd),
        do: :ok

    def validate(_), do: {:error, :invalid_kanban_relay_itest_stub_template}

    @impl Ezagent.Kind.Template
    def instantiate(_name, data, _workspace_uri) do
      uri = Ezagent.URI.new!(data["agent_uri"])

      case Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
             uri: uri,
             behaviors: Ezagent.Entity.Agent.base_behaviors(),
             role: data["role"]
           }) do
        {:ok, _pid} -> {:ok, [uri], %{fresh?: true, config_dir_path: nil}}
        {:error, {:already_started, _pid}} -> {:ok, [uri], %{fresh?: false}}
        {:error, {:already_registered, _}} -> {:ok, [uri], %{fresh?: false}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  setup do
    {:ok, _} = Elixir.Application.ensure_all_started(:ezagent_domain_session)
    {:ok, _} = Elixir.Application.ensure_all_started(:ezagent_plugin_kanban)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    # Bare-spawn stub flavor (Entity.Agent, no template class → no config dir, no
    # SDK sidecar) — the same seam `role_native_create_test` uses.
    :ok =
      AgentFlavorRegistry.register(%{
        flavor: @stub_flavor,
        kind: Ezagent.Entity.Agent,
        template_class: StubTemplate
      })

    # Seed the pm/dev recipes into ConfigStore so the materializer's fail-closed
    # `lookup_recipe` resolves them (flavor comes from the ROLE SLOT, not the
    # recipe — recipes are flavor-agnostic).
    Enum.each(Application.roles(), fn recipe ->
      assert {:ok, _} = Ezagent.Agent.RecipeRegistry.seed_role_if_absent(recipe)
    end)

    :ok = Ezagent.Agent.RecipeRegistry.flush_cache()

    # Seed the shipped-role fixture Definition (pm + dev with stub flavor plus
    # passive board) carrying the REAL relay `routing_rules`.
    assert {:ok, _} =
             DefinitionRegistry.seed_definition_if_absent(
               itest_definition_body(),
               workspace_uri: @workspace,
               actor_uri: Ezagent.URI.user(:system, :admin)
             )

    session_uri =
      Ezagent.URI.session("system", "kanban", "relay-#{System.unique_integer([:positive])}")

    {:ok, _pid} = Ezagent.Kind.spawn(Session, %{uri: session_uri, behaviors: Session.behaviors()})
    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace)
    on_exit(fn -> terminate(session_uri) end)

    {:ok, session_uri: session_uri}
  end

  test "materialize installs the shipped content-triggered relay rule; routes __done__ to the pm role",
       %{session_uri: session_uri} do
    granted_by = User.admin_uri()

    assert :ok =
             TemplateTeam.materialize_template_team(
               session_uri,
               @workspace,
               {granted_by, granted_by},
               %{installs: [@itest_definition]}
             )

    # #1180 spawns members at RANDOM UUIDs — resolve URIs by role AFTER
    # materialize via the `:member_by_role` edge resolver (a lookup, not a
    # deterministic planned URI).
    pm_uri = member_uri_for_role(session_uri, "kanban-assistant")
    dev_uri = member_uri_for_role(session_uri, "dev-together")
    board_uri = composition_target(session_uri)
    on_exit(fn -> Enum.each([pm_uri, dev_uri, board_uri], &terminate/1) end)

    # Both role-slots really JOINED (member_by_role only resolves a URI for a
    # joined member) — no RF-6 passive-join gate hit, because neither slot is the
    # passive kanban-manager (the S2 modeling fix). This is the "2 roles join" gate.
    assert %URI{} = pm_uri
    assert %URI{} = dev_uri
    assert %URI{} = board_uri
    assert member_uri_for_role(session_uri, "board") == nil

    bindings = Ezagent.Socialware.CompositionBinding.for_session(session_uri)
    assert length(bindings) == 20

    assert Enum.all?(
             bindings,
             &(&1.status == :active and &1.target_uri == URI.to_string(board_uri))
           )

    assert eventually(fn ->
             pm_uri
             |> Ezagent.Identity.list_caps_for()
             |> Enum.count(&(&1.behavior == Ezagent.ActionSet.Kanban)) == 20
           end)

    pm_caps = Ezagent.Identity.list_caps_for(pm_uri)

    refute Enum.any?(
             Ezagent.Identity.list_caps_for(dev_uri),
             &(&1.behavior == Ezagent.ActionSet.Kanban)
           )

    assert Enum.all?(Enum.filter(pm_caps, &(&1.behavior == Ezagent.ActionSet.Kanban)), fn cap ->
             cap.instance == board_uri and cap.granted_by == granted_by
           end)

    assert {:ok, %{tree: %{nodes: %{}}}} =
             Ezagent.Router.dispatch(
               Ezagent.Cmd.new(
                 Ezagent.URI.with_action(board_uri, :kanban, :get_tree),
                 :get_tree,
                 %{},
                 %{
                   mode: :call,
                   caller: pm_uri,
                   caps: pm_caps,
                   reply: {:caller_inbox, self()}
                 }
               )
             )

    # (a) the installed live rule is content-triggered + zero URI (NOT sender-locked).
    table = Resolver.default_routing_table()
    rule = RuleStore.find_by_identity(table, session_uri, "relay-back", 0)
    assert %RuleStore{} = rule

    assert rule.matcher_data == %{
             "type" => "and",
             "items" => [
               %{"type" => "text_contains", "arg" => "__done__"},
               %{"type" => "from_role", "arg" => "dev-together"}
             ]
           }

    assert Enum.map(rule.receivers, &Receiver.decode_from_store/1) == [
             {:role, "kanban-assistant"}
           ]

    # sharp anti-sender-lock proof: the spawned pm/dev UUID URIs appear NOWHERE
    # in the live rule (matcher OR receivers).
    live_rule_inspect = inspect({rule.matcher_data, rule.receivers})
    refute live_rule_inspect =~ URI.to_string(pm_uri)
    refute live_rule_inspect =~ URI.to_string(dev_uri)
    refute live_rule_inspect =~ ~r{entity://[^/]+/(agent|user)/}

    # the matcher fires on the `__done__` marker, not on a plain message.
    {:ok, matcher} = Matcher.from_json(rule.matcher_data)

    # #1212 from_role 腿需要 ctx.members（运行期由 Resolver 注入成员边；测试手工给）
    ctx = %{members: %{dev_uri => %{role_name: "dev-together"}}}
    assert Matcher.match?(matcher, msg(dev_uri, "card 3 → test __done__"), ctx)
    refute Matcher.match?(matcher, msg(dev_uri, "still working"), ctx)
    # 硬锁验证：非 dev-together 角色成员发同标记不触发
    refute Matcher.match?(matcher, msg(dev_uri, "card 3 → test __done__"), %{
             members: %{dev_uri => %{role_name: "kanban-assistant"}}
           })

    # (b) end-to-end: a `__done__` message resolves to the pm role; a plain one
    # does not. The {:role, "kanban-assistant"} receiver expands via the runtime
    # role resolver (session membership-edge lookup, #1185-stable).
    members = [dev_uri, pm_uri]
    role_resolver = role_resolver_for(session_uri)

    # The installed rule is workspace-scoped (workspace://system); pass the
    # session's workspace so the workspace filter admits it — exactly what the
    # domain's `session.send` does (via `WorkspaceRegistry.lookup`).
    # #1212: from_role 腿靠 members_snapshot（生产由 session.send 注入成员边）
    resolve_opts = [
      workspace_uri: @workspace,
      role_resolver: role_resolver,
      members_snapshot: %{
        dev_uri => %{role_name: "dev-together"},
        pm_uri => %{role_name: "kanban-assistant"}
      }
    ]

    done_recipients =
      Resolver.resolve(
        msg(dev_uri, "login card done __done__ → pr"),
        session_uri,
        members,
        resolve_opts
      )

    assert pm_uri in done_recipients

    plain_recipients =
      Resolver.resolve(msg(dev_uri, "no marker here"), session_uri, members, resolve_opts)

    refute pm_uri in plain_recipients
  end

  # --- fixture ----------------------------------------------------------------

  # The REAL shipped kanban manifest (2 active agent role-slots plus the passive
  # board role — loaded straight from the deploy-seed YAML, the one source of
  # truth), with ONLY the active-agent flavor swapped `cc-headless` → the bare-spawn stub (no SDK sidecar; the
  # loader's `:flavor` test seam) + a per-run fixture name. Role names /
  # recipes / the REAL relay `routing_rules` are the shipped ones — resolved
  # through `ManifestResolver` rather than hand-written, so this exercises the
  # actual shipped manifest.
  defp itest_definition_body do
    {:ok, definition} =
      ManifestResolver.resolve(
        ShippedManifest.load!("kanban/manifest.yaml",
          name: @itest_definition,
          flavor: @stub_flavor
        )
      )

    Definition.body(definition)
  end

  # --- helpers ----------------------------------------------------------------

  defp msg(sender, text), do: Message.new(sender, %{text: text, attachments: []}, mentions: [])

  defp member_uri_for_role(session_uri, role_name) do
    case Ezagent.UriQuery.resolve(:member_by_role, {session_uri, role_name}) do
      {:ok, %URI{} = uri} -> uri
      _ -> nil
    end
  end

  defp composition_target(session_uri) do
    case Ezagent.Socialware.CompositionBinding.for_session(session_uri) do
      [%{target_uri: uri} | _] -> Ezagent.URI.new!(uri)
      _ -> nil
    end
  end

  # Mirror the domain's `{:role, name}` resolver seam (Resolver expands a role
  # receiver via this closure): role_name → the member's per-session URI.
  defp role_resolver_for(session_uri) do
    fn role_name, _route_ctx -> member_uri_for_role(session_uri, role_name) end
  end

  defp terminate(nil), do: :ok

  defp terminate(%URI{} = uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} -> if Process.alive?(pid), do: Ezagent.Kind.terminate(uri)
      :error -> :ok
    end
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, attempts) when is_function(fun, 0) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end
end
