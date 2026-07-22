defmodule Ezagent.ActionSet.SocialwarePublisherRead do
  @moduledoc """
  Socialware publisher READ API — the scoped, fail-closed boundary that lets
  a socialware session's owner/members follow its internal publisher trunk
  WITHOUT the chat-publisher authz widening (codex #711 HIGH / P3-3).

  ## Why a DISTINCT behavior (not `Publisher.SessionImpl`)

  The (former, now-collapsed) socialware session also used `type_name/0 ==
  :session` — the SAME as the chat `Session`. The chat publisher read actions
  (`:snapshot`/`:history`/`:subscribe_from`) are registered as `{Session,
  action} -> Publisher.SessionImpl`. If reads resolved through
  `Publisher.SessionImpl`, a BROAD chat
  `kind: :session, behavior: Publisher.SessionImpl` grant (held by
  chat/Feishu participants) would ALSO authorize reading a socialware
  session's INTERNAL `:turns`/`:surface`/`:config_updates` payloads, re-opening
  the widening; and `Publisher.SessionImpl.data_owner/1` delegates to chat
  `Session.owner/1`, not a socialware owner/member model.

  P5-A / P5-1b — this behavior is the UNIFIED membership-gated read for the
  `:snapshot` + `:history` actions on the now-single `Entity.Session` Kind:
  registered for `Session` in `EzagentDomainInstanceMessage.Application` (this
  module's HOME app, where it was relocated from socialware alongside
  `Ezagent.Session.Membership` — both read ONLY the `:chat`/`:publisher`
  slices, owned here). `Publisher.SessionImpl` remains the SOLE
  owner+materializer of the `:publisher` slice; this behavior is a
  REGISTRY-ONLY dispatch surface (NOT in the Kind's `behaviors/0`) that READS
  that slice — reads route HERE, never to `Publisher.SessionImpl`.

  (The `SocialwarePublisherRead` / `Ezagent.Socialware.*` names are retained;
  a rename to a chat/session-scoped name is out of scope for this step.)

  ## Registry-only — reads but does NOT materialize the `:publisher` slice

  This module declares `state_slice :publisher` to READ the trunk's
  ring/cursor (the SAME slice the trunk owner `Publisher.SessionImpl`
  materializes), but it is NOT in `Entity.Session.behaviors/0`, so it
  never `init_slice`/materializes the slice — exactly ONE behavior per Kind
  (the trunk) owns `:publisher`. The handlers READ the slice via
  `ctx.read.(...)` and return it UNCHANGED (no `{:set, ...}` effects). Same
  registry-only pattern as `Ezagent.ActionSet.IdentityAdmin` /
  `Ezagent.ActionSet.UserDefaultCredentialSource`.

  ## `subscribe_from` is DEFERRED (codex rev5 HIGH — post-leave leak)

  The action set is EXACTLY `[:snapshot, :history]`. A long-lived
  `subscribe_from` subscription stores only a pid/ref and fans future
  events out with NO per-event caller re-check, so a member who
  subscribes-then-LEAVEs would keep receiving internal events. No P3
  consumer needs streaming (the customer SPA adapter reads
  `committed_deliveries_since`; the Feishu mirror uses the ExternalMirror
  slice-change path). `subscribe_from` is added ONLY when a streaming
  consumer exists AND carries a per-fan-out re-check + leave-removal. Its
  ABSENCE makes the streaming leak impossible by construction.

  ## Authorization — cap-EXEMPT + a LIVE in-handler fail-closed check

  The read actions are `cap_exempt_actions` at the generic dispatch layer so
  the handler can apply the session-specific membership predicate. The HANDLER
  is the SOLE authority. It declares `reads_siblings [:session]` and authorizes a read
  ONLY when ALL hold (otherwise `{:error, :unauthorized}`):

    1. `ctx.caller` is a `%URI{}` (reject nil / `:any` / `:vm_internal` /
       non-URI caller — these are NOT identities, and cap-exempt dispatch
       does not vet the caller for us);
    2. the `:chat` sibling slice is present + readable (a map);
    3. the authenticated holder durably holds the current-generation tier-1
       member cap over this session through the unified `authorize/3` gate.

  The structural owner and roster fields are projections, never authorization
  inputs. Because the held cap is re-read LIVE on every call, an ex-member is
  denied immediately even while a stale roster entry remains.
  """

  # lifecycle:state_slice_override
  #
  # Read the publisher TRUNK slice (`:publisher`), which the trunk owner
  # `Publisher.SessionImpl` materializes. The macro would otherwise derive
  # `:socialware_publisher_read` from the module name and read an empty
  # slice. This module does NOT init/materialize `:publisher` (registry-only
  # — not in `behaviors/0`); it only READS the owner's ring/cursor.
  use Ezagent.Lifecycle, state_slice: :publisher

  alias Ezagent.Publisher.Event

  @default_retention 100

  reads_siblings([:session])

  action(:snapshot,
    args: %{},
    returns: %{cursor: :integer},
    caps: [:snapshot],
    modes: [:call],
    description:
      "Read this socialware session's publisher trunk cursor + current state. " <>
        "Cap-exempt at dispatch; authorized by a live in-handler tier-1 member-cap check."
  )

  action(:history,
    args: %{},
    returns: %{},
    caps: [:history],
    modes: [:call],
    description:
      "Read events in the (from, to] cursor window from this socialware session's " <>
        "publisher trunk ring. Cap-exempt; authorized by a live in-handler " <>
        "tier-1 member-cap check."
  )

  # The reads are EXEMPT from the generic dispatch CapBAC layer. The handler
  # below is the SOLE, fail-closed membership authority. MUST equal `actions/0` (the
  # plugin-check invariant asserts `required_caps keys ∪ cap_exempt == actions`).
  @impl Ezagent.ActionSet
  def cap_exempt_actions, do: [:snapshot, :history]

  # `data_owner/1` — grant authority for this behavior's cap subjects.
  #
  # The `action/3` macro auto-emits `cap_subjects/0` (from the `caps:`
  # declarations), so the caps-data-ownership invariant
  # (`Ezagent.Invariants.CapsDataOwnerTest`) requires a `data_owner/1`. But
  # these actions are `cap_exempt_actions` — they do not gate on a cap belonging
  # to this read behavior. The authority is the LIVE in-handler tier-1 session
  # membership check, not a snapshot/history cap whose grant authority
  # `data_owner` could describe.
  #
  # So this declares `:no_owner` for every subject: there is no cap-grant
  # authority to formalize (`default_grants_from_data_owner/2` synthesizes
  # nothing, and the cap is never consulted at dispatch because the actions
  # are exempt). `:no_owner` documents "no grantable authority" — exactly
  # correct here.
  @impl Ezagent.ActionSet
  def data_owner(_), do: :no_owner

  # ----- Handlers (cap-exempt; the live check is the boundary) ----------

  @doc """
  Read the publisher trunk's current cursor + most-recent payload. Authorized
  ONLY for a current owner/member of THIS socialware session (live check).
  """
  def handle_snapshot(_args, ctx) do
    with :ok <- authorize(ctx) do
      cursor = ctx[:read].(:cursor, 0)
      ring = ctx[:read].(:ring, [])

      state =
        case List.last(ring) do
          %Event{payload: payload} -> payload
          _ -> nil
        end

      {:ok, %{cursor: cursor, state: state}, []}
    end
  end

  @doc """
  Read events in the `(from, to]` cursor window from the publisher trunk ring.
  Authorized ONLY for a current owner/member of THIS socialware session.
  """
  def handle_history(args, ctx) do
    with :ok <- authorize(ctx) do
      ring = ctx[:read].(:ring, [])
      from = Map.get(args, :from, :earliest)
      to = Map.get(args, :to, :latest)

      case window(ring, from, to) do
        {:ok, events} -> {:ok, %{events: events}, []}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ----- The fail-closed authorization predicate (THE security boundary) -
  #
  # P4 — the predicate is EXTRACTED into the shared
  # `Ezagent.Session.Membership` so that this behavior's read authz AND
  # the P4 chat_feed external read call ONE predicate (no copy-paste drift on a
  # security boundary). This wrapper extracts the authenticated holder, session
  # URI, and `:chat` sibling slice from the dispatch `ctx`; the unified held-cap
  # logic lives in `Membership.authorize/4`.
  #
  # Authorize ONLY when ALL hold (else `{:error, :unauthorized}`):
  #   - `ctx.caller` is a WELL-FORMED identity-principal `%URI{}` — a canonical
  #     `entity://<workspace>/<user|agent|worker>/<name>` (reject nil / :any /
  #     :vm_internal / non-URI AND a malformed/non-canonical/non-entity `%URI{}`,
  #     codex P3-3 HIGH);
  #   - the `:chat` sibling slice is present + readable (a map);
  #   - the authenticated holder holds the current tier-1 member cap over S.
  # Structural owner/roster equality never authorizes.
  defp authorize(ctx) do
    # A2.3 (R1.1) — pass `ctx.self_uri` (this session S) so the read requires the
    # caller to HOLD the member-cap over S, not merely appear in the roster.
    Ezagent.Session.Membership.authorize(
      get_chat_sibling(ctx),
      Map.get(ctx, :caller),
      Map.get(ctx, :self_uri),
      Map.get(ctx, :authenticated_principal)
    )
  end

  defp get_chat_sibling(ctx) do
    ctx
    |> Map.get(:siblings, %{})
    |> Map.get(:session)
  end

  # ----- Read-only window helper over the trunk ring --------------------
  #
  # Returns events with cursor in `(from, to]`:
  #   - from = :earliest → no lower bound
  #   - from = integer   → cursor > from (exclusive)
  #   - to   = :latest   → no upper bound
  #   - to   = integer   → cursor <= to (inclusive)
  # `{:error, :cursor_out_of_window}` if `from` predates the oldest retained
  # cursor. Mirrors `Publisher.SessionImpl`'s window semantics (read-only).
  defp window(ring, from, to) do
    with :ok <- validate_window(ring, from, to) do
      {:ok, Enum.filter(ring, fn %Event{cursor: c} -> in_window?(c, from, to) end)}
    end
  end

  defp validate_window(_ring, :earliest, _to), do: :ok

  defp validate_window(ring, from, to) when is_integer(from) and from >= 0 do
    cond do
      is_integer(to) and to < from -> {:error, {:invalid_window, from, to}}
      cursor_out_of_window?(ring, from) -> {:error, :cursor_out_of_window}
      true -> :ok
    end
  end

  defp validate_window(_ring, bad, _to), do: {:error, {:invalid_cursor, bad}}

  defp cursor_out_of_window?([], _from), do: false
  defp cursor_out_of_window?([%Event{cursor: oldest} | _], from), do: from < oldest - 1

  defp in_window?(_c, :earliest, :latest), do: true
  defp in_window?(c, :earliest, to) when is_integer(to), do: c <= to
  defp in_window?(c, from, :latest) when is_integer(from), do: c > from

  defp in_window?(c, from, to) when is_integer(from) and is_integer(to),
    do: c > from and c <= to

  # Default trunk retention (documented fallback; matches Publisher.SessionImpl).
  @doc false
  def default_retention, do: @default_retention
end
