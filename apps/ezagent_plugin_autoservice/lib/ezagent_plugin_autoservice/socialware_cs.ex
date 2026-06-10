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
  alias EzagentPluginAutoservice.{CinnoxAssets, CinnoxSoulSeed}

  require Logger

  # The Stage-1 cinnox flow whose skill the bot must be able to Read. Its
  # vendored package lives at `priv/cinnox/skills/customer/<name>/`; the soul's
  # skill-index references it at the in-workdir path
  # `plugins/cinnox/skills/customer/<name>/SKILL.md` (see CinnoxAssets).
  @stage1_skill "customer-type-clarifier"

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
         :ok <- install_routing(session_uri, customer_uri, bot_uri, workspace_uri) do
      # Best-effort adapter start: authoritative in a running server (the
      # seed runs in its own short-lived BEAM where the adapter dies with
      # it — `CustomerLive.mount/3` re-ensures it on the server node).
      _ = ensure_adapter(session_uri, customer_uri)
      {:ok, %{session_uri: session_uri, bot_uri: bot_uri}}
    end
  end

  @doc """
  Runtime: ensure the customer's (already-provisioned) **SocialwareSession** is
  alive and the customer is joined. Returns the session URI.

  This is the `CustomerLive.mount/3` path — the socialware successor to the
  legacy `CustomerSession.ensure_joined/1`, which would spawn a bare
  `Ezagent.Entity.Session` at the same URI and shadow the seeded
  SocialwareSession. `ensure_session/3` spawns the **SocialwareSession** Kind,
  which rehydrates from the seeded snapshot when one exists.
  """
  @spec ensure_joined(URI.t()) :: {:ok, URI.t()} | {:error, term()}
  def ensure_joined(%URI{scheme: "entity"} = customer_uri) do
    ctx = session_internal_ctx()
    session_uri = session_uri(customer_uri)
    workspace_uri = Ezagent.URI.entity_workspace_uri(customer_uri)

    with :ok <- ensure_user_alive(customer_uri),
         :ok <- ensure_session(session_uri, customer_uri, workspace_uri),
         :ok <- join(session_uri, customer_uri, ctx) do
      {:ok, session_uri}
    end
  end

  @doc "The socialware CS session URI for a customer: `session://cs/<ws>/<name>` (no side effects)."
  @spec session_uri(URI.t()) :: URI.t()
  def session_uri(%URI{} = customer_uri) do
    {ws, name} = decompose(customer_uri)
    Ezagent.URI.session(ws, "cs", name)
  end

  @doc "The cc bot agent URI for a customer: `entity://<ws>/agent/cs-bot-<name>` (no side effects)."
  @spec bot_uri(URI.t()) :: URI.t()
  def bot_uri(%URI{} = customer_uri) do
    {ws, name} = decompose(customer_uri)
    # `Workspace.create_agent` composes the agent URI from `name` AS-IS — the
    # flavor is NOT prefixed (workspace/agent_create.ex compose_agent_uri/3,
    # found live: `agent/cs-bot-alice`, not `agent/cc_cs-bot-alice`). bot_uri/1
    # must match what create_agent produces (it's known before create, for
    # seed_soul + routing).
    Ezagent.URI.agent(ws, "#{@bot_create_prefix}#{name}")
  end

  @doc """
  Materialize a vendored customer-role cinnox skill package into a bot's
  working directory so the cc bot can Read it.

  Copies `priv/cinnox/skills/customer/<skill>/` to the in-workdir path the
  soul's skill-index references: `<work_dir>/plugins/cinnox/skills/customer/<skill>/`.
  Reuses the `priv/cinnox` asset layout from `CinnoxAssets` — no new asset
  copy machinery is invented (mirrors `CinnoxRuntime.materialize_cinnox_cc!`).

  Idempotent: the destination is replaced in place, `priv/` is the source of
  truth (same overwrite semantics as `CinnoxRuntime`).
  """
  @spec materialize_skill(Path.t(), String.t()) :: :ok | {:error, term()}
  def materialize_skill(work_dir, skill_name \\ @stage1_skill)
      when is_binary(work_dir) and is_binary(skill_name) do
    src = CinnoxAssets.customer_skill_dir(skill_name)

    if File.dir?(src) do
      dst =
        Path.join([work_dir, "plugins", "cinnox", "skills", "customer", skill_name])

      File.rm_rf!(dst)
      File.mkdir_p!(Path.dirname(dst))

      case File.cp_r(src, dst) do
        {:ok, _} -> :ok
        {:error, reason, _} -> {:error, {:skill_materialize_failed, reason}}
      end
    else
      {:error, {:skill_source_missing, skill_name}}
    end
  end

  @doc """
  Idempotently start the per-session CS turn adapter
  (`SocialwareCSTurnAdapter`) under the plugin's `AdapterSupervisor`,
  registered in `AdapterRegistry` by the session-URI string.

  A second call for the same session is a no-op returning the same pid.
  The adapter drives turns with a privileged principal (the same pattern
  the adapter tests use: `system://bootstrap` caps, admin caller); the
  reply-attribution caller is overridable via `opts[:caller]`.

  Called from BOTH ends of the live wiring:
  - `provision/2` — best-effort (a seed BEAM's adapter dies with it),
  - `CustomerLive.mount/3` — the deterministic prod path (the customer
    opening the chat lazily ensures the adapter on the server node).

  Extra `opts` (e.g. `:idle_window_ms`) are forwarded to the adapter.
  """
  @spec ensure_adapter(URI.t(), URI.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_adapter(%URI{} = session_uri, %URI{} = customer_uri, opts \\ []) do
    key = URI.to_string(session_uri)

    case Registry.lookup(EzagentPluginAutoservice.AdapterRegistry, key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        {caller, opts} = Keyword.pop(opts, :caller, Ezagent.Entity.User.admin_uri())

        ctx = %{
          caller: caller,
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap")
        }

        child_opts =
          Keyword.merge(opts,
            session_uri: session_uri,
            customer_uri: customer_uri,
            ctx: ctx,
            name: {:via, Registry, {EzagentPluginAutoservice.AdapterRegistry, key}}
          )

        case DynamicSupervisor.start_child(
               EzagentPluginAutoservice.AdapterSupervisor,
               {EzagentPluginAutoservice.SocialwareCSTurnAdapter, child_opts}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, {:adapter_start_failed, reason}}
        end
    end
  end

  # --- internals ------------------------------------------------------

  # Privileged internal principal for the lazy mount-time join (same pattern
  # as the legacy `CustomerSession.session_internal_ctx/0`).
  defp session_internal_ctx do
    %{
      caller: Ezagent.SystemPrincipal.uri("session-internal"),
      caps: Ezagent.SystemPrincipal.caps("system://session-internal")
    }
  end

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

        # The real cc bot reads skills from its working dir. Give it a per-bot
        # dir and materialize the Stage-1 flow's skill into it (the soul's
        # skill-index references `plugins/cinnox/skills/customer/<skill>/`).
        work_dir = bot_work_dir(name)
        File.mkdir_p!(work_dir)

        # Write the cinnox soul as the bot's CLAUDE.md so the cc agent is
        # soul-driven from create-time (legacy autoservice path; the cc agent
        # reads CLAUDE.md from its cwd). The soul is ALSO a versioned
        # ConfigObject (DD3) — but the #17 cascade *projection* of it needs a
        # create-time cascade_resolution the minimal create_agent doesn't yet
        # produce (see repoint/3 GAP). Direct CLAUDE.md is the Stage-1 demo
        # source of truth.
        File.write!(Path.join(work_dir, "CLAUDE.md"), CinnoxAssets.build_cc_claude_md())

        case Ezagent.Workspace.create_agent(
               workspace_uri,
               # with_pty: false — headless cc bot replying via the esr
               # bridge (same as the legacy slow agent); :with_pty is a
               # REQUIRED create_agent arg (found live: {:invalid_args,
               # [{[:with_pty], :missing}]}).
               %{
                 flavor: @bot_flavor,
                 name: "#{@bot_create_prefix}#{name}",
                 cwd: work_dir,
                 with_pty: false
               },
               ctx
             ) do
          {:ok, %{agent_uri: %URI{} = uri}} ->
            with :ok <- materialize_skill(work_dir, @stage1_skill),
                 :ok <- repoint(uri, workspace_uri, config_id) do
              {:ok, uri}
            end

          {:error, {:already_exists, _}} ->
            # Idempotent re-run: the bot exists DURABLY (DB/snapshot) even when
            # its Kind isn't alive in THIS BEAM (e.g. a fresh seed VM after an
            # earlier seed created it — found live, Stage-1 seed run 4). The
            # server rehydrates it on demand; re-materialize the skill and
            # re-point the cascade, both idempotent.
            with :ok <- materialize_skill(work_dir, @stage1_skill),
                 :ok <- repoint(bot_uri, workspace_uri, config_id) do
              {:ok, bot_uri}
            end

          {:error, reason} ->
            # Tight race — a now-alive bot is success.
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

  # Persistent per-bot working dir under the ezagent profile (same
  # cc-agents/cinnox tree CinnoxRuntime uses).
  defp bot_work_dir(name) do
    Path.join([Ezagent.Home.profile_dir(), "cc-agents", "cinnox", "#{@bot_create_prefix}#{name}"])
  end

  # Repoint the bot's #17 user-cascade layer at the soul ConfigObject (the
  # socialware self-evolve *projection* path). NON-FATAL: a freshly cc-created
  # agent has no create-time cascade_resolution yet (#17 writes it only when an
  # agent is provisioned through the credential cascade), so this returns
  # {:error, :no_cascade_resolution} for the Stage-1 bot. The bot is already
  # soul-driven via the directly-written CLAUDE.md, so we log + continue.
  # GAP (found live): wiring the soul ConfigObject through the #17 create-time
  # cascade — so self-evolve config updates re-project the CLAUDE.md — is a
  # follow-up; Stage-1 serves the soul as a static CLAUDE.md.
  defp repoint(%URI{} = bot_uri, %URI{} = workspace_uri, config_id) do
    case CascadeRepoint.repoint_user_layer(bot_uri, workspace_uri, config_id) do
      :ok ->
        {:ok, bot_uri}

      {:error, :no_cascade_resolution} ->
        Logger.warning(
          "SocialwareCS: bot #{URI.to_string(bot_uri)} has no #17 cascade_resolution; " <>
            "soul served via direct CLAUDE.md (self-evolve projection deferred)."
        )

        {:ok, bot_uri}

      {:error, reason} ->
        {:error, {:cascade_repoint_failed, reason}}
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

  # customer message in THIS session → the BOT (mirrors the legacy
  # `CustomerSession.install_routing/5` pattern where receivers = the agent
  # URIs). The bot must be a routing receiver to actually RECEIVE the customer
  # message and reply; the Turn adapter needs no receiver slot — it listens on
  # the PubSub session-events topic, which fires regardless of routing.
  # Workspace-scoped so it only fires for this workspace.
  defp install_routing(session_uri, customer_uri, bot_uri, workspace_uri) do
    session_str = URI.to_string(session_uri)
    bot_str = URI.to_string(bot_uri)
    existing = Ezagent.Routing.RuleStore.list(@routing_table)

    # Idempotent: each customer's bot URI is unique, so an existing rule
    # already routing to it means this customer is wired.
    if Enum.any?(existing, fn r -> bot_str in (r.receivers || []) end) do
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
             [bot_uri],
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
