defmodule EzagentDomainInstanceMessage.Integration.SessionCreateOrchestratorDecoupleTest do
  @moduledoc """
  Rev6 gates for `docs/superpowers/specs/2026-06-23-session-create-orchestrator-decouple-design.md`.

  These tests intentionally pin the new create contract before implementation:
  create records declarations only and never spawns, waits for, or rolls back on
  an orchestrator/member bring-up.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, KindRegistry, Message}
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Workspace
  alias Ezagent.Entity.{Session, SessionTemplate, User}
  alias Ezagent.Ecto.KindSnapshot
  alias EzagentDomainInstanceMessage.SessionCreator.TemplateResolver

  setup do
    _ = Ezagent.SpawnRegistry.spawn(User.admin_uri())
    :ok = EzagentDomainInstanceMessage.Application.seed_default_session_template_now()
    :ok = seed_orchestrator_recipe()

    on_exit(fn ->
      table = Ezagent.Routing.Resolver.default_routing_table()

      try do
        Ezagent.Routing.RuleStore.load_into_registry(table)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  test "default SessionTemplate installs chat only, not orchestrator or a legacy member" do
    {:ok, template_uri, content} =
      TemplateResolver.resolve_session_template!("default", Ezagent.URI.workspace(:system))

    assert URI.to_string(template_uri) =~ "template://system/session/default@"
    refute Map.has_key?(content, :orchestrator_template_uri)
    refute Map.has_key?(content, "orchestrator_template_uri")

    members = Map.get(content, :members) || Map.get(content, "members")
    installs = Map.get(content, :installs) || Map.get(content, "installs")

    assert members == []
    assert installs == ["chat"]
  end

  # Restored to the #912 assertion. #1223 inverted it ("materializes the default
  # orchestrator Definition") while keeping the file named `..._decouple_test.exs`,
  # so the rev6 contract regressed without ever turning the suite red. The
  # declaration IS recorded at create (rev6 step 4); the live member is NOT
  # (rev6 step 5 — "join only the owner").
  test "create_session from the default template records no orchestrator declaration" do
    short = "decouple-create-#{System.unique_integer([:positive])}"

    assert {:ok, session_uri, meta} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
               template_name: "default"
             )

    assert URI.to_string(session_uri) == "session://system/default/#{short}"
    assert meta == %{}

    assert {:ok, _pid} = Ezagent.KindRegistry.lookup(session_uri)
    expected_workspace = Ezagent.URI.workspace(:system)
    assert {:ok, ^expected_workspace} = Ezagent.WorkspaceRegistry.lookup(session_uri)

    owner = URI.to_string(User.admin_uri())

    assert Session.session_member_uris(session_uri) |> Enum.map(&URI.to_string/1) == [owner]
    assert member_role_uri(session_uri, "orchestrator") == nil

    # …and it STAYS owner-only: no async materialization sneaks a member in.
    Process.sleep(100)
    assert Session.session_member_uris(session_uri) |> Enum.map(&URI.to_string/1) == [owner]

    wc = Session.read_template_working_copy(session_uri)
    assert Map.get(wc, :session_template_uri)

    assert Map.get(wc, :member_declarations) == []

    refute Map.has_key?(wc, :orchestrator_uri)
    refute Map.has_key?(wc, :orchestrator_template_uri)
  end

  test "workspace create_session returns within dispatch budget only after durable finalized snapshot" do
    workspace_uri = Ezagent.URI.workspace(:system)
    owner_uri = User.admin_uri()
    admin_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, owner_uri)

    results =
      1..3
      |> Task.async_stream(
        fn idx ->
          short = "snapshot-race-#{idx}-#{System.unique_integer([:positive])}"
          started = System.monotonic_time(:millisecond)

          result =
            Workspace.create_session(
              workspace_uri,
              %{short_name: short, template_name: "default"},
              admin_ctx
            )

          elapsed_ms = System.monotonic_time(:millisecond) - started
          {short, elapsed_ms, result}
        end,
        max_concurrency: 3,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> flunk("concurrent create task exited: #{inspect(reason)}")
      end)

    assert length(results) == 3

    for {short, elapsed_ms, result} <- results do
      assert {:ok, %{session_uri: session_uri}} = result

      # The 5s dispatch budget was the SYMPTOM ceiling (canary saw ~5.3s), so a
      # `< 5_000` assertion was green THROUGHOUT the outage and guarded nothing.
      # With the agent transaction out of create, three concurrent creates through
      # the single Workspace Kind must land far under it.
      #
      # 3s, not 1.5s: each create now persists its durable socialware-install
      # obligation before replying, then wakes a background installer. The three
      # callers queue through one Workspace Kind while those DB-backed installers
      # contend for the same Ecto pool. 3s still keeps a meaningful margin below
      # the pre-fix ~5.3s outage while measuring the new durable-enqueue boundary.
      assert elapsed_ms < 3_000,
             "create_session #{short} exceeded the owner-only create budget: #{elapsed_ms}ms"

      assert URI.to_string(session_uri) == "session://system/default/#{short}"
      assert_finalized_session_snapshot!(session_uri, owner_uri)
    end
  end

  test "Workspace.create_session default path does not materialize an orchestrator" do
    workspace_uri = Ezagent.URI.workspace(:system)
    owner_uri = User.admin_uri()
    short = "async-install-#{System.unique_integer([:positive])}"

    assert {:ok, %{session_uri: session_uri}} =
             Workspace.create_session(
               workspace_uri,
               %{short_name: short, template_name: "default"},
               Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, owner_uri)
             )

    # The create itself is owner-only…
    assert Session.session_member_uris(session_uri) |> Enum.map(&URI.to_string/1) ==
             [URI.to_string(owner_uri)]

    # Main hotfix 2026-07-10: default sessions stay plain while orchestrator
    # readiness is repaired separately.
    refute wait_until(
             fn -> match?(%URI{}, member_role_uri(session_uri, "orchestrator")) end,
             200
           )
  end

  test "route-time role delivery provisions declared orchestrator member lazily" do
    n = System.unique_integer([:positive])
    source_template_uri = seed_echo_agent_template(n)
    template_name = "lazy-orchestrator-#{n}"

    persist_session_template(%{
      name: template_name,
      description: "route-time orchestrator role",
      default_workspace_uri: Ezagent.URI.workspace(:system),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-06-23 00:00:00Z],
      members: [
        %{
          uri: nil,
          role_name: "orchestrator",
          in_session_template: true,
          source_template_uri: source_template_uri
        }
      ],
      routing_rules: [
        %{
          matcher: Ezagent.Routing.Matcher.from(User.admin_uri()),
          receivers: ["orchestrator"],
          rule_set: nil,
          position: 0
        }
      ],
      prompt_templates: %{},
      legends: %{}
    })

    short = "lazy-route-#{n}"

    assert {:ok, session_uri, %{}} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
               template_name: template_name
             )

    assert member_role_uri(session_uri, "orchestrator") == nil

    msg = Message.new(User.admin_uri(), %{text: "wake orchestrator", attachments: []})

    send_target = URI.new!("#{URI.to_string(session_uri)}?action=session.send")
    send_cap = Ezagent.Test.CapHelper.signed_action_cap!(send_target, User.admin_uri())

    :ok =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: send_target,
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: User.admin_uri(),
          authenticated_principal: User.admin_uri(),
          caps: MapSet.new([send_cap]),
          reply: :ignore
        }
      })

    assert wait_until(fn ->
             case member_role_uri(session_uri, "orchestrator") do
               %URI{} = member_uri ->
                 slice = chat_slice(session_uri)

                 match?(
                   %{online: true, source_template_uri: ^source_template_uri},
                   Map.get(slice.members, member_uri)
                 )

               nil ->
                 false
             end
           end)
  end

  defp wait_until(fun, retries \\ 50)

  defp wait_until(fun, retries) do
    case fun.() do
      false when retries > 0 ->
        Process.sleep(10)
        wait_until(fun, retries - 1)

      result ->
        result
    end
  end

  defp chat_slice(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    %{state: %{session: %{state: slice}}} = :sys.get_state(pid)
    slice
  end

  defp member_role_uri(session_uri, role_name) do
    session_uri
    |> chat_slice()
    |> Map.get(:members, %{})
    |> SessionBehavior.role_name_to_uri(role_name)
  end

  defp assert_finalized_session_snapshot!(session_uri, owner_uri) do
    uri_str = URI.to_string(session_uri)
    owner_str = URI.to_string(owner_uri)

    assert %KindSnapshot{} = row = KindSnapshot.get(uri_str)
    assert {:ok, snapshot_state} = KindSnapshot.decode_state(row)

    assert %{session: %{state: session_slice}} = snapshot_state
    assert URI.to_string(session_slice.owner_uri) == owner_str

    member_uris =
      session_slice.members
      |> Map.keys()
      |> Enum.map(&URI.to_string/1)

    assert member_uris == [owner_str]

    working_copy = Map.fetch!(session_slice, :template_working_copy)
    assert %URI{} = Map.get(working_copy, :session_template_uri)

    assert Map.get(working_copy, :member_declarations) == []
  end

  defp seed_orchestrator_recipe do
    recipe =
      [Ezagent, Orchestrator, OrchestratorRecipe]
      |> Module.concat()
      |> apply(:recipe, [])

    case Ezagent.Agent.RecipeRegistry.seed_role_if_absent(recipe) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp seed_echo_agent_template(n) do
    uri = Ezagent.URI.new!("template://system/agent/lazy-role-#{n}")
    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)

    write_target = URI.new!("#{URI.to_string(uri)}?action=template.write")
    write_cap = Ezagent.Test.CapHelper.signed_action_cap!(write_target, User.admin_uri())

    {:ok, _} =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: write_target,
        mode: :call,
        args: %{
          content: %{
            flavor: "cc",
            project_cwd: "/tmp",
            default_caps: [],
            created_by: User.admin_uri(),
            created_at: ~U[2026-06-23 00:00:00Z]
          }
        },
        ctx: %{
          caller: User.admin_uri(),
          authenticated_principal: User.admin_uri(),
          caps: MapSet.new([write_cap]),
          reply: {:caller_inbox, self()}
        }
      })

    on_exit(fn ->
      terminate_if_alive(EzagentDomainInstanceMessage.AgentTemplateSupervisor, uri)
    end)

    uri
  end

  defp persist_session_template(content) do
    hash = SessionTemplate.compute_version_hash(content)
    uri = SessionTemplate.build_uri(content.name, hash, workspace: "system")
    :ok = KindSnapshot.delete(URI.to_string(uri))
    {:ok, persisted_uri} = SessionTemplate.persist_version_as_system(content, "system")

    on_exit(fn ->
      terminate_if_alive(EzagentDomainInstanceMessage.SessionTemplateSupervisor, persisted_uri)
    end)

    persisted_uri
  end

  defp terminate_if_alive(supervisor, uri) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid), do: DynamicSupervisor.terminate_child(supervisor, pid)

      _ ->
        :ok
    end
  end
end
