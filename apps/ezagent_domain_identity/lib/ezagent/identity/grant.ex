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

  `prepare/4` derives the dispatch context from a single closed tagged value.
  Grant routes through `Ezagent.Cap.issue/3`; revoke transports the already
  signed artifact without re-stamping or re-signing it.
  Each tag fixes BOTH which caps load into `ctx.caps` (the authorizer) AND the
  derived `granted_by` (always a real entity):

  | tag | `ctx.caps` (authorizer) | `ctx.caller` | derived `granted_by` |
  |-----|-------------------------|--------------|----------------------|
  | `{:held_by, actor}` | the actor's real cap slice | `actor` | `actor` |
  | `{:admin, admin}` | the admin's real cap slice | `admin` | `admin` |

  `{:held_by, actor}` subsumes self (actor == target owner), admin
  (actor holds admin caps), and #811 manager-delegation (actor holds a
  Manage cap over the target) — all decided by `ctx.caps` exactly as
  before. Bootstrap authority is represented only by the sealed per-Kind
  admin anchor; there is no caller-selectable genesis authorization tag.

  `granted_by` is **derived from the tag** — never a parameter the
  caller can set to itself. `Ezagent.Cap` EXPLICITLY OVERWRITES the
  cap's `granted_by` (a struct update — NOT via `normalize!/2`, which
  returns a `%Capability{}` unchanged and would leave a pre-existing
  non-entity `granted_by` in place) and then VALIDATES it is
  `%URI{scheme: "entity"}`, else `{:error, {:granter_not_entity, uri}}`
  (the runtime #154 guard; fail-closed).

  ## Error policy (SPEC §3.1)

  The imperative wrappers (`grant_cap/3`, `grant_cap_via_router/4`,
  `revoke_cap/3`) RETURN `prepare/4`'s `{:error, _}`. The
  effect-constructor wrappers (`grant_cap_effect/3`,
  `grant_cap_returning_effect/4`, `revoke_cap_returning_effect/4`)
  RAISE on a `prepare/4` error — an effect site cannot return an
  `{:error}` tuple as an effect, and a non-entity granter on a
  authorization tag is a compile-fixed programmer error
  (fail-fast, let-it-crash).
  """

  alias Ezagent.{Cap, Capability, Cmd, Invocation, Router}

  @type authorization ::
          {:held_by, URI.t()}
          | {:admin, URI.t()}

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
  Issue and return a signed capability artifact without storing it.

  This is the reviewed-code handoff for framework-owned principals that must
  carry an inline capability immediately (for example, an internal worker
  subscribing during activation). Issuance still runs through the target
  Kind's cap-gated `K.grant`; this function adds no signer or key access.
  """
  @spec issue_cap(URI.t(), Capability.t(), authorization()) ::
          {:ok, Capability.t()} | {:error, term()}
  def issue_cap(%URI{} = grantee, %Capability{} = cap, authorization) do
    case prepare(grantee, cap, authorization, :grant_cap) do
      {:ok, {_target_uri, issued, _storage_ctx}} -> {:ok, issued}
      {:error, _reason} = error -> error
    end
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
  def grant_cap_via_router(
        %URI{} = target,
        %Capability{} = cap,
        authorization,
        reply_mode \\ :async
      ) do
    case prepare(target, cap, authorization, :grant_cap) do
      {:ok, {target_uri, cap2, ctx}} ->
        cmd = %Cmd{
          target: target_uri,
          action: :store_cap,
          args: %{cap: cap2},
          ctx: Map.put(ctx, :reply, reply_for(reply_mode)),
          origin: :trusted_internal
        }

        normalize_dispatch_result(Router.dispatch(cmd))

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Revoke `cap` from `target` via `Ezagent.Router.dispatch/1` (a `%Cmd{}`) — the
  router twin of `grant_cap_via_router/4`. `reply_mode` is `:async` (buffered
  `:ignore`) or `:sync` (`{:caller_inbox, self()}`); default `:async`.

  The `:async` form is REQUIRED for a revoke issued from INSIDE a Kind callback
  (e.g. the at-join member-cap compensation in `handle_join`): a session-instance
  cap's grant/revoke resolves the instance's data-owner, which re-enters the
  session Kind — a `:sync` call from within that same blocked Kind self-deadlocks.
  The cast is persisted in the capability delivery outbox before dispatch and
  retried until the grantee handler applies it. The call remains asynchronous;
  there is no wait for the outbox row to become applied. Returns `:ok` or
  `{:error, reason}`.
  """
  @spec revoke_cap_via_router(URI.t(), Capability.t(), authorization(), :async | :sync) ::
          :ok | {:error, term()}
  def revoke_cap_via_router(
        %URI{} = target,
        %Capability{} = cap,
        authorization,
        reply_mode \\ :async
      ) do
    case prepare(target, cap, authorization, :revoke_cap) do
      {:ok, {target_uri, cap2, ctx}} ->
        cmd = %Cmd{
          target: target_uri,
          action: :remove_cap,
          args: %{cap: cap2},
          ctx: Map.put(ctx, :reply, reply_for(reply_mode)),
          origin: :trusted_internal
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

  # ── CORE: prepare/4 — dispatch adapter over the Cap provenance seam ───

  # Derives ctx.caps + ctx.caller from the tag. Grant routes through
  # Cap.issue/3; revoke preserves the already-issued artifact without invoking
  # grant authorization or creating a second signing path.
  # Returns the canonical {target_with_action, cap', ctx'} or {:error, _}.
  @spec prepare(URI.t(), Capability.t(), authorization(), grant_action()) ::
          {:ok, {URI.t(), Capability.t(), map()}} | {:error, term()}
  defp prepare(%URI{} = target, %Capability{} = cap, authorization, action)
       when action in [:grant_cap, :revoke_cap] do
    artifact_result =
      case action do
        :grant_cap -> Cap.issue(authorization, target, cap)
        :revoke_cap -> {:ok, cap}
      end

    case artifact_result do
      {:ok, cap2} ->
        ctx = storage_ctx(action)

        target_uri = Ezagent.URI.with_action(target, :identity, storage_action(action))
        {:ok, {target_uri, cap2, ctx}}

      {:error, _} = error ->
        error
    end
  end

  # ── shared envelope helpers ───────────────────────────────────────────

  defp imperative_invocation(target, cap, authorization, action) do
    case prepare(target, cap, authorization, action) do
      {:ok, {target_uri, cap2, ctx}} ->
        inv = %Invocation{
          target: target_uri,
          mode: :call,
          args: %{cap: cap2},
          ctx: Map.put(ctx, :reply, {:caller_inbox, self()}),
          origin: :trusted_internal
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
          action: storage_action(action),
          args: %{cap: cap2},
          ctx: Map.put(ctx, :reply, reply_for(reply_mode)),
          origin: :trusted_internal
        }

      {:error, reason} ->
        raise ArgumentError,
              "Ezagent.Identity.Grant: cannot build #{action} effect — #{inspect(reason)}. " <>
                "An effect site cannot carry an {:error} tuple; invalid authority is a " <>
                "programmer error (Decision #154)."
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
  defp storage_ctx(:grant_cap),
    do: %{
      caller: :vm_internal,
      caps: MapSet.new(),
      cap_delivery_producer: :identity_grant
    }

  defp storage_ctx(:revoke_cap),
    do: %{caller: :vm_internal, caps: MapSet.new(), cap_delivery_producer: :identity_revoke}

  defp storage_action(:grant_cap), do: :store_cap
  defp storage_action(:revoke_cap), do: :remove_cap

  defp reply_for(:sync), do: {:caller_inbox, self()}
  defp reply_for(:async), do: :ignore

  defp normalize_dispatch_result({:ok, _} = ok), do: normalize_to_ok(ok)
  defp normalize_dispatch_result(:ok), do: :ok
  defp normalize_dispatch_result({:error, _} = err), do: err
  defp normalize_dispatch_result(other), do: {:error, {:unexpected_dispatch_result, other}}

  defp normalize_to_ok({:ok, _}), do: :ok
end
