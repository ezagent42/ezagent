defmodule EzagentPluginLoom.Bootstrap do
  @moduledoc """
  Loom per-visitor bootstrap (loom v0.2, G-C — the orchestration half).

  `run/1` is the entry point: it creates (or reuses) a session, provisions
  a temp user, assembles the Loom team, binds the session to Feishu, and
  joins the temp user — returning `{session_uri, user_uri, orchestrator_uri}`.

  Transport-agnostic by design. The browser frontend (HTTP `/bootstrap` +
  `ws_token` + the session-mirror WS) has been retired; `run/1` is now
  driven programmatically (a `mix run` script — see `e2e.exs`). The ezagent
  orchestration + the one-way Feishu mirror are unchanged.

  ## Reuse vs new (PRD §5.6)

  A caller-supplied `session_uri` that is still ALIVE is reused (the
  orchestrator's memory + the session history are there). A missing /
  dead `session_uri` → a brand-new room (a returning visitor who lost
  their session is treated as new). `Team.ensure_team/1` is an idempotent
  reconciler, so reuse re-runs it as a no-op.

  ## Caps

  All joins go through `system://session-internal` (the `cap(:any, Chat,
  :any)` Catalog principal — same as the Generator's auto-join). The temp
  user's OWN `chat.send` authority comes from its `default_caps/1`
  (`{:session, :any, :any}` in-workspace), so it can speak into its
  session without any extra grant.
  """

  require Logger

  alias Ezagent.Invocation
  alias EzagentPluginLoom.{Team, TempUser}

  # Demo workspace. Per-tenant workspaces are a later (business-PRD) concern.
  @workspace "system"

  @spec run(map()) ::
          {:ok, %{session_uri: URI.t(), user_uri: URI.t(), orchestrator_uri: URI.t()}}
          | {:error, term()}
  def run(opts \\ %{}) when is_map(opts) do
    with {:ok, session_uri} <- ensure_session(opts),
         {:ok, user_uri} <- TempUser.provision(@workspace),
         {:ok, %{orchestrator: orchestrator_uri}} <- Team.ensure_team(session_uri),
         :ok <- join_member(session_uri, user_uri) do
      # Best-effort: mirror this session to the demo Feishu group (PRD §5.4,
      # one-way). Failure must NOT fail bootstrap — the session still works
      # without Feishu.
      maybe_bind_feishu(session_uri)
      # orchestrator_uri is threaded out so the transport (ws_token) can
      # tell the mirror socket which member a user message should @mention
      # — keeping the generic socket free of loom's `loomorch_*` naming.
      {:ok, %{session_uri: session_uri, user_uri: user_uri, orchestrator_uri: orchestrator_uri}}
    end
  end

  # Feishu mirroring is gated OFF by default (env `FEISHU_MIRROR_ENABLED=1`
  # to enable). KNOWN ISSUE: `Ezagent.ExternalMirror` assumes durable
  # sessions — binding our ephemeral per-visitor sessions makes the
  # Worker's `publisher.subscribe_from` return `{:error, :no_such_actor}`
  # (crash-restart storm) AND leaves orphan binding rows that the
  # BootReconciler re-spawns crashing workers for at every boot. Until
  # that subscribe path is sorted, the gate keeps bootstrap clean.
  defp maybe_bind_feishu(session_uri) do
    if System.get_env("FEISHU_MIRROR_ENABLED") == "1" do
      case EzagentPluginLoom.Feishu.bind(session_uri) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("loom bootstrap: feishu bind skipped — #{inspect(reason)}")
      end
    else
      :ok
    end
  end

  # --- session create / reuse --------------------------------------------

  defp ensure_session(opts) do
    case opt(opts, "session_uri") do
      s when is_binary(s) and s != "" ->
        case URI.new(s) do
          {:ok, %URI{scheme: "session"} = uri} -> reuse_or_create(uri)
          _ -> create_session()
        end

      _ ->
        create_session()
    end
  end

  defp reuse_or_create(%URI{} = session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, _pid} -> {:ok, session_uri}
      # Stale / dead URI → new room (PRD §5.6: lost session = new visitor).
      _ -> create_session()
    end
  end

  # Use the domain's session-creation entry point — it builds the
  # canonical 3-segment URI (`session://<template>/<workspace>/<name>`),
  # spawns the bare Session Kind, binds the workspace, and joins a creator.
  # The Loom team + temp user are joined on top by `run/1`.
  defp create_session do
    sid = "s_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))

    # New main changed `create_session/3` to return
    # `{:ok, session_uri, %{orchestrator_uri:, orchestrator_status:, ...}}`
    # — every chat session now auto-spawns a (cc) orchestrator. Loom uses
    # its OWN loomorch via `Team.ensure_team/1`, so we discard that
    # built-in orchestrator info and normalize back to `{:ok, session_uri}`.
    case EzagentDomainInstanceMessage.SessionCreator.create_session(sid, nil,
           template_name: "loom",
           workspace_uri: URI.parse("workspace://#{@workspace}")
         ) do
      {:ok, %URI{} = uri, _orchestrator_info} -> {:ok, uri}
      {:error, _} = err -> err
      other -> {:error, {:create_session_unexpected, other}}
    end
  end

  # --- join the temp user ------------------------------------------------

  defp join_member(%URI{} = session_uri, %URI{} = member_uri) do
    target = URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

    result =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: %{member: member_uri},
        ctx: %{
          caller: Ezagent.SystemPrincipal.uri("session-internal"),
          caps: Ezagent.SystemPrincipal.caps("system://session-internal"),
          reply: {:caller_inbox, self()}
        }
      })

    case result do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:join_failed, URI.to_string(member_uri), reason}}
    end
  end

  defp opt(opts, key), do: Map.get(opts, key) || Map.get(opts, String.to_atom(key))
end
