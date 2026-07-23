defmodule Ezagent.SystemPrincipal do
  @moduledoc """
  Runtime API for `system://` principals — the closed-allowlist
  replacement for ambient `User.admin_caps/0` authority.

  Per SPEC `2026-05-25-caps-cleanup-v1.md` §4. Each system-internal
  dispatch ledger formerly got a NAMED principal URI instead of
  impersonating the bootstrap admin. (The eliminate-system-principals
  north star — see `capbac.md` §7 — has reached GENESIS-ONLY: as of the
  2026-06-20 session-internal elimination, every non-genesis principal is
  gone and `system://bootstrap` is the sole remaining entry. The final
  step collapses even that genesis into `entity://system/user/admin`.) The
  `Ezagent.SystemPrincipal.Catalog` declares the closed set
  of principals + their permitted cap structs.

  ## Two responsibilities

  - `ensure/1` — idempotently spawn the principal as a User-shaped
    Entity Kind so that dispatch paths sourcing caller caps from the
    slice see the right cap set. Reads caps from `Catalog.caps_for!/1`
    — caller cannot pass arbitrary caps.

  - `caps/1` — legacy-shape bridge for callers that still feed
    `ctx.caps` directly (the old dispatch path of PR-CC-1's window
    before PR-CC-2b removes the field). Returns a
    `MapSet.t(Ezagent.Capability.t())` derived deterministically
    from the catalog.

  ## Why the legacy bridge exists in PR-CC-1

  SPEC §4.4 row 1 ("`caps:` field removed") is PR-CC-2b's deliverable
  — it requires the new dispatch path (`required_caps/0` callback +
  `holds_cap?/2` + cap-snapshot contract) which doesn't exist yet.
  Until then, callers that previously passed `caps: <admin caps>`
  must continue to pass SOMETHING for the existing
  `Ezagent.Capability.matches?/2` check in `Kind.Runtime` step 5.5.
  `SystemPrincipal.caps/1` is that SOMETHING — it returns an
  authorization shape equivalent to the previous admin_caps for
  catalog entries whose strings include `"*"`, and an empty MapSet
  for `system://lv-anon-mount` (the auth-bug surfacer per §4.4).

  After PR-CC-2b lands, `caps/1` is DELETED and callers pass only
  `caller: <system uri>` — dispatch derives caps from the principal's
  slice via the cap-snapshot path.

  ## Persistence (PR-CC-1 scope decision)

  SPEC §4.3 says system principals persist via the `users` table.
  That row shape requires `[Capability.t()]`, and the schema's
  `workspace_uri NOT NULL` is workspace-scoped — fitting a
  `system://` URI into this shape requires PR-CC-2c's string-shape
  data migration. For PR-CC-1, system principals are spawned as
  User Kinds with `:identity` slice (snapshot-backed via
  `kind_snapshots` which already accepts `system://` URIs per
  SPEC #324 rev 3) but are NOT persisted into the `users` table.
  They are deterministically re-spawned from the Catalog on each boot
  — the Catalog itself is the persistent definition.
  """

  alias Ezagent.SystemPrincipal.Catalog

  @doc """
  Idempotently spawn the system principal Entity Kind for `uri`.

  Reads the cap list from `Catalog.caps_for!/1`. The principal is
  spawned as a `Ezagent.Entity.User` Kind (same shape — `:identity`
  slice carrying caps); only the URI scheme differs (`system://`
  instead of `entity://user/...`).

  Hard-raises if `uri` is not in the catalog OR is non-`system://`
  scheme. Per `feedback_let_it_crash_no_workarounds` — bad URI is a
  programmer error.

  Returns `:ok` on success or already-spawned. Returns
  `{:error, reason}` for other supervisor failures.

  ## Idempotency

  If the Kind is already alive (already-started result from the
  supervisor), returns `:ok`. The caller does not need to track
  first-call vs repeat-call.
  """
  @spec ensure(URI.t() | String.t()) :: :ok | {:error, term()}
  def ensure(uri) do
    parsed = parse!(uri)
    enforce_system_scheme!(parsed)

    # Catalog.caps_for!/1 raises if uri is not registered — defense
    # in depth so a caller cannot mint an ad-hoc system principal.
    # Post-PR-CC-2-v2 the catalog returns `[%Capability{}]` directly.
    initial_caps = parsed |> Catalog.caps_for!() |> MapSet.new()

    # derivation-edge: genesis-root system principal has no parent
    case Ezagent.Kind.spawn(Ezagent.Entity.User, %{
           uri: parsed,
           initial_caps: initial_caps
         }) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Convenience helper: parse a `system://<service>` URI from a string.

  Provided so call sites read `SystemPrincipal.uri("boot-reconciler")`
  instead of `Ezagent.URI.new!("system://boot-reconciler")` — minor
  readability win, no semantic difference. Raises if the resulting
  URI is not in the Catalog.
  """
  @spec uri(String.t()) :: URI.t()
  def uri(service) when is_binary(service) do
    parsed = Ezagent.URI.system_principal(service)

    unless Catalog.member?(parsed) do
      raise ArgumentError,
            "#{URI.to_string(parsed)} is not in Ezagent.SystemPrincipal.Catalog " <>
              "(SPEC caps-cleanup-v1 §4.1)."
    end

    parsed
  end

  @doc """
  Runtime caps for `uri` — returned as `MapSet.t(Ezagent.Capability.t())`
  for the dispatch path's `ctx.caps` and slice `initial_caps`.

  ## Narrow catalog is the source of truth

  Returns the catalog's structurally narrow `[%Capability{}]` list
  as a MapSet — nothing added, nothing removed. The catalog
  (`Ezagent.SystemPrincipal.Catalog`) declares each principal's
  minimum required authority per SPEC `2026-05-25-caps-cleanup-v1-r4-impl.md`
  §5; this function is a pure pass-through.

  Wildcard authority is now held ONLY by the genesis root, declared
  INSIDE the catalog (not as a runtime bridge):

  - `system://bootstrap` — Decision #81 admin invariant.

  (`system://mix-task` — operator-driven, in-VM trust model §10.5 —
  was ELIMINATED 2026-06-19; the operator CLI tasks now route their
  authority through the real `entity://system/user/admin` entity with an
  inline per-action admin cap, not this ambient wildcard principal.
  `system://chat-reply` — agent reply fan-out — was ELIMINATED
  2026-06-20, 甲-3; each agent bridge now presents its OWN inline narrow
  `session.send` cap with `granted_by: <agent_uri>` self-authority.
  `system://chat-router` — the structural open-plugin `chat.receive`
  fan-out, the LAST non-genesis wildcard holder — was ELIMINATED
  2026-06-20, 甲-4; the fan-out now mints a per-recipient inline
  `:receive` cap from the recipient's own URI [member self-consent], so
  the Catalog no longer needs to enumerate the open plugin Behavior set.)

  ## History — the pathology-B sweep removed the transitional wildcard

  PR-CC-2-v2 (#354) shipped this function with a transitional
  `transition_bridge_wildcard()` that injected the all-`:any`
  wildcard into every non-empty principal's MapSet — preserving
  PR-CC-1's coarse runtime semantics during the cap-shape switch.
  The wildcard is now REMOVED per Allen's "no defer" directive
  (`feedback_let_it_crash_no_workarounds`): each principal sees ONLY
  the narrow catalog declaration. Production callers that relied on
  the implicit wildcard now hold a documented per-principal cap; the
  catalog itself is the auditable declaration of who can do what.

  ## `lv-anon-mount` semantics preserved

  `system://lv-anon-mount` keeps `[]` (per SPEC §4.4 — anonymous LV
  mounts get NO caps so the auth bug surfaces).
  """
  @spec caps(URI.t() | String.t()) :: MapSet.t(Ezagent.Capability.t())
  def caps(uri) do
    parsed = parse!(uri)
    enforce_system_scheme!(parsed)

    parsed
    |> Catalog.caps_for!()
    |> MapSet.new()
  end

  # --- internals ---------------------------------------------------------

  defp parse!(%URI{} = u), do: u
  defp parse!(s) when is_binary(s), do: Ezagent.URI.new!(s)

  defp enforce_system_scheme!(%URI{scheme: "system"}), do: :ok

  defp enforce_system_scheme!(%URI{} = uri) do
    raise ArgumentError,
          "Ezagent.SystemPrincipal expects a system URI, got: " <>
            inspect(Ezagent.URI.stable_key(uri))
  end
end
