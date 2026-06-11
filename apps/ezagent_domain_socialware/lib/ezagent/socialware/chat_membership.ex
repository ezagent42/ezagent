defmodule Ezagent.Socialware.ChatMembership do
  @moduledoc """
  The SHARED, live, fail-closed chat owner/member authorization predicate.

  This is the SINGLE source of truth for "may `caller` read a chat session's
  `:chat` slice?" — extracted from `Ezagent.Behavior.SocialwarePublisherRead`
  (P3-3) so that BOTH that behavior's read authz AND the P4 chat_feed external
  read (`ChatFeedAdapter` / `ChatFeed`) call ONE predicate. A security boundary
  must not be copy-pasted: extracting it here makes the chat_feed authz
  byte-equivalent to P3-3 by construction (no drift on a re-check that decides
  who may read a conversation).

  ## Shape

  `authorize/2` takes the RAW `:chat` slice map (as `Ezagent.Kind.get_slice/2`
  returns it, or as the Behavior runtime injects under `ctx.siblings[:chat]`)
  and a `caller`. It returns `:ok` ONLY when ALL hold (else
  `{:error, :unauthorized}`):

    1. `caller` is a WELL-FORMED identity-principal `%URI{}` — a canonical
       `entity://<workspace>/<user|agent|worker>/<name>` (reject nil / `:any` /
       `:system` / non-URI AND a malformed/non-canonical/non-entity `%URI{}`);
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
  Authorize `caller` to read `chat` (an owner or current member of the chat
  session). Fail-closed: `{:error, :unauthorized}` on any unmet condition.
  """
  @spec authorize(chat_slice() | term(), URI.t() | term()) :: :ok | {:error, :unauthorized}
  def authorize(chat, caller) do
    with %URI{} = caller <- caller,
         true <- valid_caller_uri?(caller),
         %{} = chat <- chat,
         true <- owner?(chat, caller) or member?(chat, caller) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  Whether `caller` is a WELL-FORMED bare identity-principal instance entity URI
  `entity://<workspace>/<user|agent|worker>/<name>`.

  Rather than enumerate the fields that must be empty (authority/query/fragment/
  userinfo/port/…), RECONSTRUCT the canonical principal from the caller's
  workspace+type+name via `Ezagent.URI.entity/3` (which `new!`s the canonical
  form — every extraneous field nil) and require EXACT struct equality. Any
  crafted extra field (userinfo, port, query, fragment, subresource path, or a
  non-canonical `:authority`) makes the caller `!=` its canonical rebuild, so it
  is rejected — even if that same crafted struct is planted as
  `owner_uri`/`members`.
  """
  @spec valid_caller_uri?(term()) :: boolean()
  def valid_caller_uri?(%URI{scheme: "entity", host: host, path: path} = caller)
      when is_binary(host) and host != "" and is_binary(path) do
    case String.split(path, "/", trim: false) do
      ["", type, name] when type in ["user", "agent", "worker"] and name != "" ->
        caller == Ezagent.URI.entity(host, type, name)

      _ ->
        false
    end
  rescue
    # `Ezagent.URI.entity/3` raises on a name/segment it cannot canonicalize —
    # such a caller is not a valid principal instance: fail closed.
    _ -> false
  end

  def valid_caller_uri?(_), do: false

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
