defmodule Mix.Tasks.Ezagent.Demo.SeedAutoservice do
  @shortdoc "Seed the cinnox autoservice demo tenant (workspace + roles + agents + sessions)"
  @moduledoc """
  > **Demo seeder** (Category A, same class as `ezagent.demo.seed_cc_agent`).
  > Runs in its own BEAM via `Application.ensure_all_started/1`; the
  > Kinds it spawns persist as snapshots + DB rows that the running /
  > next server rehydrates. NOT a normal operator op — stays
  > `mix ezagent.demo.*`, not `mix ezagent`.

  Seeds the `cinnox` customer-service demo tenant end to end:

  1. `workspace://cinnox`
  2. users with role cap-bundles (`EzagentPluginAutoservice.Roles`):
     - admin    `entity://user/cinnox/admin`
     - operator `entity://user/cinnox/op`
     - customers `entity://user/cinnox/<name>` (default: alice, bob)
  3. for each customer, a provisioned service session
     (`session://cs/cinnox/<name>`) with a fast (curl/DeepSeek) agent
     joined, the customer→fast routing rule installed, and an opening
     greeting posted — via `EzagentPluginAutoservice.CustomerSession`.

  Idempotent: re-running converges (existing workspace/users/agents are
  reused).

  ## Usage

      # set a real DeepSeek key so the fast agent actually replies
      export DEEPSEEK_API_KEY=sk-...
      mix ecto.create && mix ecto.migrate   # first run only
      mix ezagent.demo.seed_autoservice

      # options
      mix ezagent.demo.seed_autoservice --customers alice,bob,carol
      mix ezagent.demo.seed_autoservice --with-slow      # also spawn cc slow agents (needs claude)
      mix ezagent.demo.seed_autoservice --deepseek-key sk-...

  After seeding, start the server (`mix phx.server`) and log in at
  `/login` with one of the seeded users (password defaults to the user's
  short name, e.g. customer `alice` / password `alice`).

  ## Why the fast agent needs a key

  Without a DeepSeek key the fast agent is still created and posts the
  canned greeting, but live replies surface a "configure my key"
  message instead of a model answer.
  """
  use Mix.Task

  alias EzagentPluginAutoservice.{CustomerSession, Roles}

  @workspace_name "cinnox"
  @default_customers ["alice", "bob"]
  @admin_short "admin"
  @operator_short "op"

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _} =
      OptionParser.parse(argv,
        strict: [customers: :string, with_slow: :boolean, deepseek_key: :string]
      )

    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_workspace)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_chat)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_curl_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_autoservice)

    deepseek_key = opts[:deepseek_key] || System.get_env("DEEPSEEK_API_KEY")
    with_slow? = Keyword.get(opts, :with_slow, false)

    # The slow agent is a cc (claude) flavor — only registered when the
    # cc plugin is started. The seed runs in its own BEAM that otherwise
    # doesn't boot it (the running server does, via ezagent_web deps).
    if with_slow?, do: {:ok, _} = Application.ensure_all_started(:ezagent_plugin_cc)
    customers = parse_customers(opts[:customers])

    workspace_uri = Ezagent.URI.new!("workspace://#{@workspace_name}")
    ctx = mix_task_ctx()

    Mix.shell().info("Seeding autoservice tenant `#{@workspace_name}` …")

    :ok = ensure_workspace()
    :ok = seed_role_user(@admin_short, :admin, workspace_uri, ctx)
    :ok = seed_role_user(@operator_short, :operator, workspace_uri, ctx)
    :ok = ensure_default_session(workspace_uri, ctx)

    results =
      Enum.map(customers, fn name ->
        :ok = seed_role_user(name, :customer, workspace_uri, ctx)
        customer_uri = user_uri(name)

        case CustomerSession.provision(customer_uri,
               workspace_uri: workspace_uri,
               ctx: ctx,
               deepseek_key: deepseek_key,
               with_slow: with_slow?
             ) do
          {:ok, info} ->
            {name, :ok, info}

          {:error, reason} ->
            {name, :error, reason}
        end
      end)

    print_summary(results, deepseek_key, with_slow?)
  end

  # --- steps ----------------------------------------------------------

  defp ensure_workspace do
    case Ezagent.Workspace.create(@workspace_name, %{}) do
      {:ok, _pid} ->
        Mix.shell().info("  workspace://#{@workspace_name} created")
        :ok

      {:error, {:already_started, _pid}} ->
        Mix.shell().info("  workspace://#{@workspace_name} already exists")
        :ok

      {:error, reason} ->
        # Some create paths return {:error, :already_exists}-style atoms;
        # treat a live workspace Kind as success.
        case Ezagent.KindRegistry.lookup(Ezagent.URI.new!("workspace://#{@workspace_name}")) do
          {:ok, _pid} ->
            Mix.shell().info("  workspace://#{@workspace_name} already exists")
            :ok

          :error ->
            Mix.raise("workspace create failed: #{inspect(reason)}")
        end
    end
  end

  # Create the user row (idempotent) with default + role caps, then add
  # to the workspace member set. `Ezagent.Users.create/3` prepends
  # `User.default_caps/1`; `Roles.bundle/2` supplies the extras.
  defp seed_role_user(short, role, workspace_uri, _ctx) do
    uri = user_uri(short)
    password = short
    extra_caps = Roles.bundle(role, workspace_uri)

    case Ezagent.Users.create(uri, password, extra_caps) do
      {:ok, _decoded} ->
        Mix.shell().info("  user #{URI.to_string(uri)} (#{role}) created")

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :uri) do
          Mix.shell().info("  user #{URI.to_string(uri)} (#{role}) already exists")
        else
          Mix.raise("user create failed for #{URI.to_string(uri)}: #{inspect(errors)}")
        end

      {:error, reason} ->
        Mix.raise("user create failed for #{URI.to_string(uri)}: #{inspect(reason)}")
    end

    _ = add_member(uri)
    :ok
  end

  # --- default session for native UI (/sessions) -----------------------

  defp ensure_default_session(workspace_uri, _ctx) do
    # 1. Create a default SessionTemplate WITHOUT orchestrator
    # (the autoservice has its own agents; no cc-orchestrator needed
    # for the cinnox workspace).
    content = %{
      name: "default",
      description: "Cinnox default session — plain (no orchestrator, uses autoservice agents)",
      agent_slots: [],
      orchestrator_template_uri: nil,
      routing_rules: [],
      default_workspace_uri: workspace_uri,
      parent_template_uri: nil,
      version_tag: nil,
      created_by: nil,
      created_at: nil
    }

    case Ezagent.Entity.SessionTemplate.persist_version_as_system(content, workspace_uri) do
      {:ok, tmpl_uri} ->
        Mix.shell().info("  default SessionTemplate #{URI.to_string(tmpl_uri)}")

      {:error, reason} ->
        Mix.shell().info("  default SessionTemplate already present (#{inspect(reason)})")
    end

    # 2. Create session://default/<ws>/main so the native /sessions page
    # finds a live session on first visit (no orchestrator to fail).
    admin_uri = user_uri(@admin_short)
    main_uri = Ezagent.URI.new!("session://default/#{@workspace_name}/main")

    case Ezagent.KindRegistry.lookup(main_uri) do
      {:ok, _pid} ->
        Mix.shell().info("  session #{URI.to_string(main_uri)} already alive")

      :error ->
        # 2026-05-31 orchestrator-startup-atomicity §4 step 9:
        # the plain-session path (nil orchestrator) is the
        # no-rollback fast-path — steps 5-7 are skipped, so
        # there are no failures to roll back.
        case EzagentDomainChat.create_session("main", admin_uri,
               template_name: "default",
               workspace_uri: workspace_uri
             ) do
          {:ok, sess_uri, _meta} ->
            Mix.shell().info("  session #{URI.to_string(sess_uri)} created")

          {:error, reason} ->
            Mix.shell().info("  session create: #{inspect(reason)} (may be idempotent)")
        end
    end

    :ok
  end

  defp add_member(uri) do
    Ezagent.Workspace.add_member(@workspace_name, uri)
  rescue
    e ->
      Mix.shell().info("  (add_member #{URI.to_string(uri)} skipped: #{inspect(e)})")
      :ok
  end

  # --- helpers --------------------------------------------------------

  defp parse_customers(nil), do: @default_customers

  defp parse_customers(csv) when is_binary(csv) do
    csv
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> @default_customers
      list -> list
    end
  end

  defp user_uri(short), do: Ezagent.URI.new!("entity://user/#{@workspace_name}/#{short}")

  defp mix_task_ctx do
    %{
      caller: Ezagent.SystemPrincipal.uri("mix-task"),
      caps: Ezagent.SystemPrincipal.caps("system://mix-task")
    }
  end

  defp print_summary(results, deepseek_key, with_slow?) do
    key_note =
      if deepseek_key in [nil, ""] do
        "\n  ⚠ No DeepSeek key (set DEEPSEEK_API_KEY) — fast agents post the greeting " <>
          "but cannot generate live replies until a key is configured."
      else
        ""
      end

    lines =
      Enum.map(results, fn
        {name, :ok, info} ->
          "  ✓ #{name}: session #{URI.to_string(info.session_uri)} | fast #{URI.to_string(info.fast_uri)}" <>
            if(info.slow_uri, do: " | slow #{URI.to_string(info.slow_uri)}", else: "")

        {name, :error, reason} ->
          "  ✗ #{name}: provision failed — #{inspect(reason)}"
      end)

    Mix.shell().info("""

    autoservice demo tenant `#{@workspace_name}` seeded#{if with_slow?, do: " (with slow cc agents)", else: ""}.

    #{Enum.join(lines, "\n")}
    #{key_note}

    Login at /login (password = the user's short name):
      admin:     entity://user/#{@workspace_name}/#{@admin_short}
      operator:  entity://user/#{@workspace_name}/#{@operator_short}
      customers: #{results |> Enum.map(fn {n, _, _} -> "entity://user/#{@workspace_name}/#{n}" end) |> Enum.join(", ")}

    Start the server with `mix phx.server`, then:
      • customer → /autoservice (their service session, fast agent greeting)
      • operator → /autoservice/operator (workspace session list → join → chat)
    """)
  end
end
