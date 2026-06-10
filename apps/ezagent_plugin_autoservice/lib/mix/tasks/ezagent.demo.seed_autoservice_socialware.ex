defmodule Mix.Tasks.Ezagent.Demo.SeedAutoserviceSocialware do
  @shortdoc "Seed the Stage-1 socialware CS demo (workspace + customer + soul-driven cc bot)"
  @moduledoc """
  > **Demo seeder** (Category A, same class as `ezagent.demo.seed_autoservice`).
  > Runs in its own BEAM via `Application.ensure_all_started/1`; the
  > Kinds it spawns persist as snapshots + DB rows that the running /
  > next server rehydrates. NOT a normal operator op — stays
  > `mix ezagent.demo.*`, not `mix ezagent`.

  Seeds the Stage-1 **socialware** customer-service demo end to end:

  1. `workspace://cinnox`
  2. one customer user `entity://user/cinnox/alice` (password `alice`)
     with the `:customer` role cap-bundle,
  3. `EzagentPluginAutoservice.SocialwareCS.provision/2` — the LIVE
     branch: a `SocialwareSession` (`session://cs/cinnox/alice`), the
     cinnox soul `ConfigObject`, the **cc bot agent** with its #17
     user-cascade layer repointed at the soul, both joined, and the
     customer→BOT routing rule installed.

  Idempotent: re-running converges (existing workspace/user/session/bot
  are reused).

  ## Usage

      mix ecto.create && mix ecto.migrate   # first run only
      mix ezagent.demo.seed_autoservice_socialware

      # structural smoke run without a live claude environment:
      mix ezagent.demo.seed_autoservice_socialware --no-bot

  After seeding, with the server running (`mix phx.server`), log in at
  `/login` as `alice` / `alice` and open `/autoservice`. The customer
  opening the chat lazily ensures the per-session Turn adapter on the
  SERVER node (`CustomerLive.mount/3` → `SocialwareCS.ensure_adapter/3`)
  — the adapter this seed BEAM starts dies with the seed, by design.

  ## `--no-bot`

  Passes `create_bot_agent: false` to `provision/2` (LIVE-CC BOUNDARY):
  the bot comes up as a plain registered entity and the cascade is NOT
  repointed — structure only, no live claude reply.
  """
  use Mix.Task

  alias EzagentPluginAutoservice.{Roles, SocialwareCS}

  @workspace_name "cinnox"
  @customer_short "alice"

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _} = OptionParser.parse(argv, strict: [no_bot: :boolean])

    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_workspace)
    # NOTE: NOT `:ezagent_domain_chat` (the legacy seeder's stale atom —
    # no such app exists); the chat/session domain is instance_message.
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_instance_message)
    # The socialware base (SocialwareSession Kind + Turn/Surface/ConfigStore).
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_socialware)
    # The bot is a cc (claude) flavor — its flavor registration lives in
    # the cc plugin, which this seed BEAM doesn't otherwise boot.
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_cc)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_autoservice)

    create_bot? = not Keyword.get(opts, :no_bot, false)

    workspace_uri = Ezagent.URI.new!("workspace://#{@workspace_name}")
    customer_uri = user_uri(@customer_short)
    ctx = mix_task_ctx()

    Mix.shell().info("Seeding Stage-1 socialware CS demo (`#{@workspace_name}`) …")

    :ok = ensure_workspace()
    :ok = seed_customer(@customer_short, workspace_uri)

    case SocialwareCS.provision(customer_uri,
           workspace_uri: workspace_uri,
           ctx: ctx,
           create_bot_agent: create_bot?
         ) do
      {:ok, %{session_uri: session_uri, bot_uri: bot_uri}} ->
        print_summary(session_uri, bot_uri, create_bot?)

      {:error, reason} ->
        Mix.raise("provision failed for #{URI.to_string(customer_uri)}: #{inspect(reason)}")
    end
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
        case Ezagent.KindRegistry.lookup(Ezagent.URI.new!("workspace://#{@workspace_name}")) do
          {:ok, _pid} ->
            Mix.shell().info("  workspace://#{@workspace_name} already exists")
            :ok

          :error ->
            Mix.raise("workspace create failed: #{inspect(reason)}")
        end
    end
  end

  # Mirrors `seed_autoservice.ex` `seed_role_user/4`: password login row +
  # workspace membership + role caps granted via dispatch (synchronous —
  # the seed VM exits right after) + seed-VM snapshot delete (cross-VM
  # :unsafe_atom safety; the server rehydrates from DB rows).
  defp seed_customer(short, workspace_uri) do
    uri = user_uri(short)
    extra_caps = Roles.bundle(:customer, workspace_uri)

    case Ezagent.Users.create(uri, short, extra_caps) do
      {:ok, _decoded} ->
        Mix.shell().info("  user #{URI.to_string(uri)} (customer) created")

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :uri) do
          Mix.shell().info("  user #{URI.to_string(uri)} (customer) already exists")
        else
          Mix.raise("user create failed for #{URI.to_string(uri)}: #{inspect(errors)}")
        end

      {:error, reason} ->
        Mix.raise("user create failed for #{URI.to_string(uri)}: #{inspect(reason)}")
    end

    _ = add_member(uri)

    grant_ctx = Map.put(mix_task_ctx(), :reply, {:caller_inbox, self()})

    Enum.each(extra_caps, fn cap ->
      case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
             target: Ezagent.URI.new!("#{URI.to_string(uri)}?action=identity.grant_cap"),
             mode: :call,
             args: %{cap: cap},
             ctx: grant_ctx
           }) do
        {:ok, _result} ->
          :ok

        {:error, reason} ->
          Mix.shell().info("  grant_cap #{URI.to_string(uri)}: #{inspect(reason)}")
      end
    end)

    Ezagent.Ecto.KindSnapshot.delete(URI.to_string(uri))

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

  defp user_uri(short), do: Ezagent.URI.new!("entity://user/#{@workspace_name}/#{short}")

  defp mix_task_ctx do
    %{
      caller: Ezagent.SystemPrincipal.uri("mix-task"),
      caps: Ezagent.SystemPrincipal.caps("system://mix-task")
    }
  end

  defp print_summary(session_uri, bot_uri, create_bot?) do
    bot_note =
      if create_bot? do
        "cc bot (soul-driven, #17 cascade repointed)"
      else
        "plain entity bot (--no-bot: no cascade repoint, no live reply)"
      end

    Mix.shell().info("""

    Stage-1 socialware CS demo seeded.

      ✓ session  #{URI.to_string(session_uri)}
      ✓ bot      #{URI.to_string(bot_uri)}  [#{bot_note}]

    Login at /login as `#{@customer_short}` / password `#{@customer_short}`,
    then open /autoservice — mounting the chat ensures the Turn adapter
    on the server node (the adapter started by this seed BEAM dies with it).
    """)
  end
end
