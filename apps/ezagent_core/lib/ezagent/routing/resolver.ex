defmodule Ezagent.Routing.Resolver do
  @moduledoc """
  Resolver — single source of truth for routing decisions (Phase 4-completion
  PR 9 consolidation).

  Per Decision #41 (additive rules), #97 (cross-session + in-session
  fall-through), and Phase 4-completion §A (no hidden fan-out in
  Behavior code):

  - `resolve/3` takes a Message + current session URI + members list
    and returns the COMPLETE recipient list — `Chat.invoke(:send)`
    must call this and dispatch to whatever it returns, **nothing
    more**. No hardcoded fan-out in Behavior code.
  - All routing logic (mention-based / from-based / always / combinators
    / in-session-member fan-out) is expressible as RoutingRegistry
    rules. The previously-hardcoded in-session fan-out is now a
    `system_default` rule with `receivers: ["$session_members"]` — a
    magic token Resolver expands at resolve time using the `members`
    arg.

  ## Magic receiver tokens

  - `"$session_members"` — expands to the current session's members
    list (excluding the message sender). The unconditional broadcast
    token — an explicit opt-in for broadcast-to-all rules.
  - `"$session_users"` — the `User`-Kind members of the current
    session (`entity://user/...`), each filtered through
    `valid_member?/2`. Drives the per-user notification path: a User
    member always gets `chat.receive` regardless of `@mention`.
  - `"$mentions"` — `message.mentions`, each filtered through
    `valid_member?/2`. The mention-gated routing primitive — only a
    validly-mentioned member (agents in practice) is dispatched to.

  `$session_users` + `$mentions` are the receivers of the
  `system_default` rule (mention-gated agent dispatch — see
  `docs/superpowers/specs/2026-05-22-mention-gated-routing.md`).
  `$session_members` stays a valid token for an explicit broadcast
  rule.

  ## `valid_member?/2` — the trust boundary

  `slice.members` is NOT a trust boundary: `chat.join` accepts any
  live `member_uri` and template instantiation joins configured URIs
  under the genesis admin entity (#154 — the former
  `system://template-materialize` principal is gone), so a
  cross-workspace entity can sit in `slice.members`. The Session
  delivery fan-out mints a `:receive` cap PER RECIPIENT it is handed
  (#154 甲-4 — the former `system://chat-router` admin wildcard is gone),
  so an unvalidated receiver would have a `:receive` cap minted for it
  and the membership filter is the ONLY thing keeping delivery to real
  members — a privilege hole if skipped.

  `valid_member?/2` is the shared predicate guarding BOTH
  `$session_users` and `$mentions`: a candidate URI is a valid
  recipient iff it is a well-formed `entity://`/`session://` URI, its
  workspace segment equals the current session's workspace, AND it is
  a currently-registered member of the session. Anything failing —
  cross-workspace, cross-session, non-member, malformed — is dropped.

  Magic tokens are surface to LV `/admin/routing` editor as
  human-readable "(dynamic: ...)" entries so operators see the full
  effective routing.

  ## Why `members` is passed as arg (not computed via :sys.get_state)

  `Chat.invoke(:send)` has the slice in hand — passing members avoids
  a synchronous call into the Session's mailbox. Resolver stays a
  pure function over (msg, session_uri, members) → recipients.
  """

  alias Ezagent.{Message, RoutingRegistry}
  alias Ezagent.Routing.Matcher

  # NOTE (2026-05-25): SessionRouting was removed from this list; the
  # Feishu chat ↔ session bridge it once held now lives in the
  # ExternalMirror domain (`external_mirror_bindings`, PR-EM-3 #317).
  @default_routing_tables [
    EzagentDomainInstanceMessage.Routing.MentionRouting
  ]

  @doc """
  The primary routing table rules (and legend rule-sets) live in. Single source
  for callers that need to fetch a legend's bound rule-set entry rule via
  `Ezagent.Routing.Legend.entry_rule/2` (team-routing-unification §3.6, PR-6) —
  so they don't hard-code the table name.
  """
  @spec default_routing_table() :: atom()
  def default_routing_table, do: hd(@default_routing_tables)

  @session_members_token "$session_members"
  @session_users_token "$session_users"
  @mentions_token "$mentions"

  @magic_tokens [@session_members_token, @session_users_token, @mentions_token]

  @doc """
  Magic token signaling "expand to current session's members" in a
  rule's receivers list — the unconditional broadcast token. Surface
  in LV / mix CLI for discoverability.
  """
  def session_members_token, do: @session_members_token

  @doc """
  Magic token expanding to the `User`-Kind members of the current
  session, each validated via `valid_member?/2`. Drives the per-user
  notification path in the mention-gated `system_default` rule.
  """
  def session_users_token, do: @session_users_token

  @doc """
  Magic token expanding to `message.mentions`, each validated via
  `valid_member?/2`. The mention-gated routing primitive for agents.
  """
  def mentions_token, do: @mentions_token

  @doc """
  The complete set of recognized magic receiver tokens. Used by the
  routing UI's receiver validator to accept these alongside concrete
  URIs.
  """
  @spec magic_tokens() :: [String.t()]
  def magic_tokens, do: @magic_tokens

  @doc """
  Is `token` one of the recognized magic receiver tokens?
  """
  @spec magic_token?(term()) :: boolean()
  def magic_token?(token), do: token in @magic_tokens

  @doc """
  Resolve recipients for `message` in context of `current_session_uri`
  with the session's `members` list.

  Returns a deduplicated `[URI.t()]` of all recipients (cross-session
  routes + in-session members from magic tokens). Sender is excluded
  in the magic-token expansion to prevent self-receive.

  This is the SINGLE call site Chat.invoke(:send) should use. If you
  find yourself adding "in-session fan-out" or other recipient logic
  inside a Behavior, that's a leak — express it as a routing rule
  instead (or extend the magic token vocabulary here).
  """
  @spec resolve(Message.t(), URI.t(), [URI.t()]) :: [URI.t()]
  def resolve(%Message{} = message, %URI{} = current_session_uri, members)
      when is_list(members) do
    resolve(message, current_session_uri, members, [])
  end

  @doc """
  Phase 6 PR 8: 4-arg form with workspace-scope context.

  `opts`:
    * `:workspace_uri` — current Session's owning workspace URI (or nil
      for sessions not bound to a workspace). Rules with a non-nil
      `workspace_uri` only fire if it matches the context; rules with
      `nil` workspace_uri apply globally.

  Use this from `EzagentDomainInstanceMessage.Behavior.Session.invoke(:send)` when the
  Session knows its workspace binding. Old 3-arg call sites continue
  to work — workspace scoping passes through as nil = global-only
  rules apply.
  """
  @spec resolve(Message.t(), URI.t(), [URI.t()], keyword()) :: [URI.t()]
  def resolve(%Message{} = message, %URI{} = current_session_uri, members, opts)
      when is_list(members) and is_list(opts) do
    resolve_with_ctx(message, current_session_uri, members, opts)
    |> Enum.map(fn {uri, _ctx} -> uri end)
  end

  @doc """
  Like `resolve/4` but returns `[{recipient_uri, ctx}]`, where `ctx` is the
  matched rule's context — `%{rule_id, rule_set, prompt_template_ref}` for
  RuleStore-backed rules, or `nil` for legacy plain-list ETS entries (which
  carry no rule identity).

  team-routing-unification §3.5 (the CRITICAL gap codex flagged): the delivery
  transform (a later PR) must know WHICH rule routed a message to a recipient
  so it can apply that rule's `prompt_template_ref`. `resolve/4` drops `ctx`
  for back-compat with its many existing callers (and now delegates here).

  Dedup keeps the FIRST `ctx` when the same recipient is produced by multiple
  rules (the rule-set / single-receiver model makes that rare; §3.5).
  """
  @spec resolve_with_ctx(Message.t(), URI.t(), [URI.t()], keyword()) ::
          [{URI.t(), map() | nil}]
  def resolve_with_ctx(%Message{} = message, %URI{} = current_session_uri, members, opts)
      when is_list(members) and is_list(opts) do
    workspace_uri = Keyword.get(opts, :workspace_uri) |> uri_to_string()
    role_resolver = Keyword.get(opts, :role_resolver)
    # RF-6: `passive?` is a (URI -> boolean) predicate injected by the domain
    # call site (parallel to `role_resolver`) answering "is this recipient a
    # PASSIVE/non-principal data actor?". The default never-passive predicate is
    # what makes the regression guarantee STRUCTURAL: every existing
    # `resolve/3`/`resolve/4` caller (echo, legend, tests) passes no opt → no URI
    # is passive → byte-identical recipient set. `passive?` lives on the domain
    # (the stored agent attribute) and is kept out of core via this opt seam.
    passive? = Keyword.get(opts, :passive?, fn _uri -> false end)
    current_str = URI.to_string(current_session_uri)
    sender_str = uri_to_string(message.sender)
    matcher_ctx = %{members: Keyword.get(opts, :members_snapshot, %{})}

    Application.get_env(:ezagent_core, :routing_tables, @default_routing_tables)
    |> Enum.flat_map(&query_table_with_ctx(&1, message, workspace_uri, matcher_ctx))
    |> Enum.flat_map(fn {receiver, ctx} ->
      expand_receiver(
        receiver,
        message,
        current_session_uri,
        members,
        workspace_uri,
        role_resolver,
        passive?
      )
      |> Enum.map(&{&1, ctx})
    end)
    # Deterministic tie-break (codex 2026-06-01 MED): when two rules route to
    # the SAME recipient, the lower rule_id (earliest-created rule) wins —
    # stable + deterministic, vs the non-deterministic ETS iteration order.
    # `sort_by` is stable, so `uniq_by` then keeps the lowest-rule_id ctx per
    # recipient. (Also makes `resolve/4`'s recipient order deterministic.)
    |> Enum.sort_by(fn {_uri, ctx} -> ctx_rank(ctx) end)
    |> Enum.uniq_by(fn {uri, _ctx} -> URI.to_string(uri) end)
    # F14 (#98): a message must NEVER route back to its own sender. Sender-exclusion
    # previously lived ONLY in the magic-token expansion ($session_members /
    # $session_users / $mentions); rule-resolved explicit targets (Always→X / from→X
    # / mention→X) bypassed it, so an `Always` rule matched an agent's OWN reply and
    # routed it back to itself → self-loop FLOOD (validation F14: 800→1168+ msgs/s).
    # Excluding the sender at the resolver's FINAL output makes the no-self-route
    # invariant UNIVERSAL across all rule types (still also excludes the session URI).
    |> Enum.reject(fn {uri, _ctx} ->
      s = URI.to_string(uri)
      s == current_str or s == sender_str
    end)
    # RF-6 (the UNIVERSAL passive-actor gate): a PASSIVE/non-principal data actor
    # must NEVER receive chat — via ANY rule type. Dropping it at the resolver's
    # FINAL output (the same chokepoint as the F14 self-loop fix) makes the
    # no-passive-receive invariant universal across `{:uri,_}` / `{:from,_}` /
    # `Always→X` / `{:role,_}` / `$mentions` alike — including the rule shapes
    # that bypass `valid_member?`. The Session delivery fan-out mints a `:receive`
    # cap PER recipient it is handed, so a passive actor surviving to here would
    # leak a principal cap; this reject is the load-bearing gate.
    |> Enum.reject(fn {uri, _ctx} -> passive?.(uri) end)
  end

  # Rank for the duplicate-recipient ctx tie-break (§3.5): lower rule_id wins;
  # nil ctx (legacy plain-list rules, no rule identity) ranks last.
  defp ctx_rank(%{rule_id: id}) when is_integer(id), do: id
  defp ctx_rank(_), do: 1_000_000_000

  # team-routing-unification §3.5: pair each matched rule's receivers with
  # that rule's ctx, so `resolve_with_ctx/4` can thread matched-rule context
  # (rule_id / prompt_template_ref) through to delivery. (Replaces the old
  # receiver-only `query_table/3`; `resolve/4` now maps ctx off.)
  defp query_table_with_ctx(table_name, message, workspace_uri_str, matcher_ctx) do
    case safe_list_all(table_name) do
      [] ->
        []

      rows ->
        sender_str = uri_to_string(message.sender)

        rows
        |> Enum.filter(fn {matcher_tuple, _value} ->
          Matcher.match?(matcher_tuple, message, matcher_ctx)
        end)
        |> Enum.filter(fn {_matcher, value} ->
          applies_to_sender?(value, sender_str)
        end)
        |> Enum.filter(fn {_matcher, value} ->
          applies_to_workspace?(value, workspace_uri_str)
        end)
        |> Enum.flat_map(fn {_matcher, value} ->
          ctx = rule_ctx_of(value)
          Enum.map(receivers_of(value), &{&1, ctx})
        end)
    end
  end

  # Matched-rule context for §3.5 threading. RuleStore-loaded values are maps
  # carrying rule_id/rule_set/prompt_template_ref (added in the rule-set schema
  # PR); legacy plain-list ETS entries (RoutingRegistry.put — tests/hand-coded)
  # carry no rule identity → nil ctx.
  defp rule_ctx_of(value) when is_map(value) do
    %{
      rule_id: Map.get(value, :rule_id),
      rule_set: Map.get(value, :rule_set),
      prompt_template_ref: Map.get(value, :prompt_template_ref)
    }
  end

  defp rule_ctx_of(_), do: nil

  # Phase 6 PR 5: rule value shape is either a plain list (legacy:
  # `[receiver_str, ...]`) or a map with `:receivers` + `:applies_to_users`.
  # Plain list path is for ETS entries written directly via
  # `RoutingRegistry.put` (tests, hand-coded callers) — they have no
  # user filter so always apply.
  defp receivers_of(receivers) when is_list(receivers), do: receivers
  defp receivers_of(%{receivers: receivers}), do: receivers

  defp applies_to_sender?(value, _sender) when is_list(value), do: true
  defp applies_to_sender?(%{applies_to_users: []}, _sender), do: true

  defp applies_to_sender?(%{applies_to_users: users}, sender_str)
       when is_list(users),
       do: sender_str in users

  defp applies_to_sender?(_value, _sender), do: true

  # Phase 6 PR 8 — workspace scope filter.
  # nil context = no workspace binding → only nil-scoped rules apply.
  # non-nil context = rule applies if its workspace_uri is nil (global)
  # OR matches the context exactly.
  defp applies_to_workspace?(value, _ctx) when is_list(value), do: true
  defp applies_to_workspace?(%{workspace_uri: nil}, _ctx), do: true
  defp applies_to_workspace?(%{workspace_uri: same}, same), do: true
  defp applies_to_workspace?(%{workspace_uri: _}, _other), do: false
  defp applies_to_workspace?(_value, _ctx), do: true

  defp uri_to_string(nil), do: nil
  defp uri_to_string(%URI{} = u), do: URI.to_string(u)
  defp uri_to_string(s) when is_binary(s), do: s

  defp safe_list_all(table_name) do
    try do
      RoutingRegistry.list_all(table_name)
    rescue
      ArgumentError -> []
    end
  end

  # Expand magic tokens. Receivers are stored as binaries in RuleStore;
  # the magic tokens expand via the `members` arg + the session URI.

  # "$session_members" — the unconditional broadcast token. Every
  # member except the sender. No trust-boundary filter — this is the
  # explicit opt-in broadcast token; an operator who adds a rule
  # resolving to it is consciously asking for full fan-out.
  defp expand_receiver(
         @session_members_token,
         message,
         _current_session_uri,
         members,
         _ws,
         _role_resolver,
         _passive?
       ) do
    sender_str = sender_string(message)

    members
    |> Enum.reject(fn m -> URI.to_string(m) == sender_str end)
  end

  # "$session_users" — the User-Kind members (entity://user/...) of
  # the current session, each through the valid_member?/2 trust
  # boundary, excluding the sender. Drives the per-user notification.
  defp expand_receiver(
         @session_users_token,
         message,
         current_session_uri,
         members,
         _ws,
         _role_resolver,
         _passive?
       ) do
    sender_str = sender_string(message)

    members
    |> Enum.filter(&user_uri?/1)
    |> Enum.filter(&valid_member?(&1, current_session_uri, members))
    |> Enum.reject(fn m -> URI.to_string(m) == sender_str end)
  end

  # "$mentions" — message.mentions, each through the valid_member?/2
  # trust boundary, excluding the sender. The mention-gated routing
  # primitive. message.mentions is user-controlled (raw compose text /
  # global registry scan) and the Session delivery fan-out mints a
  # `:receive` cap PER RECIPIENT it is handed (#154 甲-4 — the former
  # `system://chat-router` admin wildcard is gone), so unvalidated
  # mentions would be a privilege hole — the membership filter is what
  # bounds the minted cap to real members.
  #
  # RF-6 gate (mention): a PASSIVE/non-principal data actor is not a valid
  # @-mention TARGET — even if it were somehow a session member, a passive actor
  # must not be addressable by chat. Rejecting it here (in addition to the
  # universal final-output gate) keeps the mention-resolver itself honest:
  # `$mentions` never yields a passive URI, so no `:receive` cap is even
  # considered for one via the mention path.
  defp expand_receiver(
         @mentions_token,
         message,
         current_session_uri,
         members,
         _ws,
         _role_resolver,
         passive?
       ) do
    sender_str = sender_string(message)

    (message.mentions || [])
    |> Enum.map(&to_uri/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&valid_member?(&1, current_session_uri, members))
    |> Enum.reject(fn m -> URI.to_string(m) == sender_str end)
    |> Enum.reject(fn m -> passive?.(m) end)
  end

  defp expand_receiver({:magic, token}, message, current, members, ws, role_resolver, passive?)
       when is_binary(token) do
    expand_receiver(token, message, current, members, ws, role_resolver, passive?)
  end

  defp expand_receiver(
         {:uri, %URI{} = receiver},
         _message,
         _current,
         _members,
         _ws,
         _role_resolver,
         _passive?
       ),
       do: [receiver]

  defp expand_receiver(
         {:uri, receiver},
         _message,
         _current,
         _members,
         _ws,
         _role_resolver,
         _passive?
       )
       when is_binary(receiver),
       do: [Ezagent.URI.new!(receiver)]

  defp expand_receiver(
         {:role, role_name},
         message,
         current,
         members,
         ws,
         role_resolver,
         _passive?
       )
       when is_binary(role_name) and is_function(role_resolver, 2) do
    case role_resolver.(role_name, %{
           message: message,
           session_uri: current,
           members: members,
           workspace_uri: ws
         }) do
      %URI{} = uri -> [uri]
      {:ok, %URI{} = uri} -> [uri]
      uris when is_list(uris) -> Enum.filter(uris, &match?(%URI{}, &1))
      {:ok, uris} when is_list(uris) -> Enum.filter(uris, &match?(%URI{}, &1))
      nil -> []
      :error -> []
      {:error, _} -> []
      _ -> []
    end
  end

  defp expand_receiver(
         {:role, _role_name},
         _message,
         _current,
         _members,
         _ws,
         _role_resolver,
         _passive?
       ),
       do: []

  defp expand_receiver(receiver, _message, _current, _members, _ws, _role_resolver, _passive?)
       when is_binary(receiver),
       do: [Ezagent.URI.new!(receiver)]

  defp expand_receiver(
         %URI{} = receiver,
         _message,
         _current,
         _members,
         _ws,
         _role_resolver,
         _passive?
       ),
       do: [receiver]

  @doc """
  The shared trust boundary for `$session_users` + `$mentions`.

  A candidate receiver URI is a valid recipient iff ALL of:

    1. It is a well-formed, canonical `entity://` or `session://` URI
       — it parses cleanly through the STRICT `Ezagent.URI.new!/1`
       validator (SPEC-v3 3-segment authority, reserved sub-resource
       positions rejected) AND its canonical string round-trip equals
       the input. This is applied IDENTICALLY whether the candidate
       arrived as a binary or as a pre-built `%URI{}` struct — the
       real mention sources build `%URI{}` via `URI.new/URI.new!`
       (NOT `Ezagent.URI.new!`), so a hand-built struct carrying an
       extra path segment (`entity://user/team-alpha/bob/extra`) would
       otherwise bypass the shape rule. `current_session_uri` is
       held to the same strict standard.
    2. It is NOT a cross-session URI — a `session://` candidate
       naming a session OTHER than the current one is dropped (these
       tokens deliver into THIS session; routing to a peer session
       is an explicit-rule concern, not a default-token concern).
    3. Its workspace segment equals the current session's workspace
       (derived structurally from `current_session_uri` — session
       URIs are 3-segment, the workspace is in the path).
    4. It is a currently-registered member of the session — i.e. it
       appears in `members` (the Session's `slice.members` keys).

  Anything failing — cross-workspace, cross-session, non-member,
  malformed, non-canonical, wrong shape — returns `false` and is
  dropped. This is the security boundary: the Session delivery fan-out
  mints a `:receive` cap PER RECIPIENT it is handed (#154 甲-4 — the
  former `system://chat-router` admin wildcard is gone), so an
  unvalidated receiver would be a privilege hole (a cross-workspace
  entity placed in `slice.members` via programmatic `chat.join` /
  template instantiation must receive NOTHING — the membership filter
  is the only thing bounding the minted cap to real members).

  Never raises — `Ezagent.URI.new!/1` raises on bad input, so the
  canonicalization is wrapped; a malformed candidate is a `false`,
  not a crash.
  """
  @spec valid_member?(URI.t() | String.t(), URI.t(), [URI.t()]) :: boolean()
  def valid_member?(candidate, %URI{} = current_session_uri, members)
      when is_list(members) do
    with %URI{} = uri <- canonicalize(candidate),
         %URI{} = session_uri <- canonicalize(current_session_uri),
         true <- uri.scheme in ["entity", "session"],
         true <- not cross_session?(uri, session_uri),
         %URI{} = candidate_ws <- safe_workspace_of(uri),
         %URI{} = session_ws <- safe_workspace_of(session_uri),
         true <- URI.to_string(candidate_ws) == URI.to_string(session_ws),
         true <- member?(uri, members) do
      true
    else
      _ -> false
    end
  end

  def valid_member?(_candidate, _current_session_uri, _members), do: false

  # Canonicalize ANY candidate (binary OR %URI{}) through the strict
  # `Ezagent.URI.new!/1` validator. The real mention sources build
  # `%URI{}` via `URI.new/URI.new!` — NOT `Ezagent.URI.new!` — so a
  # struct path that skipped strict validation let a crafted member
  # with an extra path segment (`entity://user/team-alpha/bob/extra`)
  # bypass the SPEC-v3 3-segment / reserved-sub-resource rule and
  # become a `chat.receive` target under the system principal. Routing the
  # struct through `URI.to_string/1` then `parse!/1` applies IDENTICAL
  # strict validation to both inputs. `parse!/1` raises on malformed /
  # non-canonical / wrong-shape input — wrapped so this stays total
  # (a parse failure is a `nil`, i.e. "drop").
  defp canonicalize(%URI{} = uri), do: canonicalize(URI.to_string(uri))

  defp canonicalize(s) when is_binary(s) do
    Ezagent.URI.new!(s)
  rescue
    _ -> nil
  end

  defp canonicalize(_), do: nil

  # Membership check — the candidate must appear in the session's
  # member URI list. Compared on canonical string form.
  defp member?(%URI{} = uri, members) do
    uri_str = URI.to_string(uri)
    Enum.any?(members, fn m -> URI.to_string(m) == uri_str end)
  end

  # A `session://` candidate naming a session OTHER than the current
  # one is cross-session — dropped (SPEC §6.4(c)). The current
  # session's own URI is not cross-session (and is excluded as a
  # recipient downstream by resolve/4's self-reject anyway). An
  # `entity://` candidate is never cross-session.
  defp cross_session?(%URI{scheme: "session"} = uri, %URI{} = current_session_uri) do
    URI.to_string(uri) != URI.to_string(current_session_uri)
  end

  defp cross_session?(%URI{}, %URI{}), do: false

  # A User-Kind member is structurally an entity URI whose type axis is `user`.
  defp user_uri?(%URI{} = uri), do: uri.scheme == "entity" and Ezagent.URI.type?(uri, :user)
  defp user_uri?(uri) when is_binary(uri), do: user_uri?(to_uri(uri))
  defp user_uri?(_), do: false

  defp to_uri(%URI{} = uri), do: uri

  defp to_uri(s) when is_binary(s) do
    Ezagent.URI.new!(s)
  rescue
    _ -> nil
  end

  defp to_uri(_), do: nil

  defp safe_workspace_of(%URI{} = uri) do
    case Ezagent.Capability.workspace_of(uri) do
      %URI{} = ws -> ws
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp sender_string(message) do
    case message.sender do
      %URI{} = u -> URI.to_string(u)
      s when is_binary(s) -> s
      _ -> ""
    end
  end
end
