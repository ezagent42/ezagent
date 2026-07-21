defmodule Ezagent.Session.Membership do
  @moduledoc """
  The SHARED, live, fail-closed chat owner/member authorization predicate.

  This is the SINGLE source of truth for "may `caller` read a chat session's
  `:chat` slice?" — extracted from `Ezagent.ActionSet.SocialwarePublisherRead`
  (P3-3) so that BOTH that behavior's read authz AND the P4 chat_feed external
  read (`ChatFeedAdapter` / `ChatFeed`) call ONE predicate. A security boundary
  must not be copy-pasted: extracting it here makes the chat_feed authz
  byte-equivalent to P3-3 by construction (no drift on a re-check that decides
  who may read a conversation).

  ## Shape

  `authorize/2` takes the RAW `:chat` slice map (as `Ezagent.Kind.get_slice/2`
  returns it, or as the Behavior runtime injects under `ctx.siblings[:session]`)
  and a `caller`. It returns `:ok` ONLY when ALL hold (else
  `{:error, :unauthorized}`):

    1. `caller` is a WELL-FORMED identity-principal `%URI{}` — a canonical
       `entity://<workspace>/<user|agent|worker>/<name>` (reject nil / `:any` /
       `:vm_internal` / non-URI AND a malformed/non-canonical/non-entity `%URI{}`);
    2. `chat` is a present, readable map;
    3. EITHER `chat.owner_uri` is a `%URI{}` AND `== caller`,
       OR `caller` is a key of `chat.members` (URIs).

  A nil/missing `owner_uri` matches NOTHING (an OWNERLESS chat is NOT readable
  by a nil/`:any` caller) — there is NO "allow if owner is nil" branch. Because
  membership is re-read LIVE on every call, an ex-member (post-LEAVE) is denied
  immediately, and a chat `kind: :session` cap holder who is NOT a member is
  denied.
  """

  @typedoc "The raw `:chat` slice map (owner_uri + members keyed by URI)."
  @type chat_slice :: %{optional(:owner_uri) => URI.t() | nil, optional(:members) => map()}

  @doc """
  Authorize `caller` to read `chat` — the HELD-CAP form (membership-cap
  unification A2.3 / spec R1.1). Identical to `authorize/2` PLUS: a non-owner
  caller must additionally HOLD the member-cap over `session_uri` (read LIVE via
  `Ezagent.EntityCaps.load/1`, provenance-filtered), so an ex-member
  whose cap was revoked is denied IMMEDIATELY even if a stale roster entry lingers
  (no "in-projection ⇒ authorized" window). `session_uri == nil` skips the held-cap
  check (roster-only, backward-compatible with any caller lacking session context).
  """
  @spec authorize(chat_slice() | term(), term(), URI.t() | nil, URI.t() | term()) ::
          :ok | {:error, :unauthorized}
  def authorize(chat, _caller, session_uri, holder) do
    with %URI{} = holder <- holder,
         true <- valid_caller_uri?(holder),
         %{} = chat <- chat,
         true <- owner?(chat, holder) or member_with_held_cap?(chat, holder, session_uri) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  # A non-owner reader must be in the roster AND HOLD the member-cap over the
  # session (R1.1). The roster is the fast pre-filter; the held cap is the
  # authority — a revoked ex-member with a stale roster entry is denied.
  defp member_with_held_cap?(chat, %URI{} = caller, session_uri) do
    member?(chat, caller) and holds_member_cap?(caller, session_uri)
  end

  # `nil` session → no session context → skip the held-cap check (roster-only,
  # backward-compat). With a concrete session, require the LIVE held member-cap,
  # via the ONE shared held-cap predicate (no drift vs the receive gate, K4
  # provenance-filtered).
  defp holds_member_cap?(_caller, nil), do: true

  defp holds_member_cap?(%URI{} = caller, %URI{} = session_uri) do
    held = Ezagent.EntityCaps.load(caller)
    Ezagent.Session.MemberReceive.holds_member_cap_over?(caller, held, session_uri)
  end

  @doc """
  Whether `caller` is a WELL-FORMED bare identity-principal instance entity URI
  `entity://<workspace>/<user|agent|worker>/<name>` — delegates to the
  centralized `Ezagent.URI.bare_principal?/1` (reconstruct-and-compare against
  the canonical rebuild; any crafted authority/userinfo/port/query/fragment/
  subresource field makes the caller `!=` its rebuild and is rejected, even if
  the same crafted struct is planted as `owner_uri`/`members`).

  The positional URI introspection lives in `Ezagent.URI` (per the UriQuery
  invariant) rather than being inlined here; this stays a thin, named gate so
  the security predicate reads the same as P3-3.
  """
  @spec valid_caller_uri?(term()) :: boolean()
  def valid_caller_uri?(caller), do: Ezagent.URI.bare_principal?(caller)

  # Owner match ONLY when owner_uri is a real %URI{} that equals the caller.
  # A nil/missing owner matches NOTHING.
  @doc false
  def owner?(%{owner_uri: %URI{} = owner}, %URI{} = caller), do: owner == caller
  def owner?(_chat, _caller), do: false

  # The `:chat` slice keys `members` by the member's `%URI{}`.
  @doc false
  def member?(%{members: members}, %URI{} = caller) when is_map(members),
    do: Map.has_key?(members, caller)

  def member?(_chat, _caller), do: false
end
