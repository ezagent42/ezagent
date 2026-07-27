defmodule Ezagent.Cap.HoldsCap do
  @moduledoc """
  Core spine: the `holds_cap?` cap-policy block RELOCATED OUT of
  `Ezagent.Kind` (C5 §3.4 — it is cap POLICY layered on the §2.2 public
  `Ezagent.Kind.read_classified/2`, not actor mechanics; it struct-matches
  `%Ezagent.Capability{}` and calls `Ezagent.Cap.authorize/3`, so it can
  never live in the actor app under the §3.4 opacity rule).

  The framework reaches this spine ONLY through the AuthzPort
  (`Ezagent.Kind.Ports.AuthzPort` → `Ezagent.Kind.Adapters.AuthzAdapter`);
  `Ezagent.Kind.holds_cap?/3` / `Ezagent.Kind.default_holds_cap?/2` remain
  as thin port delegates for the established caller API. STAYS in core when
  the framework moves to `apps/ezagent_actor`.
  """

  @doc """
  Default `holds_cap?/2` impl — used by `holds_cap?/3`
  when the target Kind module does not export the optional callback.

  Reads the entity's `:identity` slice directly via `Kind.get_slice/3`
  (a `GenServer.call` to the live Kind.Server, NOT a re-entry into
  `Invocation.dispatch/1` — this breaks the self-list-caps recursion) and
  tests each held cap against `needed` via `Capability.granted_by_entity?/1`
  (#154 predicate A) + `Capability.matches?/2`.

  ## Fail-LOUD on a transient read — NOT fail-closed (correctness gate)

  The `:identity` read has four possible outcomes, and they are NOT all a
  denial:

  | outcome | meaning | decision |
  |---|---|---|
  | `{:ok, %{caps: caps}}` | slice read, caps present | check caps; genuinely-absent → **deny** (`false`) |
  | `{:ok, other}` | live Kind, no cap-bearing identity slice | **deny** (`false`) — a non-cap-bearer holds no caps |
  | `{:error, {:get_slice_exit, _}}` | Kind is ALIVE but the call timed out / exited (DB-pool starvation, mid-restart) | **TRANSIENT** — bounded-retry, then `raise Ezagent.Kind.IdentityReadError` |
  | `{:error, :not_found}` | no live Kind | disambiguate by DURABLE existence (below) |

  A `:not_found` is the subtle case. A **durable Kind snapshot** existing for
  the URI (what a Kind restart / rehydration preserves) means the entity is
  KNOWN but transiently unreachable → TRANSIENT (retry/raise). No durable
  snapshot → the entity genuinely does not exist / has never persisted an
  identity → **deny** (`false`). This distinction is load-bearing: it MUST NOT
  treat a non-existent entity as transient (that would turn every probe of an
  unknown URI into a crash) and MUST NOT treat a KNOWN-but-cold entity as
  absent (the historical `_ -> false` bug — a spurious `:unauthorized` on a
  DB blip / Kind restart).

  Historically this whole non-`{:ok, caps}` space collapsed to a single
  `_ -> false` deny-by-default. Under a starved Ecto sandbox pool (or a
  production Kind restart / DB failover) a TRANSIENT read failure became a
  false DENY → the well-known WorldConversationTest CI flake AND a latent
  production correctness bug. The fix distinguishes a transient failure to read
  a KNOWN entity from a legitimate "no such cap / no such entity", and refuses
  to convert the former into a security decision — it retries, then fails LOUD.

  > **`cbac-done-right` contract:** the future cap-layer refactor MUST preserve
  > these fail-loud-not-deny semantics. A transient identity-read failure must
  > never be converted into a capability denial.

  Retry bound + per-attempt timeout are `Application.get_env(:ezagent_core, …)`
  tunables (`:identity_read_timeout_ms` 1_000, `:identity_read_max_attempts` 4,
  `:identity_read_backoff_ms` 25) so the bounded retry fits inside the enclosing
  dispatch deadline and a genuinely-stuck Kind eventually fails LOUD, not hangs.

  SPEC §3 default impl.
  """
  @spec default_holds_cap?(URI.t() | String.t() | :vm_internal | nil, Ezagent.Capability.t()) ::
          boolean()
  # `:vm_internal` remains a provenance marker for the fixed non-cap action
  # class only. It never supplies target capability authority.
  def default_holds_cap?(:vm_internal, %Ezagent.Capability{}), do: false

  def default_holds_cap?(nil, %Ezagent.Capability{}), do: false

  def default_holds_cap?(entity_uri, %Ezagent.Capability{} = needed) do
    needed_map = %{
      kind: needed.kind,
      behavior: needed.behavior,
      # SPEC 2026-05-27 capability-action-axis — propagate action axis
      # into the needed-map shape `Capability.matches?/2` consumes.
      action: Ezagent.Capability.action_of(needed),
      instance: needed.instance,
      workspace_uri: needed.workspace_uri
    }

    # Read + CLASSIFY the entity's `:identity` slice (bounded-retry on a
    # transient read) via the §2.2 public read surface
    # `Ezagent.Kind.read_classified/2` — the same fail-LOUD classification
    # the old `SliceAccess.read_identity_caps/1` applied (bounded retry +
    # `:not_found` durable-disambiguation), reached WITHOUT touching actor
    # internals (§4.2 forward gate; this spine module is core-side). The
    # SECURITY decision (predicate-A match / clean-deny / fail-loud raise)
    # stays HERE. The read returns one of:
    #   {:ok, %{caps: MapSet}} — slice read, check held caps
    #   {:ok, _other}          — live Kind, no cap-bearing identity → deny
    #   :absent                — genuinely no caps / no such entity → deny
    #   {:transient, why}      — a KNOWN entity was unreadable → fail LOUD
    case Ezagent.Kind.read_classified(entity_uri, :identity) do
      {:ok, %{caps: caps}} when is_struct(caps, MapSet) ->
        # #154 genesis collapse (2026-06-20) — predicate A: a slice-held cap
        # authorizes ONLY if its authority traces to a real ENTITY
        # (`granted_by_entity?/1`, never a `system://` principal). The grant
        # chokepoint already forces an `entity` granter on every grant, so this
        # is defense-in-depth against a stale pre-collapse snapshot carrying a
        # `system://`-granted cap. Mirrors the inline-`ctx.caps` check in
        # `Ezagent.Kind.Runtime.authorizes?/2`.
        #
        # The inner `rescue`/`catch` is INTENTIONALLY narrow: a MALFORMED cap in
        # a successfully-read slice is a legitimate non-match (deny), a distinct
        # failure class from the transient READ failure handled above — a bad cap
        # struct must NOT become a transient-raise.
        Enum.any?(caps, fn held ->
          try do
            Ezagent.Capability.granted_by_entity?(held) and
              match?(
                {:ok, %Ezagent.Capability{}},
                Ezagent.Cap.authorize(entity_uri, [held], needed_map)
              )
          rescue
            _ -> false
          catch
            _, _ -> false
          end
        end)

      {:ok, _non_cap_bearing} ->
        # A live Kind that is NOT a cap-bearer (nil / non-`:caps` identity
        # slice). It is reachable, so this is a genuine "holds no caps",
        # not transient — deny cleanly.
        false

      :absent ->
        # Genuinely-absent: a live Kind that bears no cap-carrying identity
        # slice, OR `:not_found` with NO durable snapshot (entity never existed
        # / never persisted an identity). Deny-by-default is CORRECT here — and
        # is the security-critical control against opening a bypass where a
        # non-existent entity would be treated as retryable.
        false

      {:transient, reason} ->
        # A KNOWN entity's identity was transiently unreadable. NEVER silently
        # deny — raise so the enclosing dispatch fails LOUD / the caller retries.
        raise Ezagent.Kind.IdentityReadError, entity_uri: entity_uri, reason: reason
    end
  end

  @doc """
  Resolve `holds_cap?/2` for `kind_module`, defaulting to
  `default_holds_cap?/2` when the optional callback is not exported.

  This is the entry point dispatch step 5.5 uses — never call
  `kind_module.holds_cap?(...)` directly without going through this
  helper, or you skip the default impl for the (common) Kinds that
  haven't overridden it.
  """
  @spec holds_cap?(module(), URI.t() | String.t(), Ezagent.Capability.t()) :: boolean()
  def holds_cap?(kind_module, entity_uri, %Ezagent.Capability{} = needed)
      when is_atom(kind_module) do
    if function_exported?(kind_module, :holds_cap?, 2) do
      kind_module.holds_cap?(entity_uri, needed)
    else
      default_holds_cap?(entity_uri, needed)
    end
  end
end
