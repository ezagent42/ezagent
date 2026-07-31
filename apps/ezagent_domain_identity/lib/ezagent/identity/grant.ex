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

  require Logger

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
  Issue one target-signed artifact, hand it to the grantee's self-store, and
  wait until that exact artifact is observable in the grantee's cap slice.

  Framework producers that need synchronous ISSUE -> SELF-STORE semantics use
  this facade so adapters such as the CLI never construct an absorb envelope.
  """
  @spec issue_and_absorb_cap(URI.t(), Capability.t(), authorization(), timeout()) ::
          :ok | {:error, term()}
  def issue_and_absorb_cap(
        %URI{} = grantee,
        %Capability{} = cap,
        authorization,
        timeout_ms \\ 5_000
      ) do
    with {:ok, artifact} <- issue_cap(grantee, cap, authorization),
         :ok <- Ezagent.Identity.absorb_cap(grantee, artifact),
         :ok <- Ezagent.Identity.CapAbsorbAwait.await_exact(grantee, [artifact], timeout_ms) do
      :ok
    end
  end

  @doc """
  Revoke `cap` from `target` — STORE-FIRST, symmetric to
  `revoke_cap_via_router/4` (② P2(c), codex must-fix #4: EVERY revoke entry
  point routes through the same durable `Ezagent.EntityCaps.revoke_persisted/2`
  core). The durable delete (tombstone + pending-delivery cancel + plane
  deletes) commits FIRST, independent of target liveness; the `:remove_cap`
  `Ezagent.Invocation.dispatch/1` (`:call` mode) is then only the
  live-reconcile hint. Returns:

    * `:ok` — durable delete committed AND the live hint applied;
    * `{:ok, {:hint_failed, reason}}` — the durable delete COMMITTED (the
      revoke IS durable: tombstone recorded, planes deleted, pending
      deliveries cancelled) but the target did not apply the live hint
      (down/restarting). NOT a revoke failure — the target reconciles from
      the store on its next load, and the tombstone fences any stale write
      in between. Callers must NOT treat this as "member fully intact";
    * `{:error, reason}` — the durable delete did NOT commit; the revoke did
      not happen (safe to abort dependent work).
  """
  @spec revoke_cap(URI.t(), Capability.t(), authorization()) ::
          :ok | {:ok, {:hint_failed, term()}} | {:error, term()}
  def revoke_cap(%URI{} = target, %Capability{} = cap, authorization) do
    case prepare(target, cap, authorization, :revoke_cap) do
      {:ok, {target_uri, cap2, ctx}} ->
        with :ok <- Ezagent.EntityCaps.revoke_persisted(target, cap2) do
          inv = %Invocation{
            target: target_uri,
            mode: :call,
            args: %{cap: cap2},
            ctx: Map.put(ctx, :reply, {:caller_inbox, self()}),
            origin: :trusted_internal
          }

          case normalize_dispatch_result(Invocation.dispatch(inv)) do
            :ok -> :ok
            {:error, reason} -> hint_failed(target, reason)
          end
        end

      {:error, _} = err ->
        err
    end
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

  ② P2(b) — DURABILITY: the revoke FIRST deletes the cap from the target's
  authoritative durable store (`Ezagent.EntityCaps.revoke_persisted/2`),
  synchronously and independent of target liveness. That store delete — not
  the dispatch — is what makes the revoke survive the target being down or
  restarting: the generation gate does NOT backstop `remove_cap` (the
  `revoke_generation_gate_repro_test` verdict — ②-Q2 option (a)). The
  `:remove_cap` dispatch is only a "wake up + re-read" hint: a live holder
  drops its in-memory copy and re-persists; a cold/restarted holder
  reconciles from the store on load.

  The durable store delete is a direct store-layer write — NOT a round-trip
  to the target Kind — so the self-deadlock contract is preserved: the
  `:async` form remains REQUIRED for a revoke issued from INSIDE a Kind
  callback (e.g. the at-join member-cap compensation in `handle_join`): a
  session-instance cap's grant/revoke resolves the instance's data-owner,
  which re-enters the session Kind — a `:sync` HINT dispatch from within that
  same blocked Kind self-deadlocks.

  Return contract (② P2(c), codex must-fix #5 — the REMOVE-abort fix):

    * `:ok` — durable delete committed AND the hint applied;
    * `{:ok, {:hint_failed, reason}}` (`:sync` only) — the durable delete
      COMMITTED but the live hint did not apply. This is NOT a "revoke did
      not happen" signal: the caller must NOT claim a full rollback (e.g.
      member REMOVE proceeds with / reconciles the roster removal — the cap
      is durably gone and the tombstone fences stale writers);
    * `:async` — a hint failure is logged and swallowed to `:ok` (the store
      is already correct — the target reconciles on its next load);
    * `{:error, reason}` — the durable delete did NOT commit; the revoke did
      not happen (safe to abort dependent work).
  """
  @spec revoke_cap_via_router(URI.t(), Capability.t(), authorization(), :async | :sync) ::
          :ok | {:ok, {:hint_failed, term()}} | {:error, term()}
  def revoke_cap_via_router(
        %URI{} = target,
        %Capability{} = cap,
        authorization,
        reply_mode \\ :async
      ) do
    case prepare(target, cap, authorization, :revoke_cap) do
      {:ok, {target_uri, cap2, ctx}} ->
        with :ok <- Ezagent.EntityCaps.revoke_persisted(target, cap2) do
          cmd = %Cmd{
            target: target_uri,
            action: :remove_cap,
            args: %{cap: cap2},
            ctx: Map.put(ctx, :reply, reply_for(reply_mode)),
            origin: :trusted_internal
          }

          case normalize_dispatch_result(Router.dispatch(cmd)) do
            :ok ->
              :ok

            {:error, reason} ->
              case reply_mode do
                :sync ->
                  hint_failed(target, reason)

                :async ->
                  Logger.warning(
                    "Ezagent.Identity.Grant.revoke_cap_via_router: durable revoke " <>
                      "committed but the :remove_cap reconcile hint failed for " <>
                      "#{URI.to_string(target)}: #{inspect(reason)} — the store is " <>
                      "authoritative; the target reconciles from it on its next load"
                  )

                  :ok
              end
          end
        end

      {:error, _} = err ->
        err
    end
  end

  # The committed-delete / failed-hint signal (must-fix #5): the durable
  # revoke DID commit, so this is a success variant — but a distinguishable
  # one, so an abort-on-error caller (member REMOVE) does NOT roll back
  # dependent work under the false belief that the member is fully intact.
  defp hint_failed(target, reason) do
    Logger.warning(
      "Ezagent.Identity.Grant: durable revoke committed but the :remove_cap " <>
        "reconcile hint failed for #{URI.to_string(target)}: #{inspect(reason)} — " <>
        "the store is authoritative; the target reconciles from it on its next load"
    )

    {:ok, {:hint_failed, reason}}
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
  failure-propagating).

  ② P2(c) (codex must-fix #4) — STORE-FIRST at construction: the durable
  `Ezagent.EntityCaps.revoke_persisted/2` delete commits HERE, while the
  handler builds the effect, so the revoke is durable even if the dispatch
  (now only the live-reconcile `:remove_cap` hint) never lands. RAISES on a
  `prepare/4` error OR a durable-delete failure — an effect site cannot
  carry an `{:error}` tuple, and a revoke that cannot commit durably must
  fail the handler loudly (let-it-crash; the slice mutation never commits
  under a failed security revoke).
  """
  @spec revoke_cap_returning_effect(URI.t(), Capability.t(), authorization(), atom()) ::
          {:dispatch_returning, Cmd.t(), keyword()}
  def revoke_cap_returning_effect(%URI{} = target, %Capability{} = cap, authorization, bind_as)
      when is_atom(bind_as) do
    case prepare(target, cap, authorization, :revoke_cap) do
      {:ok, {target_uri, cap2, ctx}} ->
        case Ezagent.EntityCaps.revoke_persisted(target, cap2) do
          :ok ->
            cmd = %Cmd{
              target: target_uri,
              action: storage_action(:revoke_cap),
              args: %{cap: cap2},
              ctx: Map.put(ctx, :reply, reply_for(:sync)),
              origin: :trusted_internal
            }

            {:dispatch_returning, cmd, bind_as: bind_as}

          {:error, reason} ->
            raise ArgumentError,
                  "Ezagent.Identity.Grant: cannot build revoke_cap effect — the durable " <>
                    "revoke failed to commit: #{inspect(reason)}. An effect site cannot " <>
                    "carry an {:error} tuple; a security revoke that cannot commit " <>
                    "durably must fail the handler (let-it-crash)."
        end

      {:error, reason} ->
        raise ArgumentError,
              "Ezagent.Identity.Grant: cannot build revoke_cap effect — #{inspect(reason)}. " <>
                "An effect site cannot carry an {:error} tuple; invalid authority is a " <>
                "programmer error (Decision #154)."
    end
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
