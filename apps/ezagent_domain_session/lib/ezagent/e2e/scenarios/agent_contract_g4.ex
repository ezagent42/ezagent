defmodule Ezagent.E2E.Scenarios.AgentContractG4 do
  @moduledoc """
  spec-3 gate **G4** — publish → adopt-on-create → ledger-tracked `migrate_session`,
  driven IN-NODE through production paths (`mix ezagent.e2e.run agent_contract_g4`).

  This module lives in `ezagent_domain_session` (it needs `SessionCreator`,
  `SessionManager`, and `Ezagent.Orchestrator.Tools.migrate_session`); the core
  harness (`Ezagent.E2E.Run`) discovers it BY CONVENTION at runtime, so there is
  no `ezagent_core → ezagent_domain_session` compile edge.

  It is a hybrid of the two Phase-3 integration blueprints, exercising both new
  Phase-3 surfaces end-to-end on the live node:

  * **Part A — adopt-on-create / frozen-on-publish (T3.1, G-INV-9/12):** create
    session A through `SessionCreator.create_session` while `current → @h1`; move
    `current → @h2`; create session B. A stays pinned to `@h1` (a publish never
    touches a live session's immutable URI); B adopts `@h2`.

  * **Part B — `migrate_session` (T3.3, G-INV-10/13):** manually provision an
    orchestrator + `SessionManager` (the proven headless path — no live Claude),
    add a `worker` member from `source_v1`, then migrate to a target template whose
    `worker` uses `source_v2`. An injected mid-migration fault leaves a resumable
    ledger; the rerun converges, regenerating the member (new `source_template_uri`).

  * **Part C — cross-session rule isolation (G-INV-11):** a *second* session's
    routing rule is left untouched by the first session's migration (migration only
    deletes rule-sets whose `created_by == the migrating session`). This is the
    coverage the two unit blueprints did NOT have.

  Migration is driven through the production tool surface
  `SessionManager.run_tool/4` (bridge-token gate + session-side cap reconstruction),
  exactly as a forwarded `tools/call` would.
  """

  import Ezagent.E2E.Step

  alias Ezagent.AgentBridge.TokenStore
  alias Ezagent.ActionSet.Session.ConfigActions
  alias Ezagent.E2E.Scenario
  alias Ezagent.Entity.{Agent, Session, SessionTemplate, User}
  alias Ezagent.Routing.{Matcher, Resolver, RuleStore}
  alias Ezagent.Session.SessionManager
  alias Ezagent.{AgentFlavorRegistry, Capability, TemplateTags}
  alias EzagentDomainInstanceMessage.SessionCreator

  @workspace_str "workspace://team-alpha"

  @spec scenario() :: Scenario.t()
  def scenario do
    %Scenario{
      id: "agent_contract_g4",
      base: nil,
      steps: [
        # ---- Part A: adopt-on-create + frozen-on-publish (create_session path) ----
        step("seed-pin-templates",
          run: fn ctx -> {:ok, seed_pin_templates(ctx)} end,
          await: fn _ -> :ok end,
          assert: fn ctx ->
            if match?(%URI{}, ctx[:h1_uri]) and match?(%URI{}, ctx[:h2_uri]),
              do: :ok,
              else: {:error, {:no_pin_templates, ctx[:h1_uri], ctx[:h2_uri]}}
          end
        ),
        step("create-session-a-pins-h1",
          run: fn ctx -> {:ok, create_session_a(ctx)} end,
          await: fn _ -> :ok end,
          assert: fn ctx -> assert_pin(ctx[:session_a], ctx[:h1_uri]) end
        ),
        step("publish-h2-then-create-b",
          run: fn ctx -> {:ok, publish_h2_create_b(ctx)} end,
          await: fn _ -> :ok end,
          assert: fn ctx ->
            with :ok <- assert_pin(ctx[:session_b], ctx[:h2_uri]),
                 :ok <- assert_pin(ctx[:session_a], ctx[:h1_uri]) do
              :ok
            end
          end
        ),

        # ---- Part B: migrate_session (manual orchestrator, production tool surface) ----
        step("seed-agent-template-versions",
          run: fn ctx -> {:ok, seed_agent_template_versions(ctx)} end,
          await: fn _ -> :ok end,
          assert: fn ctx ->
            if match?(%URI{}, ctx[:source_v1]) and match?(%URI{}, ctx[:source_v2]),
              do: :ok,
              else: {:error, :no_agent_template_versions}
          end
        ),
        step("provision-orchestrator-and-worker",
          run: fn ctx -> {:ok, provision_orchestrator_and_worker(ctx)} end,
          await: fn _ -> :ok end,
          assert: fn ctx ->
            if match?(%URI{}, ctx[:old_member_uri]),
              do: :ok,
              else: {:error, {:no_worker_member, ctx[:old_member_uri]}}
          end
        ),
        step("seed-rules-and-target",
          run: fn ctx -> {:ok, seed_rules_and_target(ctx)} end,
          await: fn _ -> :ok end,
          assert: fn ctx ->
            with true <- match?(%URI{}, ctx[:target_uri]) || {:error, :no_target},
                 true <- is_integer(ctx[:mig_rule_id]) || {:error, :no_mig_rule},
                 true <- is_integer(ctx[:other_rule_id]) || {:error, :no_other_rule} do
              :ok
            else
              other -> other
            end
          end
        ),
        step("migrate-injected-fault-leaves-ledger",
          run: fn ctx -> {:ok, migrate_with_fault(ctx)} end,
          await: fn _ -> :ok end,
          assert: fn ctx -> assert_failed_migration(ctx) end
        ),
        step("migrate-resume-converges",
          run: fn ctx -> {:ok, migrate_resume(ctx)} end,
          await: fn _ -> :ok end,
          assert: fn ctx -> assert_converged_migration(ctx) end
        ),

        # ---- Part C: cross-session rule isolation (G-INV-11) ----
        step("other-session-rules-untouched",
          run: fn ctx -> {:ok, ctx} end,
          await: fn _ -> :ok end,
          assert: fn ctx -> assert_rule_isolation(ctx) end
        )
      ]
    }
  end

  # ───────────────────────── Part A helpers ─────────────────────────

  defp seed_pin_templates(ctx) do
    name = "g4-pin-#{uniq()}"
    ws = Ezagent.URI.new!(@workspace_str)

    {:ok, h1_uri} = SessionTemplate.persist_version_as_system(pin_content(name, "h1", ws), ws)
    {:ok, h2_uri} = SessionTemplate.persist_version_as_system(pin_content(name, "h2", ws), ws)

    :ok = TemplateTags.put(ws, name, "current", hash_of(h1_uri), User.admin_uri())

    Map.merge(ctx, %{pin_template_name: name, workspace: ws, h1_uri: h1_uri, h2_uri: h2_uri})
  end

  defp create_session_a(ctx) do
    {:ok, session_a, _meta} =
      SessionCreator.create_session("g4-a-#{uniq()}", User.admin_uri(),
        workspace_uri: ctx.workspace,
        template_name: ctx.pin_template_name
      )

    Map.put(ctx, :session_a, session_a)
  end

  defp publish_h2_create_b(ctx) do
    :ok =
      TemplateTags.move(
        ctx.workspace,
        ctx.pin_template_name,
        "current",
        hash_of(ctx.h1_uri),
        hash_of(ctx.h2_uri)
      )

    {:ok, session_b, _meta} =
      SessionCreator.create_session("g4-b-#{uniq()}", User.admin_uri(),
        workspace_uri: ctx.workspace,
        template_name: ctx.pin_template_name
      )

    Map.put(ctx, :session_b, session_b)
  end

  # ───────────────────────── Part B helpers ─────────────────────────

  defp seed_agent_template_versions(ctx) do
    flavor = register_test_flavor()
    source_v1 = Ezagent.URI.new!("template://team-alpha/agent/g4-v1-#{uniq()}")
    source_v2 = Ezagent.URI.new!("template://team-alpha/agent/g4-v2-#{uniq()}")
    :ok = create_agent_template(source_v1, flavor, "g4-v1")
    :ok = create_agent_template(source_v2, flavor, "g4-v2")

    Map.merge(ctx, %{flavor: flavor, source_v1: source_v1, source_v2: source_v2})
  end

  defp provision_orchestrator_and_worker(ctx) do
    ws = Ezagent.URI.new!(@workspace_str)
    session_uri = spawn_session()
    orchestrator_uri = Ezagent.URI.new!("entity://team-alpha/agent/g4_orch-#{uniq()}")
    :ok = Ezagent.AgentFlavorAttributes.put(orchestrator_uri, "cc")

    caps =
      orchestrator_caps(session_uri, orchestrator_uri, ws, [:agent_template, :session_template])

    # derivation-edge: test-scenario in-code E2E fixture
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: orchestrator_uri, initial_caps: caps})
    :ok = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, ws)

    {:ok, _} =
      ConfigActions.system_set_working_copy(session_uri, %{
        orchestrator_uri: orchestrator_uri,
        orchestrator_template_uri: Ezagent.URI.new!("template://system/agent/cc-orchestrator")
      })

    {:ok, token} = TokenStore.mint(orchestrator_uri)

    {:ok, _sm} =
      SessionManager.ensure_started(
        orchestrator_uri: orchestrator_uri,
        session_uri: session_uri,
        workspace_uri: ws,
        owner_uri: orchestrator_uri
      )

    orch = %{orchestrator_uri: orchestrator_uri, token: token, session_uri: session_uri}

    {:ok, %URI{} = old_member_uri} =
      run_tool(orch, "add_managed_member", %{
        "source_agent_template_uri" => URI.to_string(ctx.source_v1),
        "role_name" => "worker",
        "in_session_template" => true
      })

    Map.merge(ctx, %{
      mig_workspace: ws,
      mig_session_uri: session_uri,
      orch: orch,
      old_member_uri: old_member_uri
    })
  end

  # Seed: (1) a rule on the MIGRATING session (created_by == it → migration must
  # delete it), (2) a rule on a SECOND session (created_by != it → must survive),
  # and (3) the migrate target SessionTemplate (worker → source_v2).
  defp seed_rules_and_target(ctx) do
    table = Resolver.default_routing_table()
    ws = ctx.mig_workspace
    other_session = spawn_session()

    {:ok, mig_rule} =
      RuleStore.add(
        table,
        Matcher.always(),
        [URI.to_string(User.admin_uri())],
        URI.to_string(ctx.mig_session_uri),
        workspace_uri: URI.to_string(ws),
        rule_set: "g4-mig",
        position: 0
      )

    {:ok, other_rule} =
      RuleStore.add(
        table,
        Matcher.always(),
        [URI.to_string(User.admin_uri())],
        URI.to_string(other_session),
        workspace_uri: URI.to_string(ws),
        rule_set: "g4-other",
        position: 0
      )

    target_content = %{
      name: "g4-migrate-target-#{uniq()}",
      description: "target team",
      members: [
        %{
          uri: nil,
          role_name: "worker",
          in_session_template: true,
          source_template_uri: ctx.source_v2
        }
      ],
      routing_rules: [],
      prompt_templates: %{},
      legends: %{},
      orchestrator_template_uri: Ezagent.URI.new!("template://system/agent/cc-orchestrator"),
      default_workspace_uri: ws,
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-06-21 00:00:00Z]
    }

    {:ok, target_uri} = SessionTemplate.persist_version_as_system(target_content, ws)

    Map.merge(ctx, %{
      other_session: other_session,
      mig_rule_id: mig_rule.id,
      other_rule_id: other_rule.id,
      target_uri: target_uri
    })
  end

  defp migrate_with_fault(ctx) do
    Application.put_env(
      :ezagent_domain_session,
      :migrate_session_fault,
      {:after_role_done, "worker"}
    )

    result =
      run_tool(ctx.orch, "migrate_session", %{
        "target_session_template_uri" => URI.to_string(ctx.target_uri)
      })

    Map.put(ctx, :fault_result, result)
  end

  defp migrate_resume(ctx) do
    Application.delete_env(:ezagent_domain_session, :migrate_session_fault)

    result =
      run_tool(ctx.orch, "migrate_session", %{
        "target_session_template_uri" => URI.to_string(ctx.target_uri)
      })

    Map.put(ctx, :resume_result, result)
  end

  # ───────────────────────── assertions ─────────────────────────

  defp assert_pin(%URI{} = session_uri, %URI{} = expected) do
    actual = Session.read_template_working_copy(session_uri).session_template_uri

    if actual == expected,
      do: :ok,
      else: {:error, {:wrong_pin, session_uri, expected: expected, actual: actual}}
  end

  defp assert_pin(other, _expected), do: {:error, {:not_a_session_uri, other}}

  defp assert_failed_migration(ctx) do
    wc = Session.read_template_working_copy(ctx.mig_session_uri)
    ledger = Map.get(wc, :migration_ledger)
    members = chat_slice(ctx.mig_session_uri).members

    cond do
      ctx.fault_result != {:error, {:injected_migration_failure, "worker"}} ->
        {:error, {:unexpected_fault_result, ctx.fault_result}}

      Map.get(wc, :session_template_uri) == ctx.target_uri ->
        {:error, :pin_advanced_despite_fault}

      not match?(%{target_session_template_uri: _}, ledger) ->
        {:error, {:no_ledger, ledger}}

      ledger.target_session_template_uri != ctx.target_uri ->
        {:error, {:ledger_wrong_target, ledger.target_session_template_uri}}

      Map.get(ledger.members, "worker") != :done ->
        {:error, {:ledger_worker_not_done, ledger.members}}

      not Enum.any?(members, fn {_uri, meta} -> meta.role_name == "worker" end) ->
        {:error, :no_worker_after_fault}

      true ->
        :ok
    end
  end

  defp assert_converged_migration(ctx) do
    final_wc = Session.read_template_working_copy(ctx.mig_session_uri)
    members = chat_slice(ctx.mig_session_uri).members

    cond do
      not match?({:ok, %{session_template_uri: _}}, ctx.resume_result) ->
        {:error, {:unexpected_resume_result, ctx.resume_result}}

      final_wc.session_template_uri != ctx.target_uri ->
        {:error, {:pin_not_advanced, final_wc.session_template_uri}}

      Map.has_key?(final_wc, :migration_ledger) ->
        {:error, :ledger_not_cleared}

      Map.has_key?(members, ctx.old_member_uri) ->
        {:error, :old_member_not_retired}

      not Enum.any?(members, fn {_uri, meta} ->
        meta.role_name == "worker" and meta.source_template_uri == ctx.source_v2
      end) ->
        {:error, {:worker_not_regenerated, members}}

      true ->
        :ok
    end
  end

  defp assert_rule_isolation(ctx) do
    table = Resolver.default_routing_table()
    ids = table |> RuleStore.list() |> Enum.map(& &1.id) |> MapSet.new()

    cond do
      not MapSet.member?(ids, ctx.other_rule_id) ->
        {:error, {:other_session_rule_lost, ctx.other_rule_id}}

      MapSet.member?(ids, ctx.mig_rule_id) ->
        {:error, {:migrating_session_rule_not_replaced, ctx.mig_rule_id}}

      true ->
        :ok
    end
  end

  # ───────────────────────── shared seed helpers (ported from blueprints) ─────────────────────────

  defp uniq, do: System.unique_integer([:positive])

  defp hash_of(%URI{} = uri) do
    uri |> Ezagent.URI.name!() |> String.split("@", parts: 2) |> List.last()
  end

  defp pin_content(name, description, ws) do
    %{
      name: name,
      description: description,
      members: [],
      routing_rules: [],
      prompt_templates: %{},
      legends: %{},
      orchestrator_template_uri: nil,
      default_workspace_uri: ws,
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-06-21 00:00:00Z]
    }
  end

  defp register_test_flavor do
    flavor = "g4e2e#{uniq()}"

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Agent,
        template_class: __MODULE__.TestFlavorClass
      })

    flavor
  end

  defp create_agent_template(uri, flavor, name) do
    content = %{
      name: name,
      description: "worker #{name}",
      flavor: flavor,
      project_cwd: "/tmp/g4-e2e",
      config_dir: nil,
      settings_path: nil,
      mcp_config_path: nil,
      api_key_helper: nil,
      default_caps: [],
      created_by: User.admin_uri(),
      created_at: ~U[2026-05-22 00:00:00Z]
    }

    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    {:ok, %{content: ^content}} = dispatch(uri, "template.write", %{content: content})
    :ok
  end

  defp dispatch(uri, action, args) do
    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=#{action}")
    admin = User.admin_uri()

    with {:ok, signed_cap} <- Ezagent.Cap.issue_for_action({:admin, admin}, admin, target) do
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: target,
        mode: :call,
        args: args,
        ctx: %{
          caller: admin,
          authenticated_principal: admin,
          caps: MapSet.new([signed_cap]),
          reply: {:caller_inbox, self()}
        },
        origin: :trusted_internal
      })
    end
  end

  defp spawn_session do
    session_uri = Ezagent.URI.session("team-alpha", "generic", "g4-e2e-#{uniq()}")

    {:ok, _pid} =
      # derivation-edge: test-scenario in-code E2E fixture
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, Ezagent.URI.new!(@workspace_str))
    session_uri
  end

  defp template_cap(kind, ws) do
    %Capability{
      kind: kind,
      behavior: Ezagent.ActionSet.Template,
      instance: {:within_workspace, ws},
      workspace_uri: ws,
      granted_by: User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  defp orchestrator_caps(session_uri, orchestrator_uri, ws, template_kinds) do
    base = [
      %Capability{
        kind: :session,
        behavior: :any,
        instance: {:within_session, session_uri},
        workspace_uri: ws,
        granted_by: User.admin_uri(),
        granted_at: DateTime.utc_now()
      },
      %Capability{
        kind: :agent,
        behavior: :any,
        instance: {:spawned_by, orchestrator_uri},
        workspace_uri: ws,
        granted_by: User.admin_uri(),
        granted_at: DateTime.utc_now()
      }
    ]

    MapSet.new(base ++ Enum.map(template_kinds, &template_cap(&1, ws)))
  end

  defp run_tool(%{orchestrator_uri: orch, token: token}, tool, args) when is_binary(tool) do
    SessionManager.run_tool(orch, tool, args, token)
  end

  defp chat_slice(session_uri) do
    {:ok, %{state: slice}} =
      Ezagent.Kind.get_raw_slice(session_uri, :session)

    slice
  end

  defmodule TestFlavorClass do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "g4.e2e.agent"

    @impl true
    def validate(tmpl) when is_map(tmpl),
      do: if(Map.has_key?(tmpl, "agent_uri"), do: :ok, else: {:error, :missing_agent_uri})

    def validate(_), do: {:error, :not_a_map}

    @impl true
    def instantiate(_tmpl_name, %{"agent_uri" => uri_str}, _workspace_uri) do
      agent_uri = Ezagent.URI.new!(uri_str)

      case Ezagent.Domain.Agent.materialize_declared(agent_uri) do
        {:ok, :started, _pid} -> {:ok, [agent_uri], %{fresh?: true}}
        {:ok, :already_started, _pid} -> {:ok, [agent_uri], %{fresh?: false}}
        {:error, _} = err -> err
      end
    end

    def instantiate(_n, tmpl, _ws), do: {:error, {:invalid_template, tmpl}}
  end
end
