defmodule EzagentPluginFeishu.InboundChatLookup do
  @moduledoc """
  PR-EM-6 (SPEC §9 PR-EM-6) — chat_id → session_uri reverse lookup
  for the inbound Feishu webhook path.

  Replaces `EzagentPluginFeishu.SessionBinding.resolve/1` (retired in
  this PR along with the rest of the one-off path). The data lives in
  the generic `external_mirror_bindings` projection table maintained
  by `Ezagent.Behavior.ExternalMirror`'s `:bind` / `:unbind` actions
  (PR-EM-3). Inbound direction reads the same table the outbound
  Worker subscribes off of — single SoT, no parallel join table.

  ## Cardinality (codex r1 HIGH fix 2026-05-25 — fail-closed)

  The `external_mirror_bindings` natural key is
  `(session_uri, adapter_id, target_id)` — so the SAME Feishu
  chat_id CAN be bound to multiple sessions. The retired
  `feishu_session_bindings` had `chat_id` as PRIMARY KEY so this
  ambiguity was impossible; the new schema permits it.

  V1 policy: **fail closed on ambiguity** rather than silently
  routing to the oldest (the pre-r1 behavior). An operator who
  legitimately wants a shared chat must explicitly resolve the
  policy. The inbound dispatcher receives
  `{:error, :ambiguous_chat_binding}` and surfaces it back to
  Feishu with a distinct react + text body so the operator sees
  the exact reason rather than messages mysteriously landing in
  the wrong session.

  Per `feedback_let_it_crash_no_workarounds`: no `:warning` + degrade
  paths. A duplicate binding is an operator-actionable
  misconfiguration; the inbound surface flags it loudly + drops
  the message rather than picking one arbitrarily.

  ## Mention-based disambiguation (2026-06-01 — feature)

  Fail-closed-on-ambiguity is correct when ESR has no signal about
  WHICH session the inbound message targets. But when the message
  `@`-mentions a specific agent, that mention IS the signal: route
  to the session the mentioned agent is a member of. This lets one
  Feishu group host multiple orchestrator sessions, disambiguated
  by who is `@`-mentioned.

  `resolve/2` takes the message's mention URIs (already resolved to
  live `entity://agent/...` URIs by `MentionParser`). When 2+ chat
  bindings exist, it counts the candidate sessions whose membership
  contains at least one mentioned agent:

    - exactly ONE candidate → route there;
    - ZERO candidates (no mention, or the mentioned agent isn't a
      member of any bound session) → still `:ambiguous_chat_binding`;
    - 2+ candidates (a mentioned agent is a member of several bound
      sessions) → still `:ambiguous_chat_binding`.

  This is still a structural, fail-closed policy — there is no
  silent "pick the oldest" fallback. The disambiguation only ever
  NARROWS an already-ambiguous set; the 0-or-1-binding cases are
  untouched, and an ambiguous set that the mention can't narrow to
  exactly one stays a hard error.

  Membership is read via `Ezagent.Entity.Session.session_member_uris/1`,
  which returns `[]` for a session whose Kind is not live (a
  non-running session cannot be the routing target anyway).

  ## Why a tiny query module not inline in the dispatcher

  Keeps the inbound dispatcher transport-agnostic and the lookup
  logic test-isolatable. The dispatcher just asks
  `InboundChatLookup.resolve/1`; the lookup module owns the SQL
  query + the multi-row conflict handling.
  """

  require Logger

  import Ecto.Query

  alias Ezagent.ExternalMirror.BindingRow
  alias EzagentCore.Repo

  @adapter_id "feishu"

  @doc """
  Resolve a Feishu `chat_id` to its bound session URI, with no
  mention context. Equivalent to `resolve(chat_id, [])`.

  Kept for back-compat with callers that have no inbound message
  mentions available. See `resolve/2` for the full semantics.
  """
  @spec resolve(String.t()) :: {:ok, URI.t()} | {:error, :ambiguous_chat_binding} | :error
  def resolve(chat_id), do: resolve(chat_id, [])

  @doc """
  Resolve a Feishu `chat_id` to its bound session URI, using the
  inbound message's `@`-mentions to disambiguate when the chat is
  bound to multiple sessions.

  `mentions` is the list of resolved agent URIs (`[URI.t()]`) the
  message `@`-mentions — exactly what `MentionParser.extract_agent_mentions/1`
  returns. Pass `[]` when the message has no mentions.

  Returns:

  - `{:ok, %URI{}}` when EXACTLY ONE binding exists for the chat_id
    under adapter `"feishu"` (`mentions` ignored — no ambiguity to
    resolve).
  - `{:ok, %URI{}}` when 2+ bindings exist AND exactly ONE of those
    bound sessions has a mentioned agent as a member (the `@`-mention
    disambiguates which orchestrator session the message targets).
  - `{:error, :ambiguous_chat_binding}` when 2+ bindings exist and
    the mentions DON'T narrow them to exactly one session — i.e. no
    mention, the mentioned agent is in none of the bound sessions, or
    the mentioned agent is in 2+ of them. Fail closed (codex r1 HIGH
    fix 2026-05-25); the caller (`InboundDispatcher`) surfaces the
    error back to the user via a distinct Feishu react + text body.
    No silent "pick the oldest" fallback.
  - `:error` when no binding exists.
  """
  @spec resolve(String.t(), [URI.t()]) ::
          {:ok, URI.t()} | {:error, :ambiguous_chat_binding} | :error
  def resolve(chat_id, mentions)
      when is_binary(chat_id) and chat_id != "" and is_list(mentions) do
    rows =
      from(r in BindingRow,
        where: r.adapter_id == ^@adapter_id and r.target_id == ^chat_id,
        order_by: r.bound_at,
        select: r.session_uri
      )
      |> Repo.all()

    case rows do
      [] ->
        :error

      [session_uri_str] ->
        {:ok, Ezagent.URI.new!(session_uri_str)}

      multiple ->
        disambiguate(chat_id, multiple, mentions)
    end
  end

  def resolve(_, _), do: :error

  # 2+ bindings: the only way OUT of fail-closed is an `@`-mention
  # that narrows the set to EXACTLY one bound session whose membership
  # contains the mentioned agent.
  defp disambiguate(chat_id, session_uri_strs, mentions) do
    mention_keys = MapSet.new(mentions, &URI.to_string/1)

    candidates =
      session_uri_strs
      |> Enum.map(&Ezagent.URI.new!/1)
      |> Enum.filter(&session_has_mentioned_member?(&1, mention_keys))

    case candidates do
      [session_uri] ->
        # Exactly one bound session has a mentioned agent as a member —
        # the @-mention unambiguously identifies the target session.
        {:ok, session_uri}

      _ ->
        # Zero candidates (no mention, or the mentioned agent is in none
        # of the bound sessions) OR 2+ candidates (a mentioned agent is a
        # member of several bound sessions). Either way the mention does
        # not narrow to exactly one — fail closed, no arbitrary pick.
        Logger.error(
          "InboundChatLookup: chat_id #{chat_id} resolves to MULTIPLE sessions " <>
            "(#{length(session_uri_strs)} bindings): #{inspect(session_uri_strs)}; " <>
            "@-mentions #{inspect(MapSet.to_list(mention_keys))} narrow to " <>
            "#{length(candidates)} candidate session(s) — failing closed " <>
            "(need exactly one; operator must unbind stale row(s) or @-mention " <>
            "an agent that is a member of exactly one bound session)"
        )

        {:error, :ambiguous_chat_binding}
    end
  end

  # True if `session_uri`'s live `:chat` membership contains at least
  # one of the mentioned agent URIs. Compared on canonical string form
  # because the persisted/rehydrated members map may carry either URI
  # structs or their string form (snapshot round-trip).
  defp session_has_mentioned_member?(%URI{} = session_uri, mention_keys) do
    if MapSet.size(mention_keys) == 0 do
      false
    else
      session_uri
      |> member_uris()
      |> Enum.any?(fn member -> MapSet.member?(mention_keys, member_key(member)) end)
    end
  end

  # Membership reader seam. Production reads the live Session Kind's
  # `:chat` members via `Ezagent.Entity.Session.session_member_uris/1`
  # (returns `[]` for a non-live session — which cannot be a routing
  # target anyway). Overridable per-env for unit tests that don't spin
  # up the full Kind supervision tree (same DI pattern as
  # `:ezagent_core, :routing_tables`).
  @default_member_reader {Ezagent.Entity.Session, :session_member_uris}
  defp member_uris(%URI{} = session_uri) do
    {mod, fun} =
      Application.get_env(:ezagent_plugin_feishu, :session_member_reader, @default_member_reader)

    apply(mod, fun, [session_uri])
  end

  defp member_key(%URI{} = uri), do: URI.to_string(uri)
  defp member_key(uri) when is_binary(uri), do: uri

  @doc """
  Reverse: every chat_id currently bound to `session_uri` under the
  Feishu adapter. Used by the admin LV's session-context panel
  (replaces `EzagentPluginFeishu.SessionBinding.chat_ids_for/1`).
  """
  @spec chat_ids_for(URI.t() | String.t()) :: [String.t()]
  def chat_ids_for(%URI{} = session_uri),
    do: chat_ids_for(URI.to_string(session_uri))

  def chat_ids_for(session_uri) when is_binary(session_uri) do
    from(r in BindingRow,
      where: r.session_uri == ^session_uri and r.adapter_id == ^@adapter_id,
      order_by: r.bound_at,
      select: r.target_id
    )
    |> Repo.all()
  end

  def chat_ids_for(_), do: []
end
