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

  `authorize/4` takes the RAW `:chat` slice map (as `Ezagent.Kind.get_slice/2`
  returns it, or as the Behavior runtime injects under `ctx.siblings[:session]`)
  and an authenticated `holder`. It returns `:ok` ONLY when ALL hold (else
  `{:error, :unauthorized}`):

    1. `holder` is a WELL-FORMED identity-principal `%URI{}` — a canonical
       `entity://<workspace>/<user|agent|worker>/<name>` (reject nil / `:any` /
       `:vm_internal` / non-URI AND a malformed/non-canonical/non-entity `%URI{}`);
    2. `chat` is a present, readable map;
    3. `holder` durably holds the current-generation membership cap over the
       concrete session through `Ezagent.Cap.authorize/3`.

  `owner_uri` and `members` are projection metadata only: neither is consulted
  for authorization. Owners receive the same born-signed tier-1 membership cap
  at creation and therefore traverse the same generation-aware gate as every
  other member. A missing session context fails closed.
  """

  @typedoc "The raw `:chat` slice map (owner_uri + members keyed by URI)."
  @type chat_slice :: %{optional(:owner_uri) => URI.t() | nil, optional(:members) => map()}

  @doc """
  Authorize the authenticated `holder` to read `chat`. The durably-held
  current-generation member cap is the sole enabling truth; the roster and
  structural owner fields are never authority. This denies a revoked member
  immediately even if a stale projection lingers, and admits a newly granted
  member before its projection has converged.
  """
  @spec authorize(chat_slice() | term(), term(), URI.t() | nil, URI.t() | term()) ::
          :ok | {:error, :unauthorized}
  def authorize(chat, _caller, session_uri, holder) do
    with %URI{} = holder <- holder,
         true <- valid_caller_uri?(holder),
         %{} <- chat,
         true <- holds_member_cap?(holder, session_uri) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp holds_member_cap?(_caller, nil), do: false

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

  # Structural owner metadata remains available to projection/delivery callers,
  # but authorize/4 deliberately does not use it.
  @doc false
  def owner?(%{owner_uri: %URI{} = owner}, %URI{} = caller), do: owner == caller
  def owner?(_chat, _caller), do: false

  # The `:chat` slice keys `members` by the member's `%URI{}`.
  @doc false
  def member?(%{members: members}, %URI{} = caller) when is_map(members),
    do: Map.has_key?(members, caller)

  def member?(_chat, _caller), do: false
end
