defmodule Ezagent.Socialware.SessionReads do
  @moduledoc """
  The single cap-gated read chokepoint for a session's conversation plane
  (messages + members).

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

  Both functions take `caller` FIRST and authorize BEFORE any read. A
  non-member / non-authorized caller gets `{:error, :unauthorized}`
  (fail-closed) — never a degraded / observe read.

    * `messages(caller, session_uri, view \\\\ :conversation, page_opts)` covers
      BOTH the initial recent load AND older/pagination (a single authorized
      door for the whole conversation history), returning the raw
      `[%Message{}]` in store order (descending) so results are byte-identical
      to the pre-consolidation direct-store reads.
    * `members(caller, session_uri)` returns the raw `:session`-slice members
      map (`%{URI => meta}`), the authoritative source the presenters shape.

  ## Live-first authorization (spec §3.2 — reused UNCHANGED)

  Authorization delegates to the shared `Ezagent.Session.Membership.authorize/3`
  predicate — the SAME one the feeds (`ChatFeed` / `ExternalFeed`) and
  `SocialwarePublisherRead` use. It is **live-first**: it reads the live
  `:session` slice and the caller's live caps (`EntityCaps.load/1`), so an
  async at-join member-cap grant that is not yet persisted is still seen —
  a fresh join is NOT falsely denied. Cost is one predicate call **per read**
  (not per row).

  ## Row-policy ownership (spec §3.1 step 2 — moved INTO the chokepoint)

  The `:read_unfiltered` decision (visible-only vs unfiltered rows) is sourced
  HERE from the caller's own live caps (`EntityCaps.load/1`) — it is NEVER a
  caller-supplied flag (that would re-open a caller-selectable bypass). Only a
  caller holding the session's `Ezagent.ActionSet.Session :read_unfiltered` cap
  reads `:internal` messages; everyone else gets the `:external_visible` view.
  This logic used to live in `Ezagent.World.ConversationData`; consolidating it
  here makes it un-bypassable.
  """

  alias Ezagent.MessageStore
  alias Ezagent.Session.Membership

  @typedoc "Fixed view enum — selects a query SHAPE, never widens VISIBILITY."
  @type view :: :conversation

  @typedoc """
  Pagination options. `:limit` bounds the batch; an `:older_than` cursor
  (a `DateTime`) selects the pagination window, its absence the initial
  recency window.
  """
  @type page_opts :: %{
          required(:limit) => pos_integer(),
          optional(:older_than) => DateTime.t()
        }

  @doc """
  Authorized conversation messages for `caller` in `session_uri`.

  Authorizes `caller` (live-first membership/owner predicate) BEFORE reading.
  On success returns `{:ok, [%Message{}]}` in store order (descending); a
  non-member / nil / malformed caller gets `{:error, :unauthorized}`.

  `view` is a fixed enum selecting the query shape (`:conversation` today).
  `page_opts` carries `:limit` and — for pagination — an `:older_than` cursor;
  its absence selects the initial recency window. The `:read_unfiltered`
  row-policy is decided internally from the caller's caps (§ moduledoc), so the
  `:conversation` view routes to `recent_visible_in_session`/`recent_in_session`
  (initial) or `older_visible_than`/`older_than` (pagination) accordingly.
  """
  @spec messages(URI.t() | term(), URI.t(), view(), page_opts()) ::
          {:ok, [Ezagent.Message.t()]} | {:error, :unauthorized}
  def messages(caller, session_uri, view \\ :conversation, page_opts)

  def messages(caller, %URI{} = session_uri, :conversation, page_opts) when is_map(page_opts) do
    with :ok <- authorize(caller, session_uri) do
      {:ok, conversation_read(session_uri, read_unfiltered?(caller, session_uri), page_opts)}
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

  # ----- authorization (live-first, shared predicate) ------------------------

  # The SAME live, fail-closed owner/member predicate the feeds use. Reads the
  # live `:session` slice + the caller's held member-cap (A2.3/R1.1) so an
  # ex-member is denied immediately and a fresh async-granted member is allowed.
  defp authorize(caller, %URI{} = session_uri) do
    Membership.authorize(chat_slice(session_uri), caller, session_uri)
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

  # ----- :read_unfiltered row-policy (sourced from the caller's live caps) ---
  #
  # Moved verbatim from `Ezagent.World.ConversationData` so the row-policy is
  # owned by the chokepoint, not a presenter. Caps are loaded LIVE from the
  # caller (never caller-supplied), so a non-holder cannot obtain `:internal`
  # rows by any flag.
  defp read_unfiltered?(caller, %URI{} = session_uri) do
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
