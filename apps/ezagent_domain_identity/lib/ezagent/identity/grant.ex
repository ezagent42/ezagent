defmodule Ezagent.Identity.Grant do
  @moduledoc """
  The single chokepoint every capability grant/revoke dispatch routes
  through — GLOSSARY Decision #154 ("no unowned permissions").

  ## The three roles a grant conflates

  A capability grant has THREE distinct roles the pre-chokepoint code
  blurred (SPEC `docs/superpowers/specs/2026-06-17-unified-grant-chokepoint.md`
  §1):

  - **caller** — the code path invoking the grant (an HTTP handler, a
    reconciler, an assembly effect — often not a person). `ctx.caller`.
  - **authorizer** — *what makes the grant permitted*. This is
    `ctx.caps` — the cap set the dispatch carries (verified:
    `IdentityAdmin.check_grant_authorized/2` +
    `holds_admin_caps?`/`holds_manage_over_target?`/`require_workspace_admin`
    all read `ctx.caps`; `ctx.caller` is used only for the
    `caller == owner` self-check).
  - **granter** (`granted_by`) — the real accountable ENTITY recorded
    on the cap.

  Pre-chokepoint, every grant-dispatch site independently picked
  `ctx.caps` AND `granted_by`, and several stamped `granted_by` with a
  non-entity `system://…` URI — directly violating Decision #154.

  ## The closed authorization-tag set

  `prepare/4` derives ALL THREE roles from a single closed tagged
  value. Each tag fixes BOTH which caps load into `ctx.caps` (the
  authorizer) AND the derived `granted_by` (always a real entity):

  | tag | `ctx.caps` (authorizer) | `ctx.caller` | derived `granted_by` |
  |-----|-------------------------|--------------|----------------------|
  | `{:held_by, actor}` | the actor's real cap slice | `actor` | `actor` |
  | `{:admin, admin}` | the admin's real cap slice | `admin` | `admin` |
  | `{:rule, name, configurer}` | `[]` + `ctx.authorization_rule = name` | `configurer` | `configurer` |
  | `{:system, principal, granted_by}` *(transitional)* | `SystemPrincipal.caps(principal)` | `granted_by` | `granted_by` (MUST be entity) |

  > NOTE (deviation from SPEC §2 table): for `{:system, …}` the `ctx.caller`
  > is the ENTITY `granted_by`, NOT the principal. `ctx.caps` carries the
  > principal's authority (satisfying dispatch step 5.5, which the entity
  > caller lacks), while `ctx.caller` stays the accountable entity so the
  > handler's `caller == owner` self-check still authorizes a
  > concrete-data_owner grant (the original sites split on caller; the
  > self-check is load-bearing). See `derive/1`.

  `{:held_by, actor}` subsumes self (actor == target owner), admin
  (actor holds admin caps), and #811 manager-delegation (actor holds a
  Manage cap over the target) — all decided by `ctx.caps` exactly as
  before. `{:system, …}` is the **transitional** tag: it preserves
  today's system-principal *authorization* while forcing `granted_by`
  to a real entity, so PR-1 fixes the #154 granter violations
  everywhere without changing authorization semantics. PR-2/PR-3
  convert `{:system, …}` calls to `{:rule, …}` / `{:held_by, …}` and
  the principal then leaves the Catalog.

  `granted_by` is **derived from the tag** — never a parameter the
  caller can set to itself. The chokepoint EXPLICITLY OVERWRITES the
  cap's `granted_by` (a struct update — NOT via `normalize!/2`, which
  returns a `%Capability{}` unchanged and would leave a pre-existing
  system-principal `granted_by` in place) and then VALIDATES it is
  `%URI{scheme: "entity"}`, else `{:error, {:granter_not_entity, uri}}`
  (the runtime #154 guard; fail-closed).

  ## Error policy (SPEC §3.1)

  The imperative wrappers (`grant_cap/3`, `grant_cap_via_router/4`,
  `revoke_cap/3`) RETURN `prepare/4`'s `{:error, _}`. The
  effect-constructor wrappers (`grant_cap_effect/3`,
  `grant_cap_returning_effect/4`, `revoke_cap_returning_effect/4`)
  RAISE on a `prepare/4` error — an effect site cannot return an
  `{:error}` tuple as an effect, and a non-entity granter on a
  `{:system, p, entity}` tag is a compile-fixed programmer error
  (fail-fast, let-it-crash).
  """

  alias Ezagent.{Capability, Cmd, Invocation, Router}

  @type authorization ::
          {:held_by, URI.t()}
          | {:admin, URI.t()}
          | {:rule, atom(), URI.t()}
          | {:system, URI.t(), URI.t()}

  @type grant_action :: :grant_cap | :revoke_cap

  # ── imperative wrappers (build envelope + send) ───────────────────────

  @doc """
  Grant `cap` to `target` via `Ezagent.Invocation.dispatch/1` (`:call`
  mode). The `authorization` tag derives `ctx.caps` + `ctx.caller` +
  the entity `granted_by` (see moduledoc). Returns `:ok` or
  `{:error, reason}` (including `prepare/4`'s `{:granter_not_entity, _}`).
  """
  @spec grant_cap(URI.t(), Capability.t(), authorization()) :: :ok | {:error, term()}
  def grant_cap(%URI{} = target, %Capability{} = cap, authorization) do
    imperative_invocation(target, cap, authorization, :grant_cap)
  end

  @doc """
  Revoke `cap` from `target` via `Ezagent.Invocation.dispatch/1`
  (`:call` mode). Symmetric to `grant_cap/3`. Returns `:ok` or
  `{:error, reason}`.
  """
  @spec revoke_cap(URI.t(), Capability.t(), authorization()) :: :ok | {:error, term()}
  def revoke_cap(%URI{} = target, %Capability{} = cap, authorization) do
    imperative_invocation(target, cap, authorization, :revoke_cap)
  end

  @doc """
  Grant `cap` to `target` via `Ezagent.Router.dispatch/1` (a `%Cmd{}`,
  `:call` mode). For sites that already speak the Router `%Cmd{}`
  envelope. `reply_mode` is `:async` (buffered `:ignore`) or `:sync`
  (`{:caller_inbox, self()}`); default `:async`. Returns `:ok` or
  `{:error, reason}`.
  """
  @spec grant_cap_via_router(URI.t(), Capability.t(), authorization(), :async | :sync) ::
          :ok | {:error, term()}
  def grant_cap_via_router(%URI{} = target, %Capability{} = cap, authorization, reply_mode \\ :async) do
    case prepare(target, cap, authorization, :grant_cap) do
      {:ok, {target_uri, cap2, ctx}} ->
        cmd = %Cmd{
          target: target_uri,
          action: :grant_cap,
          args: %{cap: cap2},
          ctx: Map.put(ctx, :reply, reply_for(reply_mode))
        }

        normalize_dispatch_result(Router.dispatch(cmd))

      {:error, _} = err ->
        err
    end
  end

  # ── effect-constructor wrappers (return effect tuples; RAISE on prepare error) ──

  @doc """
  Build a `{:dispatch, %Cmd{}}` effect that grants `cap` to `target`.
  For Behavior handlers returning effects. RAISES on a `prepare/4`
  error (an effect site cannot carry an `{:error}` tuple — fail-fast).
  """
  @spec grant_cap_effect(URI.t(), Capability.t(), authorization()) ::
          {:dispatch, Cmd.t()}
  def grant_cap_effect(%URI{} = target, %Capability{} = cap, authorization) do
    {:dispatch, cmd!(target, cap, authorization, :grant_cap, :async)}
  end

  @doc """
  Build a `{:dispatch_returning, %Cmd{}, bind_as: bind_as}` effect that
  grants `cap` to `target` (synchronous, failure-propagating). RAISES
  on a `prepare/4` error.
  """
  @spec grant_cap_returning_effect(URI.t(), Capability.t(), authorization(), atom()) ::
          {:dispatch_returning, Cmd.t(), keyword()}
  def grant_cap_returning_effect(%URI{} = target, %Capability{} = cap, authorization, bind_as)
      when is_atom(bind_as) do
    {:dispatch_returning, cmd!(target, cap, authorization, :grant_cap, :sync), bind_as: bind_as}
  end

  @doc """
  Build a `{:dispatch_returning, %Cmd{}, bind_as: bind_as}` effect that
  REVOKES `cap` from `target` (the security-revoke twin — synchronous,
  failure-propagating). RAISES on a `prepare/4` error.
  """
  @spec revoke_cap_returning_effect(URI.t(), Capability.t(), authorization(), atom()) ::
          {:dispatch_returning, Cmd.t(), keyword()}
  def revoke_cap_returning_effect(%URI{} = target, %Capability{} = cap, authorization, bind_as)
      when is_atom(bind_as) do
    {:dispatch_returning, cmd!(target, cap, authorization, :revoke_cap, :sync), bind_as: bind_as}
  end

  # ── CORE: prepare/4 — the ONLY place granted_by is derived ────────────

  # Derives ctx.caps + ctx.caller + granted_by + authorization_rule from
  # the tag, OVERWRITES the cap's granted_by (struct update — NOT
  # normalize!/2), and VALIDATES the derived granted_by is an entity URI.
  # Returns the canonical {target_with_action, cap', ctx'} or {:error, _}.
  @spec prepare(URI.t(), Capability.t(), authorization(), grant_action()) ::
          {:ok, {URI.t(), Capability.t(), map()}} | {:error, term()}
  defp prepare(%URI{} = target, %Capability{} = cap, authorization, action)
       when action in [:grant_cap, :revoke_cap] do
    {caps, caller, granted_by, rule} = derive(authorization)

    # OVERWRITE the cap's granter (explicit struct update). normalize!/2
    # is NOT used here: for a %Capability{} it is a passthrough that
    # ignores the granter, so a pre-existing system-principal granted_by
    # would survive — exactly the #154 bug.
    cap2 = %{cap | granted_by: granted_by, granted_at: DateTime.utc_now()}

    if match?(%URI{scheme: "entity"}, granted_by) do
      ctx = build_ctx(caps, caller, rule)
      target_uri = Ezagent.URI.with_action(target, :identity, action)
      {:ok, {target_uri, cap2, ctx}}
    else
      {:error, {:granter_not_entity, granted_by}}
    end
  end

  # ── tag → {caps, caller, granted_by, rule} ────────────────────────────

  defp derive({:held_by, %URI{} = actor}) do
    {Ezagent.Identity.read_held_caps(actor), actor, actor, nil}
  end

  defp derive({:admin, %URI{} = admin}) do
    {Ezagent.Identity.read_held_caps(admin), admin, admin, nil}
  end

  defp derive({:rule, name, %URI{} = configurer}) when is_atom(name) do
    {MapSet.new(), configurer, configurer, name}
  end

  defp derive({:system, %URI{} = principal, %URI{} = granted_by}) do
    # ctx.caps = the principal's catalog caps (the AUTHORIZER — satisfies
    # dispatch step 5.5, which needs the IdentityAdmin grant cap the owner
    # does NOT hold). ctx.caller = the ENTITY `granted_by` (NOT the
    # principal) — the handler's `check_grant_authorized` self-check reads
    # `ctx.caller` and rejects `:grant_not_owner` for a concrete-data_owner
    # cap unless caller == owner. This matches what the original sites
    # 6/7/10 ran (`caller: owner_uri` + `caps: template-materialize`) and is
    # safe at the caller=principal sites (their handler authz is caps-based:
    # `Template.data_owner/1` == :any → require_workspace_admin reads caps).
    # DEVIATION from SPEC §2 table (which says caller=principal): the
    # original sites split on caller, and the caller self-check is
    # load-bearing wherever data_owner is concrete. (code-wins-over-spec.)
    {Ezagent.SystemPrincipal.caps(principal), granted_by, granted_by, nil}
  end

  # ── shared envelope helpers ───────────────────────────────────────────

  defp imperative_invocation(target, cap, authorization, action) do
    case prepare(target, cap, authorization, action) do
      {:ok, {target_uri, cap2, ctx}} ->
        inv = %Invocation{
          target: target_uri,
          mode: :call,
          args: %{cap: cap2},
          ctx: Map.put(ctx, :reply, {:caller_inbox, self()})
        }

        normalize_dispatch_result(Invocation.dispatch(inv))

      {:error, _} = err ->
        err
    end
  end

  # Build the %Cmd{} for an effect wrapper — RAISES on prepare error.
  defp cmd!(target, cap, authorization, action, reply_mode) do
    case prepare(target, cap, authorization, action) do
      {:ok, {target_uri, cap2, ctx}} ->
        %Cmd{
          target: target_uri,
          action: action,
          args: %{cap: cap2},
          ctx: Map.put(ctx, :reply, reply_for(reply_mode))
        }

      {:error, reason} ->
        raise ArgumentError,
              "Ezagent.Identity.Grant: cannot build #{action} effect — #{inspect(reason)}. " <>
                "An effect site cannot carry an {:error} tuple; a non-entity granted_by on a " <>
                "{:system, principal, entity} tag is a programmer error (Decision #154)."
    end
  end

  # NB: the ctx deliberately carries NO `:mode` key. The dispatch mode is
  # decided by the envelope: the Invocation imperative path sets
  # `mode: :call` on the `%Invocation{}` struct, while the Router `%Cmd`
  # path lets `Ezagent.Router.derive_mode/1` derive it from `:reply`
  # (`:ignore` → `:cast`; `{:caller_inbox, _}` → `:call`). Forcing
  # `mode: :call` into the ctx would override the Router's `:cast`
  # derivation and DEADLOCK the deliberate fire-and-forget grant at
  # `Session.membership.grant_first_join_owner_cap/2` (site #10).
  defp build_ctx(caps, caller, nil) do
    %{caller: caller, caps: caps}
  end

  defp build_ctx(caps, caller, rule) when is_atom(rule) do
    %{caller: caller, caps: caps, authorization_rule: rule}
  end

  defp reply_for(:sync), do: {:caller_inbox, self()}
  defp reply_for(:async), do: :ignore

  defp normalize_dispatch_result({:ok, _} = ok), do: normalize_to_ok(ok)
  defp normalize_dispatch_result(:ok), do: :ok
  defp normalize_dispatch_result({:error, _} = err), do: err
  defp normalize_dispatch_result(other), do: {:error, {:unexpected_dispatch_result, other}}

  defp normalize_to_ok({:ok, _}), do: :ok
end
