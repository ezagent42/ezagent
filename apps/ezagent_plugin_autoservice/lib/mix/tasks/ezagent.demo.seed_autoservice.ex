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
     - admin    `entity://cinnox/user/admin`
     - operator `entity://cinnox/user/op`
     - customers `entity://cinnox/user/<name>` (default: alice, bob)
  3. for each customer, a provisioned service session
     (`session://cs/cinnox/<name>`) with a fast (curl/DeepSeek) agent
     joined, the customer→fast routing rule installed, and an opening
     greeting posted — via `EzagentPluginAutoservice.CustomerSession`.

  Idempotent: deletes existing users from the DB before creating, so
  re-running converges (existing workspace/agents/sessions are reused).

  ## Usage

      # set a real DeepSeek key so the fast agent actually replies
      export DEEPSEEK_API_KEY=sk-...
      mix ecto.create && mix ecto.migrate   # first run only
      mix ezagent.demo.seed_autoservice

      # options
      mix ezagent.demo.seed_autoservice --tenant acme --customers alice,bob
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

  import Ecto.Query
  alias EzagentPluginAutoservice.{CustomerSession, Roles}

  @workspace_name "cinnox"
  @default_customers ["alice", "bob"]
  @admin_short "admin"
  @operator_short "op"

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _} =
      OptionParser.parse(argv,
        strict: [customers: :string, with_slow: :boolean, deepseek_key: :string, tenant: :string]
      )

    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_workspace)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_instance_message)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_curl_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_autoservice)

    deepseek_key = opts[:deepseek_key] || System.get_env("DEEPSEEK_API_KEY")
    with_slow? = Keyword.get(opts, :with_slow, false)

    # The slow agent is a cc (claude) flavor — only registered when the
    # cc plugin is started. The seed runs in its own BEAM that otherwise
    # doesn't boot it (the running server does, via ezagent_web deps).
    if with_slow?, do: {:ok, _} = Application.ensure_all_started(:ezagent_plugin_cc)

    customers = parse_customers(opts[:customers])

    workspace_name = Keyword.get(opts, :tenant, @workspace_name)
    workspace_uri = Ezagent.URI.new!("workspace://#{workspace_name}")
    ctx = mix_task_ctx()

    Mix.shell().info("Seeding autoservice tenant `#{workspace_name}` …")

    # Idempotency: delete existing users from the DB first.
    :ok = delete_existing_users()

    :ok = ensure_workspace()

    # Create all users first.
    :ok = seed_role_user(@admin_short, :admin, workspace_uri, ctx)
    :ok = seed_role_user(@operator_short, :operator, workspace_uri, ctx)
    Enum.each(customers, fn name ->
      :ok = seed_role_user(name, :customer, workspace_uri, ctx)
    end)

    # Default SessionTemplate for native /sessions UI.
    # Session creation is deferred to AdminLive.ensure_main_session
    # (avoids cross-VM rollback issues).
    :ok = ensure_default_template(workspace_uri)

    # Provision customer-service sessions (fast + slow agents, routing,
    # greeting).
    results =
      Enum.map(customers, fn name ->
        customer_uri = user_uri(name)

        case CustomerSession.provision(customer_uri,
               tid: workspace_name,
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

  defp delete_existing_users do
    workspace_uri = Ezagent.URI.new!("workspace://#{@workspace_name}")

    users = Ezagent.Users.list_in_workspace(workspace_uri)

    if users == [] do
      Mix.shell().info("  no existing users to delete")
      :ok
    else
      Enum.each(users, fn user ->
        uri_str = URI.to_string(user.uri)

        case EzagentCore.Repo.delete_all(
               from(u in Ezagent.Users, where: u.uri == ^uri_str)
             ) do
          {n, _} when n > 0 ->
            Mix.shell().info("  deleted user #{uri_str}")

          _ ->
            :ok
        end

        # Also delete the KindSnapshot so the next phx.server boot does
        # a fresh init from the new caps_json.
        Ezagent.Ecto.KindSnapshot.delete(uri_str)
      end)

      :ok
    end
  end

  defp ensure_workspace do
    case Ezagent.Workspace.create(@workspace_name, %{}) do
      {:ok, _pid} ->
        Mix.shell().info("  workspace://#{@workspace_name} created")
        :ok

      {:error, :workspace_exists} ->
        Mix.shell().info("  workspace://#{@workspace_name} already exists")
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

    # Grant role caps via dispatch so they land in the Identity slice.
    # Use :call (synchronous) — the seed VM exits after this function,
    # so :cast would be dropped before the Kind is ready.
    grant_ctx = Map.put(mix_task_ctx(), :reply, {:caller_inbox, self()})
    Enum.each(extra_caps, fn cap ->
      case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
             target: Ezagent.URI.new!("#{URI.to_string(uri)}?action=identity.grant_cap"),
             mode: :call,
             args: %{cap: cap},
             ctx: grant_ctx
           }) do
        {:ok, _result} -> :ok
        {:error, reason} -> Mix.shell().info("  grant_cap #{URI.to_string(uri)}: #{inspect(reason)}")
      end
    end)

    # Delete the snapshot written by the seed VM — its binary may
    # contain atoms unknown to the phx.server VM (cross-VM :unsafe_atom).
    # On next spawn, load_with_fallback will call fetch_snapshot → :error
    # → init_fresh which calls create(args) with initial_caps from
    # caps_json (ever_created? is reset by the delete, so create runs).
    Ezagent.Ecto.KindSnapshot.delete(URI.to_string(uri))

    :ok
  end

  # --- default template for native UI (/sessions) --------------------

  defp ensure_default_template(workspace_uri) do
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

  defp user_uri(short), do: Ezagent.URI.new!("entity://#{@workspace_name}/user/#{short}")

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
      admin:     entity://#{@workspace_name}/user/#{@admin_short}
      operator:  entity://#{@workspace_name}/user/#{@operator_short}
      customers: #{results |> Enum.map(fn {n, _, _} -> "entity://#{@workspace_name}/user/#{n}" end) |> Enum.join(", ")}

    Start the server with `mix phx.server`, then:
      • customer → /autoservice (their service session, fast agent greeting)
      • operator → /autoservice/operator (workspace session list → join → chat)
    """)
  end
end
