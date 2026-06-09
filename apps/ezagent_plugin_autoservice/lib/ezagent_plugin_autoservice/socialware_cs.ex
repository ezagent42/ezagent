defmodule EzagentPluginAutoservice.SocialwareCS do
  @moduledoc """
  Stage-1 idempotent provisioner that puts the AutoService customer-service
  session on the **socialware base** (`Ezagent.Entity.SocialwareSession`) with a
  single, soul-driven cc bot.

  This is the socialware successor to `EzagentPluginAutoservice.CustomerSession`.
  Two deliberate differences:

  - **Socialware base, not plain Chat.** The session is a
    `Ezagent.Entity.SocialwareSession` (Chat + Turn + Surface + ConfigUpdate),
    so the Turn state machine + Surface approval ride along. The Turn adapter
    (a later task) drives replies; this provisioner only assembles structure.

  - **Single cc bot, NO fast/slow biphasic.** One bot agent, driven by the
    vendored cinnox soul through the #17 user-cascade layer.

  `provision/2` (idempotent — re-running converges, never duplicates):

  1. spawn the `SocialwareSession` + bind it to the workspace,
  2. seed the cinnox soul as a socialware `ConfigObject`
     (`CinnoxSoulSeed.seed_soul/2`) on the bot's session layer,
  3. create the cc bot agent + repoint its #17 user-cascade layer at the soul
     object (`CascadeRepoint.repoint_user_layer/3`),
  4. join the customer + the bot to the session (`chat.join`),
  5. install the `{:from customer, :in_session session} → session` routing rule,
  6. return `{:ok, %{session_uri:, bot_uri:}}`.

  ## LIVE-CC BOUNDARY (`:create_bot_agent`)

  Creating the real cc bot agent (`Ezagent.Workspace.create_agent` with the
  `cc` flavor) needs a live claude environment, and repointing its #17 layer
  (`CascadeRepoint.repoint_user_layer/3`) needs the create-time cascade
  resolution that only a cc-created agent has (it returns
  `{:error, :no_cascade_resolution}` otherwise). Both are gated behind the
  `:create_bot_agent` opt (default `true` in prod). When `false`, the bot is
  brought up as a plain registered `Ezagent.Entity.Agent` so it can still
  satisfy `chat.join`'s member-must-be-registered requirement and the soul +
  routing structure is still assembled — but the cascade is NOT repointed.
  Unit tests pass `create_bot_agent: false` and assert the structural result;
  the live claude reply is exercised by a later live task.
  """

  alias Ezagent.{Invocation, KindRegistry, SpawnRegistry, WorkspaceRegistry}
  alias Ezagent.Socialware.CascadeRepoint
  alias EzagentPluginAutoservice.CinnoxSoulSeed

  require Logger

  # The routing table the chat fan-out / Turn adapter consults
  # (`Ezagent.Routing.Resolver` default — the single declared table). Declared
  # by `EzagentDomainInstanceMessage` at boot.
  @routing_table EzagentDomainInstanceMessage.Routing.MentionRouting

  @bot_flavor "cc"
  # The flavor `name` arg `Workspace.create_agent/3` expects (it composes
  # `entity://agent/<ws>/<flavor>_<name>` itself).
  @bot_create_prefix "cs-bot-"

  @typedoc "Setup context — `%{caller: URI.t(), caps: [Capability.t()]}`."
  @type setup_ctx :: %{caller: URI.t(), caps: term()}

  @doc """
  Seed-time full assembly for one customer on the socialware base. Idempotent.

  Required opts:
  - `:workspace_uri` — `%URI{scheme: "workspace"}`
  - `:ctx` — `%{caller:, caps:}` privileged setup principal

  Optional opts:
  - `:create_bot_agent` — when `true` (default) create the real cc bot agent +
    repoint its #17 user-cascade layer; when `false` bring the bot up as a plain
    registered entity and skip the cascade repoint (see LIVE-CC BOUNDARY).
  """
  @spec provision(URI.t(), keyword()) ::
          {:ok, %{session_uri: URI.t(), bot_uri: URI.t()}} | {:error, term()}
  def provision(%URI{scheme: "entity"} = customer_uri, opts) do
    workspace_uri = Keyword.fetch!(opts, :workspace_uri)
    ctx = Keyword.fetch!(opts, :ctx)
    create_bot_agent? = Keyword.get(opts, :create_bot_agent, true)

    session_uri = session_uri(customer_uri)
    bot_uri = bot_uri(customer_uri)

    with :ok <- ensure_user_alive(customer_uri),
         :ok <- ensure_session(session_uri, customer_uri, workspace_uri),
         {:ok, %{config_id: config_id}} <- seed_soul(bot_uri, workspace_uri),
         {:ok, ^bot_uri} <-
           ensure_bot(customer_uri, bot_uri, workspace_uri, config_id, create_bot_agent?, ctx),
         :ok <- join(session_uri, customer_uri, ctx),
         :ok <- join(session_uri, bot_uri, ctx),
         :ok <- install_routing(session_uri, customer_uri, workspace_uri) do
      {:ok, %{session_uri: session_uri, bot_uri: bot_uri}}
    end
  end

  @doc "The socialware CS session URI for a customer: `session://cs/<ws>/<name>` (no side effects)."
  @spec session_uri(URI.t()) :: URI.t()
  def session_uri(%URI{} = customer_uri) do
    {ws, name} = decompose(customer_uri)
    Ezagent.URI.session(ws, "cs", name)
  end

  @doc "The cc bot agent URI for a customer: `entity://agent/<ws>/cc_cs-bot-<name>` (no side effects)."
  @spec bot_uri(URI.t()) :: URI.t()
  def bot_uri(%URI{} = customer_uri) do
    {ws, name} = decompose(customer_uri)
    Ezagent.URI.agent(ws, "#{@bot_flavor}_#{@bot_create_prefix}#{name}")
  end

  # --- internals ------------------------------------------------------

  defp decompose(%URI{scheme: "entity"} = uri) do
    ws = Ezagent.URI.workspace_name!(uri)

    name =
      case Ezagent.URI.name(uri) do
        {:ok, name} -> name
        :error -> raise ArgumentError, "expected a named entity URI, got: #{inspect(uri)}"
      end

    {ws, name}
  end

  # Spawning a User Kind via SpawnRegistry is the documented pattern (mirrors
  # `EzagentDomainChat.join_creator/2`). The customer must be a registered Kind
  # for `chat.join` to accept it as a member.
  defp ensure_user_alive(%URI{} = uri) do
    case KindRegistry.lookup(uri) do
      {:ok, _pid} ->
        :ok

      :error ->
        case SpawnRegistry.spawn(uri) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, {:user_spawn_failed, URI.to_string(uri), reason}}
        end
    end
  end

  defp ensure_session(%URI{} = session_uri, %URI{} = owner_uri, %URI{} = workspace_uri) do
    spawn_result =
      case KindRegistry.lookup(session_uri) do
        {:ok, _pid} ->
          :ok

        :error ->
          case Ezagent.Kind.spawn(Ezagent.Entity.SocialwareSession, %{
                 uri: session_uri,
                 owner_uri: owner_uri
               }) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
            {:error, {:already_registered, _}} -> :ok
            {:error, reason} -> {:error, {:session_spawn_failed, reason}}
          end
      end

    with :ok <- spawn_result do
      # WorkspaceRegistry.bind/2 always returns :ok (idempotent ETS put).
      :ok = WorkspaceRegistry.bind(session_uri, workspace_uri)
      :ok
    end
  end

  # Seed the cinnox soul as an immutable socialware ConfigObject on the bot's
  # session layer. Idempotent: `ConfigStore.write_and_point` keys the object by
  # content, so a re-seed converges on the same object.
  defp seed_soul(%URI{} = bot_uri, %URI{} = workspace_uri) do
    case CinnoxSoulSeed.seed_soul(bot_uri, workspace_uri) do
      {:ok, %{config_id: _} = result} -> {:ok, result}
      {:error, reason} -> {:error, {:soul_seed_failed, reason}}
    end
  end

  # Bring the cc bot agent up and repoint its #17 user-cascade layer at the soul
  # ConfigObject. See LIVE-CC BOUNDARY: gated behind `create_bot_agent?`.
  defp ensure_bot(customer_uri, bot_uri, workspace_uri, config_id, true, ctx) do
    case KindRegistry.lookup(bot_uri) do
      {:ok, _pid} ->
        repoint(bot_uri, workspace_uri, config_id)

      :error ->
        {_ws, name} = decompose(customer_uri)

        case Ezagent.Workspace.create_agent(
               workspace_uri,
               %{flavor: @bot_flavor, name: "#{@bot_create_prefix}#{name}"},
               ctx
             ) do
          {:ok, %{agent_uri: %URI{} = uri}} ->
            with :ok <- repoint(uri, workspace_uri, config_id), do: {:ok, uri}

          {:error, reason} ->
            # Idempotent re-run / tight race — a now-alive bot is success.
            case KindRegistry.lookup(bot_uri) do
              {:ok, _pid} -> repoint(bot_uri, workspace_uri, config_id)
              :error -> {:error, {:bot_agent_create_failed, reason}}
            end
        end
    end
  end

  # LIVE-CC BOUNDARY: bot brought up as a plain registered entity, cascade NOT
  # repointed (a plain agent has no cascade_resolution to repoint). Used by unit
  # tests asserting the structural result.
  defp ensure_bot(_customer_uri, bot_uri, _workspace_uri, _config_id, false, _ctx) do
    case KindRegistry.lookup(bot_uri) do
      {:ok, _pid} ->
        {:ok, bot_uri}

      :error ->
        case Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: bot_uri}) do
          {:ok, _pid} -> {:ok, bot_uri}
          {:error, {:already_started, _pid}} -> {:ok, bot_uri}
          {:error, {:already_registered, _}} -> {:ok, bot_uri}
          {:error, reason} -> {:error, {:bot_spawn_failed, reason}}
        end
    end
  end

  defp repoint(%URI{} = bot_uri, %URI{} = workspace_uri, config_id) do
    case CascadeRepoint.repoint_user_layer(bot_uri, workspace_uri, config_id) do
      :ok -> {:ok, bot_uri}
      {:error, reason} -> {:error, {:cascade_repoint_failed, reason}}
    end
  end

  defp join(%URI{} = session_uri, %URI{} = member_uri, ctx) do
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

    result =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: %{member: member_uri},
        ctx: Map.put(ctx, :reply, {:caller_inbox, self()})
      })

    case result do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, {:join_failed, URI.to_string(member_uri), reason}}
    end
  end

  # customer message in THIS session → the session itself (the Turn adapter,
  # installed in a later task, picks the message off the session and drives the
  # bot reply). Workspace-scoped so it only fires for this workspace.
  defp install_routing(session_uri, customer_uri, workspace_uri) do
    session_str = URI.to_string(session_uri)
    existing = Ezagent.Routing.RuleStore.list(@routing_table)

    # Idempotent: each customer's session URI is unique, so an existing rule
    # already routing to it means this customer is wired.
    if Enum.any?(existing, fn r -> session_str in (r.receivers || []) end) do
      _ = Ezagent.Routing.RuleStore.load_into_registry(@routing_table)
      :ok
    else
      matcher =
        {:and,
         [
           {:in_session, session_str},
           {:from, URI.to_string(customer_uri)}
         ]}

      case Ezagent.Routing.RuleStore.add(
             @routing_table,
             matcher,
             [session_uri],
             nil,
             workspace_uri: workspace_uri
           ) do
        {:ok, _rule} ->
          _ = Ezagent.Routing.RuleStore.load_into_registry(@routing_table)
          :ok

        {:error, reason} ->
          {:error, {:routing_rule_failed, reason}}
      end
    end
  end
end
