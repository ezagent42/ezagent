defmodule Ezagent.Socialware.SessionReads do
  @moduledoc """
  The single cap-gated read chokepoint for a session's conversation plane
  (messages + members) AND the session's external-feed plane (external-visible
  messages + delivery outbox + surface page/shell).

  ## Why this exists (the X — read-plane-authz spec §0/§1)

  Message + member READS were scattered as direct `MessageStore.*` /
  `Kind.get_slice(_, :session)` calls in LiveView data-loaders and controllers
  with **zero authorization** — so a logged-in non-member could deep-link
  `?session=<uri>` and read a conversation they were never a member of, and a
  rejected-`self_join` "observer" degraded to an observe-read. Because those
  reads never passed through a chokepoint, the write-plane cap-signing hardening
  (#1457) could not reach them (write-signed / read-ungated inversion).

  `SessionReads` is that chokepoint: **every principal-facing conversation read
  routes through here, is authorized FIRST, and only then touches the store.** A
  mechanism update (authz, row-policy, filtering, logging) now changes one place
  and every caller inherits it; a new bypass is caught by the module-boundary
  gate (`message_read_chokepoint_boundary_test`).

  ## Contract (binding — read-plane-authz plan Pillar A)

  Every function takes `caller` FIRST and authorizes BEFORE any read. A
  non-member / non-authorized caller gets `{:error, :unauthorized}`
  (fail-closed) — never a degraded / observe read.

    * `messages(caller, session_uri, view \\\\ :conversation, page_opts)` covers
      BOTH the initial recent load AND older/pagination (a single authorized
      door for the whole conversation history), returning the raw
      `[%Message{}]` in store order (descending) so results are byte-identical
      to the pre-consolidation direct-store reads.
    * `members(caller, session_uri)` returns the raw `:session`-slice members
      map (`%{URI => meta}`), the authoritative source the presenters shape.
    * `external_deliveries_since/3`, `latest_external_delivery_cursor/2` and
      `committed_external_surface_version/2` are the DELIVERY plane (the
      durable `DeliveryOutbox` commit-cursor reads the external feed replays
      and pages from).
    * `external_snapshot_reads/3` is the ATOMIC snapshot plane: the committed
      external-visible messages + the committed surface version authorized ONCE
      and read in straddle-safe (version-first) order, so a mid-read settlement
      commit can never yield a rendered page without its messages.
    * `external_surface/2` is the SURFACE plane (the `:surface`-slice page/shell
      read, cold-safe via the durable-snapshot fallback).

  ## Two authorization modes (spec §3.2 — live-first, both fail-closed)

  Authorization delegates to the shared `Ezagent.Session.Membership.authorize/3`
  predicate — the SAME one the feeds (`ChatFeed` / `ExternalFeed`) and
  `SocialwarePublisherRead` use. It is **live-first**: it reads the live
  `:session` slice and the caller's live caps (`EntityCaps.load/1`), so an
  async at-join member-cap grant that is not yet persisted is still seen —
  a fresh join is NOT falsely denied. Cost is one predicate call **per read**
  (not per row).

    * **Strict membership** (`:conversation` / `:chat_feed` views, `members/2`,
      `authorized?/2`): owner/member only. A `public_view` session does NOT
      open the internal conversation read — the deep-link fix depends on it.
    * **Public-aware read gate** (the external-feed plane: `:external_feed` /
      `:external_chat` views, delivery and surface reads): strict membership
      OR the session's installed-socialware `public_view` open policy
      (`PublicView.web_anon_access?/1`), folded INTO the chokepoint (PR-2) so
      the anon/public open policy cannot be bypassed or half-applied at a
      call-site. A public session is readable by ANY caller (the same public
      page an anonymous visitor sees); a private session stays strict
      member-only. This never grants write.

  ## Row-policy ownership (spec §3.1 step 2 — moved INTO the chokepoint)

  The `:read_unfiltered` decision (visible-only vs unfiltered rows) is sourced
  HERE from the caller's own live caps (`EntityCaps.load/1`) — it is NEVER a
  caller-supplied flag (that would re-open a caller-selectable bypass). Only a
  caller holding the session's `Ezagent.ActionSet.Session :read_unfiltered` cap
  reads `:internal` messages; everyone else gets the `:external_visible` view.
  This logic used to live in `Ezagent.World.ConversationData`; consolidating it
  here makes it un-bypassable.
  """

  import Ecto.Query

  alias Ezagent.MessageStore
  alias Ezagent.Session.Membership
  alias Ezagent.Socialware.{DeliveryOutbox, PublicView}
  alias EzagentCore.Repo

  @typedoc "Fixed view enum — selects a query SHAPE, never widens VISIBILITY."
  @type view :: :conversation | :chat_feed | :external_feed | :external_chat

  @typedoc """
  A committed-delivery row as replayed by the external feed: the commit-order
  cursor, the settled turn, the delivered message ids, and the committed page
  version (nil for a messages-only commit).
  """
  @type delivery :: %{
          cursor: integer(),
          turn_id: String.t(),
          message_ids: [String.t()],
          surface_version: integer() | nil
        }

  @typedoc """
  Read options. `:limit` bounds the batch (required by the recency-window
  views); an `:older_than` cursor (a `DateTime`) selects the pagination window,
  its absence the initial recency window. `:ids` (the `:external_feed` view
  only) selects the committed external-visible messages in a fixed id set (the
  delivery-replay render read) instead of windowing by recency.
  """
  @type page_opts :: %{
          optional(:limit) => pos_integer(),
          optional(:older_than) => DateTime.t(),
          optional(:ids) => [String.t()]
        }

  @doc """
  Authorized conversation/feed messages for `caller` in `session_uri`.

  Authorizes `caller` BEFORE reading. On success returns `{:ok, [%Message{}]}`
  in store order; a non-authorized / nil / malformed caller gets
  `{:error, :unauthorized}`.

  `view` is a fixed enum selecting the query shape AND the authorization mode
  (§ moduledoc "Two authorization modes"):

    * `:conversation` — strict membership; routes to
      `recent_visible_in_session`/`recent_in_session` (initial) or
      `older_visible_than`/`older_than` (pagination, via the `:older_than`
      cursor in `page_opts`) per the internally-decided `:read_unfiltered`
      row-policy.
    * `:chat_feed` — strict membership; ChatFeed's snapshot read, routes to
      `chat_visible_recent/2` (the external-visible chat recency window,
      byte-identical to ChatFeed's pre-consolidation direct store read).
    * `:external_feed` — public-aware read gate; ExternalFeed's delivered
      projection, routes to `committed_external_visible/2` for `%{limit: n}`
      or `committed_external_visible_by_ids/2` for `%{ids: ids}` (the
      delivery-replay render read), byte-identical to ExternalFeed's
      pre-consolidation direct store reads.
    * `:external_chat` — public-aware read gate; ExternalFeed's full-chat
      read, routes to `chat_visible_recent/2`.
  """
  @spec messages(URI.t() | term(), URI.t(), view(), page_opts()) ::
          {:ok, [Ezagent.Message.t()]} | {:error, :unauthorized}
  def messages(caller, session_uri, view \\ :conversation, page_opts)

  def messages(caller, %URI{} = session_uri, :conversation, page_opts) when is_map(page_opts) do
    with :ok <- authorize(caller, session_uri) do
      {:ok, conversation_read(session_uri, read_unfiltered?(caller, session_uri), page_opts)}
    end
  end

  def messages(caller, %URI{} = session_uri, :chat_feed, page_opts) when is_map(page_opts) do
    with :ok <- authorize(caller, session_uri) do
      {:ok, chat_feed_read(session_uri, page_opts)}
    end
  end

  def messages(caller, %URI{} = session_uri, :external_feed, page_opts) when is_map(page_opts) do
    with :ok <- authorize_external_read(caller, session_uri) do
      {:ok, external_feed_read(session_uri, page_opts)}
    end
  end

  def messages(caller, %URI{} = session_uri, :external_chat, page_opts) when is_map(page_opts) do
    with :ok <- authorize_external_read(caller, session_uri) do
      {:ok, external_chat_read(session_uri, page_opts)}
    end
  end

  @doc """
  Authorized session members for `caller` in `session_uri`.

  Authorizes `caller` BEFORE reading; on success returns
  `{:ok, %{URI => meta}}` (the raw `:session`-slice members map the presenters
  shape), else `{:error, :unauthorized}`.
  """
  @spec members(URI.t() | term(), URI.t()) ::
          {:ok, %{optional(URI.t()) => map()}} | {:error, :unauthorized}
  def members(caller, %URI{} = session_uri) do
    with :ok <- authorize(caller, session_uri) do
      {:ok, members_map(session_uri)}
    end
  end

  @doc """
  Whether `caller` is authorized to read `session_uri`'s conversation plane —
  the boolean form of the same live-first predicate `messages/4`/`members/2`
  gate on.

  This is the door the LIVE plane consults: the `world_live` broadcast handler
  drops a `:chat_message` for an unauthorized caller, and roster pushes are
  suppressed for one. Gating a persisted read is not enough — the ungated live
  broadcast + roster push were the read-plane-authz round-2 findings (F1/F2).
  """
  @spec authorized?(URI.t() | term(), URI.t()) :: boolean()
  def authorized?(caller, %URI{} = session_uri), do: authorize(caller, session_uri) == :ok

  # ----- DELIVERY plane (the durable outbox commit-cursor reads) -------------

  @doc """
  Authorized replay of `session_uri`'s committed external deliveries with
  `committed_seq > cursor` (ascending commit order).

  Authorizes `caller` (public-aware read gate § moduledoc) BEFORE reading; on
  success returns `{:ok, [%{cursor, turn_id, message_ids, surface_version}]}`
  — byte-identical to `ExternalFeed`'s pre-consolidation direct outbox query.
  A non-authorized caller gets `{:error, :unauthorized}` (fail closed).
  """
  @spec external_deliveries_since(URI.t() | term(), URI.t(), integer()) ::
          {:ok, [delivery()]} | {:error, :unauthorized}
  def external_deliveries_since(caller, %URI{} = session_uri, cursor) when is_integer(cursor) do
    with :ok <- authorize_external_read(caller, session_uri) do
      {:ok, deliveries_since(session_uri, cursor)}
    end
  end

  @doc """
  The highest committed-delivery cursor for `session_uri` (0 if none),
  authorized by the public-aware read gate.
  """
  @spec latest_external_delivery_cursor(URI.t() | term(), URI.t()) ::
          {:ok, integer()} | {:error, :unauthorized}
  def latest_external_delivery_cursor(caller, %URI{} = session_uri) do
    with :ok <- authorize_external_read(caller, session_uri) do
      {:ok, latest_delivery_cursor(session_uri)}
    end
  end

  @doc """
  The `surface_version` of `session_uri`'s latest page-bearing COMMITTED
  delivery (nil when no committed page), authorized by the public-aware read
  gate. Commit-order (descending `committed_seq`) so a ROLLBACK correctly
  re-approves an older retained version.
  """
  @spec committed_external_surface_version(URI.t() | term(), URI.t()) ::
          {:ok, integer() | nil} | {:error, :unauthorized}
  def committed_external_surface_version(caller, %URI{} = session_uri) do
    with :ok <- authorize_external_read(caller, session_uri) do
      {:ok, committed_surface_version(session_uri)}
    end
  end

  # ----- SURFACE plane (the `:surface`-slice page/shell read) ----------------

  @doc """
  The authorized `:surface` slice (page/shell state) of `session_uri`.

  Authorizes `caller` (public-aware read gate § moduledoc) BEFORE reading.
  COLD-SAFE: tries the live slice first; on `:not_found` falls back to the
  durable snapshot via `Ezagent.Kind.StateRebuilder.rebuild/1` +
  `Ezagent.Kind.normalize_slice_view/1`, so a committed page still renders
  after a BEAM restart / reaped session. Returns `{:ok, surface_map}`
  (`%{}` when the session has no surface) or `{:error, :unauthorized}`.
  """
  @spec external_surface(URI.t() | term(), URI.t()) ::
          {:ok, map()} | {:error, :unauthorized}
  def external_surface(caller, %URI{} = session_uri) do
    with :ok <- authorize_external_read(caller, session_uri) do
      {:ok, surface_slice(session_uri)}
    end
  end

  @external_snapshot_limit 100

  @doc """
  Atomic external-feed snapshot reads for `caller` in `session_uri`: the committed
  external-visible messages AND the committed surface version, authorized ONCE
  (public-aware read gate) and read in a STRADDLE-SAFE order.

  Reads the committed version FIRST, then the messages. Settlement commits are
  atomic (`Settlement.commit_after_pointer/2` flips settlement status + assigns
  `DeliveryOutbox.committed_seq`/`surface_version` in one transaction) and
  monotonic, so version-first guarantees: if a committed `version` is reported,
  that committed turn's messages are already visible to the later messages read
  (no page-without-content straddle). The benign inverse (messages ahead of the
  page for one poll) self-heals and is covered by the durable delivery replay.

  `opts[:mid_read]` is a 0-arity TEST seam fired AFTER the version read and BEFORE
  the messages read — the straddle-injection point. Defaults to a no-op; never set
  in production.

  `@external_snapshot_limit` MUST stay equal to `ExternalFeed.@history_limit` —
  the snapshot parity test depends on the identical recency window.
  """
  @spec external_snapshot_reads(URI.t() | term(), URI.t(), keyword()) ::
          {:ok, %{messages: [Ezagent.Message.t()], version: integer() | nil}}
          | {:error, :unauthorized}
  def external_snapshot_reads(caller, %URI{} = session_uri, opts \\ []) when is_list(opts) do
    with :ok <- authorize_external_read(caller, session_uri) do
      version = committed_surface_version(session_uri)
      run_mid_read(opts[:mid_read])
      messages = external_feed_read(session_uri, %{limit: @external_snapshot_limit})
      {:ok, %{messages: messages, version: version}}
    end
  end

  defp run_mid_read(nil), do: :ok
  defp run_mid_read(fun) when is_function(fun, 0), do: fun.()

  # ----- authorization (live-first, shared predicate) ------------------------

  # The SAME live, fail-closed owner/member predicate the feeds use. Reads the
  # live `:session` slice + the caller's held member-cap (A2.3/R1.1) so an
  # ex-member is denied immediately and a fresh async-granted member is allowed.
  defp authorize(caller, %URI{} = session_uri) do
    Membership.authorize(chat_slice(session_uri), caller, session_uri, caller)
  end

  # The external-feed-plane READ gate (PR-2 — the public-view open policy
  # folded INTO the chokepoint). Deliberately BROADER than participation:
  # strict membership first; on a membership denial, a `public_view` session
  # (its installed socialware permits anonymous web access) is readable by ANY
  # caller — exactly the sessions where an anonymous visitor is admitted
  # read-only at ingress — so a signed-in NON-member (or an anon principal)
  # sees the same public page instead of a dead "无权限". A private session
  # stays strict member-only. This never grants write: posting, attachment
  # downloads, and the `viewer.member` flag keep using the strict predicate.
  defp authorize_external_read(caller, %URI{} = session_uri) do
    case authorize(caller, session_uri) do
      :ok ->
        :ok

      {:error, _} = err ->
        if PublicView.web_anon_access?(session_uri), do: :ok, else: err
    end
  end

  defp chat_slice(%URI{} = session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, slice} -> slice
      _ -> nil
    end
  end

  defp members_map(%URI{} = session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, %{members: members}} when is_map(members) -> members
      _ -> %{}
    end
  end

  # ----- :conversation view routing (shape × row-policy) ---------------------

  # Initial recency window (no cursor).
  defp conversation_read(%URI{} = session_uri, unfiltered?, %{limit: limit} = opts)
       when is_integer(limit) and limit > 0 and not is_map_key(opts, :older_than) do
    if unfiltered? do
      MessageStore.recent_in_session(session_uri, limit)
    else
      MessageStore.recent_visible_in_session(session_uri, limit)
    end
  end

  # Pagination window (strictly older than the cursor).
  defp conversation_read(%URI{} = session_uri, unfiltered?, %{
         limit: limit,
         older_than: %DateTime{} = cursor
       })
       when is_integer(limit) and limit > 0 do
    if unfiltered? do
      MessageStore.older_than(session_uri, cursor, limit)
    else
      MessageStore.older_visible_than(session_uri, cursor, limit)
    end
  end

  # ----- :chat_feed view routing (ChatFeed's snapshot read) ------------------

  # The chat feed projects ONLY :external_visible messages: its read is the chat
  # recency window `chat_visible_recent/2` — byte-identical to the direct store
  # call ChatFeed made before consolidating onto this chokepoint.
  defp chat_feed_read(%URI{} = session_uri, %{limit: limit})
       when is_integer(limit) and limit > 0 do
    MessageStore.chat_visible_recent(session_uri, limit)
  end

  # ----- :external_feed view routing (ExternalFeed's delivered projection) ----

  # The delivered external projection: committed + external-visible messages.
  # The `%{limit: n}` window is ExternalFeed's snapshot/history read; the
  # `%{ids: ids}` form is its delivery-replay render read — both byte-identical
  # to the direct store calls ExternalFeed made before consolidating here.
  defp external_feed_read(%URI{} = session_uri, %{limit: limit})
       when is_integer(limit) and limit > 0 do
    MessageStore.committed_external_visible(session_uri, limit)
  end

  defp external_feed_read(%URI{} = session_uri, %{ids: ids}) when is_list(ids) do
    MessageStore.committed_external_visible_by_ids(session_uri, ids)
  end

  # ----- :external_chat view routing (ExternalFeed's full-chat read) ----------

  # The FULL collaborative chat window (every external-visible message), gated
  # by the public-aware read gate (the page is already public_view) — the same
  # store shape as :chat_feed but the broader external-feed authorization.
  defp external_chat_read(%URI{} = session_uri, %{limit: limit})
       when is_integer(limit) and limit > 0 do
    MessageStore.chat_visible_recent(session_uri, limit)
  end

  # ----- DELIVERY plane reads (moved out of ExternalFeed verbatim) ------------

  # Committed outbox rows with `committed_seq > cursor` (ascending). `committed_seq`
  # is assigned at the commit boundary in commit order, so this never skips a late
  # out-of-order commit.
  defp deliveries_since(%URI{} = session_uri, cursor) do
    session_str = URI.to_string(session_uri)

    from(o in DeliveryOutbox,
      where:
        o.session_uri == ^session_str and not is_nil(o.committed_seq) and
          o.committed_seq > ^cursor,
      order_by: [asc: o.committed_seq],
      select: %{
        cursor: o.committed_seq,
        turn_id: o.turn_id,
        message_ids: o.message_ids,
        surface_version: o.surface_version
      }
    )
    |> Repo.all()
  end

  # The highest committed-delivery cursor for a session (0 if none).
  defp latest_delivery_cursor(%URI{} = session_uri) do
    session_str = URI.to_string(session_uri)

    from(o in DeliveryOutbox,
      where: o.session_uri == ^session_str and not is_nil(o.committed_seq),
      select: max(o.committed_seq)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  # The target_surface_version of the most-recently-COMMITTED page-bearing
  # delivery, ordered by committed_seq (the SAME order deliveries_since/2
  # replays). Commit-order (not max(version)) so a ROLLBACK (a later commit
  # re-approving an older retained version) correctly makes that older version
  # the page; committed_seq is a total order so a committed_at tie can't pick an
  # older turn. nil when no committed page (messages-only commits have
  # surface_version nil).
  defp committed_surface_version(%URI{} = session_uri) do
    session_str = URI.to_string(session_uri)

    from(o in DeliveryOutbox,
      where:
        o.session_uri == ^session_str and not is_nil(o.committed_seq) and
          not is_nil(o.surface_version),
      order_by: [desc: o.committed_seq],
      limit: 1,
      select: o.surface_version
    )
    |> Repo.one()
  end

  # ----- SURFACE plane read (moved out of ExternalFeed verbatim) --------------

  # COLD-SAFE surface read. `get_slice/2` needs a live session process (it does
  # NOT lazy-spawn); after a BEAM restart / reaped session the committed page
  # must still render from the durable snapshot. Try the live slice first; on
  # `:not_found` fall back to the snapshot via StateRebuilder.rebuild/1 + the
  # public normalize_slice_view/1 (the snapshot stores the two-container
  # Lifecycle slice; normalize flattens it exactly as get_slice/2 does).
  # Returns `%{}` if neither path yields a slice.
  defp surface_slice(%URI{} = session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :surface) do
      {:ok, surface} when is_map(surface) ->
        surface

      _ ->
        case Ezagent.Kind.StateRebuilder.rebuild(URI.to_string(session_uri)) do
          {:ok, state, _from} ->
            Ezagent.Kind.normalize_slice_view(Map.get(state, :surface, %{}))

          _ ->
            %{}
        end
    end
  end

  # ----- :read_unfiltered row-policy (sourced from the caller's live caps) ---
  #
  @doc """
  Whether `caller` holds the session's `:read_unfiltered` cap — i.e. may read
  `:internal` messages. Sourced LIVE from the caller's caps, never caller-
  supplied. Public so the LIVE plane can apply the SAME row-policy: the
  `world_live` broadcast handler drops a live `:internal` message for a caller
  without this cap (the row-policy the historical read already enforces).
  """
  @spec read_unfiltered?(URI.t() | term(), URI.t()) :: boolean()
  def read_unfiltered?(caller, %URI{} = session_uri) do
    workspace_uri = Ezagent.Capability.workspace_of(session_uri)

    caller
    |> Ezagent.EntityCaps.load()
    |> Enum.any?(&read_unfiltered_cap?(&1, session_uri, workspace_uri))
  rescue
    _ -> false
  end

  defp read_unfiltered_cap?(
         %Ezagent.Capability{} = cap,
         %URI{} = session_uri,
         %URI{} = workspace_uri
       ) do
    cap_field?(cap.kind, :session) and
      cap_field?(cap.behavior, Ezagent.ActionSet.Session) and
      cap_field?(Map.get(cap, :action, :any), :read_unfiltered) and
      cap_instance?(cap.instance, session_uri, workspace_uri) and
      cap_workspace?(cap.workspace_uri, workspace_uri)
  end

  defp read_unfiltered_cap?(_, _, _), do: false

  defp cap_field?(:any, _needed), do: true
  defp cap_field?(same, same), do: true
  defp cap_field?(_, _), do: false

  defp cap_instance?(:any, _session_uri, _workspace_uri), do: true

  defp cap_instance?({:within_session, %URI{} = held}, %URI{} = session_uri, _workspace_uri),
    do: same_uri?(held, session_uri)

  defp cap_instance?({:within_workspace, %URI{} = held}, _session_uri, %URI{} = workspace_uri),
    do: same_uri?(held, workspace_uri)

  defp cap_instance?(%URI{} = held, %URI{} = session_uri, _workspace_uri),
    do: same_uri?(held, session_uri)

  defp cap_instance?(_, _, _), do: false

  defp cap_workspace?(:any, _workspace_uri), do: true
  defp cap_workspace?(%URI{} = held, %URI{} = workspace_uri), do: same_uri?(held, workspace_uri)
  defp cap_workspace?(_, _), do: false

  defp same_uri?(%URI{} = left, %URI{} = right), do: URI.to_string(left) == URI.to_string(right)
  defp same_uri?(_, _), do: false
end
