defmodule Ezagent.Socialware.ExternalFeed do
  @moduledoc """
  Gated external projection for socialware sessions — the agent-generated
  surface page (`%{messages, page, shell, shell_css}`) plus the durable
  delta-cursor replay over the settlement outbox.

  External routes must use this module rather than raw MessageStore, Publisher,
  or ExternalMirror streams.

  ## Authorization — live membership (not a token), via `SessionReads`

  Every read routes through the `Ezagent.Socialware.SessionReads` chokepoint,
  which authorizes the caller FIRST and only then touches the store: strict
  live membership (the SAME fail-closed owner/member predicate the chat surface
  uses), OR — for the external-feed read plane only — the session's
  `public_view` open policy (`PublicView.web_anon_access?/1`, folded INTO the
  chokepoint in PR-2). Authz is re-checked on every read — so an ex-member (or
  a revoked anon) is denied on the next advisory with no token revocation
  needed. Every public viewer is a minted read-only **anon-User** or a
  signed-in **member** (the ingress is modeled on `ChatFeedController`); there
  is no identity-less token. The 2nd argument of the read functions is the
  caller `%URI{}` principal, exactly like `ChatFeed.snapshot/2`.

  Auth and projection are orthogonal: the chokepoint authorizes and returns the
  raw messages/deliveries/surface; this module then projects
  (`messages/page/shell/shell_css`) — the projection reads nothing from the
  caller.
  """

  alias Ezagent.ActionSet.Surface
  alias Ezagent.Session.ExternalDelivery
  alias Ezagent.Socialware.SessionReads
  alias Ezagent.URI, as: EzURI

  @history_limit 100
  @approved_scan_limit 500

  @doc """
  Thin delegator — the canonical external-delivery topic builder now lives in
  `Ezagent.Session.ExternalDelivery` (instance_message). Kept so existing
  callers of `ExternalFeed.topic/1` do not churn.
  """
  @spec topic(URI.t()) :: String.t()
  def topic(%URI{} = session_uri), do: ExternalDelivery.topic(session_uri)

  @spec snapshot(URI.t(), URI.t() | term()) :: {:ok, map()} | {:error, :unauthorized}
  def snapshot(%URI{} = session_uri, caller) do
    with {:ok, messages} <-
           SessionReads.messages(caller, session_uri, :external_feed, %{limit: @history_limit}),
         {:ok, surface} <- SessionReads.external_surface(caller, session_uri),
         {:ok, version} <- SessionReads.committed_external_surface_version(caller, session_uri) do
      {:ok,
       %{
         messages: messages,
         page: external_page(surface, version),
         shell: external_shell(surface),
         shell_css: external_shell_css(surface)
       }}
    end
  end

  # The AI-authored, server-sanitised HTML site-frame (hybrid architecture).
  # nil when the session has no shell yet → the client falls back to its built-in
  # theme frame.
  defp external_shell(surface) do
    case surface do
      %{shell: s} when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  # The shell's pre-compiled Tailwind CSS (its AI-authored classes are invisible
  # to the build-time scan, so they ship with the shell and are inlined).
  defp external_shell_css(surface) do
    case surface do
      %{shell_css: c} when is_binary(c) and c != "" -> c
      _ -> nil
    end
  end

  @spec history(URI.t(), URI.t() | term()) :: {:ok, map()} | {:error, :unauthorized}
  def history(%URI{} = session_uri, caller) do
    with {:ok, messages} <-
           SessionReads.messages(caller, session_uri, :external_feed, %{limit: @history_limit}) do
      {:ok, %{messages: messages}}
    end
  end

  @doc """
  The FULL collaborative chat (every chat-visible message), not the delivered
  external-visible projection `snapshot/2` returns. The external preview is a
  shared whiteboard: every viewer sees all participants' messages live, and each
  message drives a hello page edit. Gated by the same public-aware read gate as the
  page (the page is already public_view), so it carries no membership leak the
  page itself doesn't. Mirrors `Ezagent.Socialware.ChatFeed`'s message source.
  """
  @spec chat_messages(URI.t(), URI.t() | term()) :: {:ok, [map()]} | {:error, :unauthorized}
  def chat_messages(%URI{} = session_uri, caller) do
    SessionReads.messages(caller, session_uri, :external_chat, %{limit: @history_limit})
  end

  @doc """
  P2.5b — durable, cursor-addressable replay of committed external deliveries.
  Returns committed outbox rows with `committed_seq > cursor` (ascending), each
  `%{cursor, turn_id, message_ids, surface_version}`. `committed_seq` is assigned
  at the commit boundary in commit order, so this never skips a late
  out-of-order commit. The durable source the P3 ExternalAdapter replays from;
  the PubSub `{:external_delivery}` event is only an advisory wake-up.

  Caller-authorizing (PR-2): routes through the `SessionReads` delivery-plane
  chokepoint, so a non-authorized caller gets `{:error, :unauthorized}`.
  """
  @spec committed_deliveries_since(URI.t() | term(), URI.t(), integer()) ::
          {:ok,
           [
             %{
               cursor: integer(),
               turn_id: String.t(),
               message_ids: [String.t()],
               surface_version: integer() | nil
             }
           ]}
          | {:error, :unauthorized}
  def committed_deliveries_since(caller, %URI{} = session_uri, cursor) when is_integer(cursor) do
    SessionReads.external_deliveries_since(caller, session_uri, cursor)
  end

  @doc """
  P3-2 — the LOWER-BOUND cursor join protocol (codex P3 rev1 HIGH-3 + rev2
  HIGH-1). The CALLER's channel subscribes to the `{:external_delivery}` topic
  FIRST (a PubSub subscription is channel-process-bound and stays in the
  channel); this function then performs the source-layer steps that must NOT
  race a concurrent commit:

    1. capture `lower = latest_cursor/2` BEFORE any snapshot content read;
    2. take the gated snapshot content (`snapshot/2`) and let the caller render
       it;
    3. immediately replay `committed_deliveries_since(lower)`.

  Because `lower` is captured BEFORE the content read, any commit landing at or
  after `lower` — including one that lands in the narrow window between the
  content read and the replay (and whose advisory `{:external_delivery}` event
  is lost) — is re-included by the replay. Replay is idempotent by
  `committed_seq` id, so a row may be re-delivered (harmless) but is NEVER
  skipped.

  Returns `{:ok, %{snapshot: %{messages, page}, deliveries: [...], cursor: int}}`
  where `cursor` is the max `committed_seq` actually replayed (or `lower` when
  the replay is empty). `{:error, :unauthorized}` on a non-member (fail closed).

  `opts[:before_replay]` is a 0-arity seam fired AFTER the content read and
  BEFORE the replay — used by the join-race test to inject a commit (and drop
  its advisory) in exactly the window codex flagged. Defaults to a no-op.
  """
  @spec join(URI.t(), URI.t() | term(), keyword()) ::
          {:ok, %{snapshot: map(), deliveries: [map()], cursor: integer()}}
          | {:error, :unauthorized}
  def join(%URI{} = session_uri, caller, opts \\ []) when is_list(opts) do
    # Auth gate + initial content read (fail closed).
    case snapshot(session_uri, caller) do
      {:ok, snapshot0} ->
        # Test-only seam: a commit injected here (advisory dropped) must still be
        # rendered, because the replay below covers the FULL committed backlog.
        run_before_replay(opts[:before_replay])

        # codex P3-2 r3 HIGH-1: replay the FULL committed backlog (since 0), NOT
        # `committed_deliveries_since(latest_cursor)`. For a session with more
        # than `@history_limit` committed deliveries, `latest_cursor` would
        # checkpoint the cursor at the max while the recency-windowed snapshot
        # rendered only the latest 100 — stranding the older committed deliveries
        # (cursor advanced PAST rows never rendered). Replaying from 0 makes
        # `replayed_result/5` AUGMENT the snapshot with every committed delivery's
        # messages before advancing the cursor, so the join cursor only ever
        # checkpoints rows that were actually rendered (no skip), and the render
        # is bounded by the session's total external-visible delivery count.
        case committed_deliveries_since(caller, session_uri, 0) do
          {:ok, deliveries} -> replayed_result(session_uri, caller, snapshot0, deliveries, 0)
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  P3-2 — cursor replay for an ESTABLISHED connection, triggered by every
  advisory `{:external_delivery}` event (or a reconnect). Re-validates the
  caller (fail closed), replays `committed_deliveries_since(cursor)`, and returns
  the refreshed gated snapshot so the caller can push the current
  external-visible view.

  Returns `{:ok, %{snapshot: %{messages, page}, deliveries: [...], cursor: int}}`
  where `cursor` advances ONLY to the max `committed_seq` actually replayed
  (unchanged when the replay is empty — idempotent). `{:error, :unauthorized}`
  on a non-member.
  """
  @spec replay(URI.t(), URI.t() | term(), integer()) ::
          {:ok, %{snapshot: map(), deliveries: [map()], cursor: integer()}}
          | {:error, :unauthorized}
  def replay(%URI{} = session_uri, caller, cursor) when is_integer(cursor) do
    case snapshot(session_uri, caller) do
      {:ok, snapshot0} ->
        case committed_deliveries_since(caller, session_uri, cursor) do
          {:ok, deliveries} -> replayed_result(session_uri, caller, snapshot0, deliveries, cursor)
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  # Build the {:ok, %{snapshot, deliveries, cursor}} result, coupling the cursor
  # to what is ACTUALLY rendered (codex P3-2 r2 HIGH-1 + HIGH-2).
  #
  # Empty replay: nothing new — return the already-read snapshot, cursor unchanged.
  defp replayed_result(_session_uri, _caller, snapshot0, [], base_cursor) do
    {:ok, %{snapshot: snapshot0, deliveries: [], cursor: base_cursor}}
  end

  # Non-empty replay: re-render so the snapshot includes EVERY replayed delivery's
  # external-visible messages, THEN advance the cursor to the max replayed
  # committed_seq. Because the render explicitly includes the delivery messages
  # (even ones outside the recency window — >100-batch / old-inserted_at), the
  # cursor never advances past a row the snapshot does not render (no skip), and
  # every replayed row IS rendered (no infinite re-replay). The re-render
  # RE-AUTHORIZES (via `render_with_deliveries`): if the caller lost membership
  # since the first read, fail closed (`{:error, :unauthorized}`) — do NOT advance
  # the cursor or push stale content.
  defp replayed_result(session_uri, caller, _snapshot0, deliveries, _base_cursor) do
    case render_with_deliveries(session_uri, caller, deliveries) do
      {:ok, snapshot} ->
        cursor = deliveries |> Enum.map(& &1.cursor) |> Enum.max()
        {:ok, %{snapshot: snapshot, deliveries: deliveries, cursor: cursor}}

      {:error, _} = err ->
        err
    end
  end

  # Re-read the gated snapshot (fresh page + a SECOND auth check = fail closed)
  # and augment its message list with the replayed deliveries' external-visible
  # messages that fall outside the recency window, so the rendered view reflects
  # every delivery the cursor will account for.
  defp render_with_deliveries(session_uri, caller, deliveries) do
    case snapshot(session_uri, caller) do
      {:ok, %{messages: base} = fresh} ->
        base_ids = MapSet.new(base, & &1.id)

        delivery_ids =
          deliveries |> Enum.flat_map(& &1.message_ids) |> Enum.uniq()

        extra =
          case SessionReads.messages(caller, session_uri, :external_feed, %{ids: delivery_ids}) do
            {:ok, messages} -> Enum.reject(messages, &MapSet.member?(base_ids, &1.id))
            {:error, _} -> []
          end

        {:ok, %{fresh | messages: base ++ extra}}

      {:error, _} = err ->
        err
    end
  end

  defp run_before_replay(nil), do: :ok
  defp run_before_replay(fun) when is_function(fun, 0), do: fun.()

  @doc """
  P2.5b — the highest committed-delivery cursor for a session (0 if none).
  Caller-authorizing (PR-2): routes through the `SessionReads` delivery-plane
  chokepoint.
  """
  @spec latest_cursor(URI.t() | term(), URI.t()) :: {:ok, integer()} | {:error, :unauthorized}
  def latest_cursor(caller, %URI{} = session_uri) do
    SessionReads.latest_external_delivery_cursor(caller, session_uri)
  end

  @doc """
  Whether `upload_uri` (a `resource://<ws>/uploads/<name>` URI) is an APPROVED
  attachment in `session_uri` — i.e. it appears in the decoded `attachments` of
  some committed, `external_visible` message in that session
  (Resource-unification P2a / OI-1).

  This is the **approved-only gate** for the external feed: a download token is
  minted only when this returns `true`, AND it is re-checked at serve time
  (serve-time re-validation — a revocation lever beyond the token TTL: if an
  reviewer flips the message back to `internal` via
  `MessageStore.mark_visibility/2`, an already-minted token stops working).

  Unlike the internal participation check this is purely visibility-based: a feed
  viewer reads as a read-only member, so "approved for external" is the only
  authority for the bearer download. The message scan routes through the
  `SessionReads` chokepoint (PR-2): a caller with no read authority over the
  session gets `false` (fail closed).
  """
  @spec approved_attachment?(URI.t() | term(), URI.t(), URI.t()) :: boolean()
  def approved_attachment?(caller, %URI{} = session_uri, %URI{scheme: "resource"} = upload_uri) do
    if EzURI.type?(upload_uri, :uploads) do
      case SessionReads.messages(caller, session_uri, :external_feed, %{
             limit: @approved_scan_limit
           }) do
        {:ok, messages} -> Enum.any?(messages, &message_attaches?(&1, upload_uri))
        {:error, _} -> false
      end
    else
      false
    end
  end

  def approved_attachment?(_caller, _session_uri, _upload_uri), do: false

  @doc """
  Mint a signed download token for `upload_uri` ONLY if it is an approved
  attachment in `session_uri` for `caller` (the approved-only gate). Returns
  `{:ok, token}` | `{:error, :not_approved}`.

  **Person-bound (read-plane PR-3):** the mint passes `grantee: caller` to the
  signer, so the minted token is bound to the ONE principal this cap-gated read
  authorized — a leaked/copied token replayed by a non-grantee is rejected at
  serve time. The `mint_fun` is injected so the authorization gate stays
  decoupled from the signer — pass `&Ezagent.Uploads.DownloadToken.mint!/2`.
  """
  @spec mint_approved_token(
          URI.t() | term(),
          URI.t(),
          URI.t(),
          (URI.t(), keyword() -> String.t())
        ) :: {:ok, String.t()} | {:error, :not_approved}
  def mint_approved_token(caller, %URI{} = session_uri, %URI{} = upload_uri, mint_fun)
      when is_function(mint_fun, 2) do
    if approved_attachment?(caller, session_uri, upload_uri) do
      {:ok, mint_fun.(upload_uri, grantee: caller)}
    else
      {:error, :not_approved}
    end
  end

  @doc """
  Resolve an external-feed attachment download to its on-disk path, doing ALL
  feed-side authorization (Resource-unification P2a / OI-1) — the external bearer
  path for viewers reading via a minted anon/member principal:

    1. **session auth** — the strict live owner/member predicate (the SAME one
       the chat surface uses, via `SessionReads.authorized?/2`) proves `caller`
       is a live owner/member of `session_uri`;
    2. **file binding** — `upload_uri` is the URI the signed `DownloadToken` was
       bound to (passed in already-verified by the caller);
    3. **serve-time approved-only re-validation** — `approved_attachment?/3`
       re-confirms the attachment is STILL a committed external-visible item in
       this session (a revocation lever beyond the upload-token TTL);
    4. **resolve** — under the SESSION's workspace (the authenticated subject for
       the feed, derived from the session binding, NOT from the upload URI), via
       the hardened uploads resolver (ws-segment authority + R-2 traversal guard).

  Returns `{:ok, path}` | `{:error, :unauthorized}` (fail closed on any step).
  `resolve_fun` is injected so the socialware domain does not depend on the web
  uploads module — pass `&Ezagent.Uploads.resolve/2`.
  """
  @spec authorized_attachment_path(
          URI.t(),
          URI.t() | term(),
          URI.t(),
          (URI.t(), map() -> {:ok, String.t()} | :none | {:error, term()})
        ) :: {:ok, String.t()} | {:error, :unauthorized}
  def authorized_attachment_path(%URI{} = session_uri, caller, %URI{} = upload_uri, resolve_fun)
      when is_function(resolve_fun, 2) do
    with true <- SessionReads.authorized?(caller, session_uri),
         true <- approved_attachment?(caller, session_uri, upload_uri),
         {:ok, workspace_uri} <- workspace(session_uri),
         {:ok, ws_name} <- EzURI.workspace_name(workspace_uri),
         {:ok, path} <- resolve_fun.(upload_uri, %{workspace: ws_name}) do
      {:ok, path}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp message_attaches?(message, %URI{} = upload_uri) do
    target = EzURI.stable_key(upload_uri)

    message
    |> attachments_of()
    |> Enum.any?(fn att -> attachment_key(att) == target end)
  end

  defp attachments_of(%{body: %{attachments: list}}) when is_list(list), do: list
  defp attachments_of(%{body: %{"attachments" => list}}) when is_list(list), do: list
  defp attachments_of(_), do: []

  defp attachment_key(%URI{} = uri), do: EzURI.stable_key(uri)

  defp attachment_key(s) when is_binary(s) do
    EzURI.stable_key(EzURI.new!(s))
  rescue
    ArgumentError -> nil
  end

  defp attachment_key(_), do: nil

  @doc """
  Strict live membership check (owner/member of the session), decoupled from the
  page READ gate. A `public_view` reader who is NOT a member reads the public
  page (the chokepoint's public-aware read gate) but is `member?/2 == false`, so
  the surface shows the "加入" affordance rather than the "发送" composer.
  """
  @spec member?(URI.t(), URI.t() | term()) :: boolean()
  def member?(%URI{} = session_uri, caller), do: SessionReads.authorized?(caller, session_uri)

  # P2.5a (codex rev4 MEDIUM) — derive the workspace STRUCTURALLY from the
  # session URI (session://<workspace>/<template>/<name>), not the volatile
  # WorkspaceRegistry ETS cache (empty after a restart). Mirrors
  # MessageStore.committed_external_visible/2, which already resolves the
  # workspace via Ezagent.Persistence. Returns a `%URI{}` (parsed from the
  # structural string) to preserve the URI-struct contract
  # `authorized_attachment_path/4` relies on (`EzURI.workspace_name/1` has ONLY
  # `%URI{}` heads).
  defp workspace(session_uri) do
    case Ezagent.Persistence.workspace_uri_for(session_uri) do
      {:ok, workspace_str} -> {:ok, EzURI.new!(workspace_str)}
      {:error, _} -> {:error, :unbound_session}
    end
  end

  # P2.5a — render the external page from the COMMITTED surface version, NOT the
  # live `:surface.approved` pointer. `turn.settle` dispatches `:approve`
  # (advancing the live pointer) BEFORE `:commit_settlement` flips the settlement
  # status, so reading the live pointer leaks an approved-but-uncommitted page.
  # The committed version is the latest committed settlement's
  # `target_surface_version` (mirrors the message gate, which requires
  # status == :committed). The :surface slice retains every version tree, so the
  # committed (possibly older) version is still renderable.
  defp external_page(_surface, nil), do: nil

  defp external_page(surface, version), do: Surface.tree_for_version(surface, version)
end
