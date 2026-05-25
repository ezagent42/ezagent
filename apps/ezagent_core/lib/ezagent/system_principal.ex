defmodule Ezagent.SystemPrincipal do
  @moduledoc """
  Runtime API for `system://` principals — the closed-allowlist
  replacement for ambient `User.admin_caps/0` authority.

  Per SPEC `2026-05-25-caps-cleanup-v1.md` §4. Each system-internal
  dispatch ledger gets a NAMED principal URI (e.g.
  `system://boot-reconciler`, `system://chat-reply`,
  `system://lv-anon-mount`) instead of impersonating the bootstrap
  admin. The `Ezagent.SystemPrincipal.Catalog` declares the closed set
  of 14 principals + their permitted cap strings.

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
  instead of `URI.parse("system://boot-reconciler")` — minor
  readability win, no semantic difference. Raises if the resulting
  URI is not in the Catalog.
  """
  @spec uri(String.t()) :: URI.t()
  def uri(service) when is_binary(service) do
    parsed = URI.parse("system://" <> service)

    unless Catalog.member?(parsed) do
      raise ArgumentError,
            "system://#{service} is not in Ezagent.SystemPrincipal.Catalog " <>
              "(SPEC caps-cleanup-v1 §4.1)."
    end

    parsed
  end

  @doc """
  Runtime caps for `uri` — returned as `MapSet.t(Ezagent.Capability.t())`
  for the dispatch path's `ctx.caps` and slice `initial_caps`.

  ## Two-tier cap shape during PR-CC-2-v2 transition

  The catalog (`Ezagent.SystemPrincipal.Catalog`) holds STRUCTURALLY
  NARROW caps per SPEC `2026-05-25-caps-cleanup-v1-r4-impl.md` §5 —
  the declared intent for each principal. The
  no-wildcard invariant test asserts this narrowing.

  But the actual RUNTIME cap set this function returns combines the
  catalog's narrow shape with a transitional bootstrap-wildcard cap
  (for non-empty / non-`lv-anon-mount` principals). The wildcard is
  the legacy PR-CC-1 bridge shape that ALL production code paths
  authoring before PR-CC-2-v2 implicitly depended on (the bridge
  collapsed every non-empty catalog entry to one wildcard struct).
  Removing the wildcard now would break tests across `domain_chat`,
  `domain_external_mirror`, `domain_workspace`, etc., that dispatch
  under these principals.

  PR-CC-2c (per parent SPEC §0d row 1) deletes `ctx.caps` from
  dispatch entirely — at that point the wildcard transition is gone
  and the dispatch reads ONLY the slice (which holds the same widened
  shape until each principal's slice is migrated independently). The
  narrow catalog is the source of truth for documentation + the
  invariant test; the widened runtime is the bridge.

  ## `lv-anon-mount` semantics preserved

  `system://lv-anon-mount` keeps `[]` (per SPEC §4.4 — anonymous LV
  mounts get NO caps so the auth bug surfaces). The empty catalog
  list maps to an empty MapSet (no wildcard added).
  """
  @spec caps(URI.t() | String.t()) :: MapSet.t(Ezagent.Capability.t())
  def caps(uri) do
    parsed = parse!(uri)
    enforce_system_scheme!(parsed)

    catalog_caps = Catalog.caps_for!(parsed)

    case catalog_caps do
      [] ->
        # `system://lv-anon-mount` — explicitly empty per SPEC §4.4.
        MapSet.new()

      list when is_list(list) ->
        # Catalog declares the structural narrow; the transitional
        # bootstrap-wildcard preserves PR-CC-1 runtime semantics for
        # ctx.caps consumers. PR-CC-2c removes the wildcard half by
        # deleting the bridge consumer. Bootstrap principal already
        # has a wildcard cap in its catalog list (admin_invariant?/1
        # recognises it); de-duped on MapSet insertion.
        list
        |> MapSet.new()
        |> MapSet.put(transition_bridge_wildcard())
    end
  end

  # --- internals ---------------------------------------------------------

  # PR-CC-2-v2 transition: the legacy wildcard cap PR-CC-1's bridge
  # minted for every non-empty catalog entry. Re-issued here as the
  # additive `ctx.caps` shape so existing production code paths that
  # depend on system-principal admin authority keep working until
  # PR-CC-2c deletes `ctx.caps` entirely.
  #
  # This wildcard's `granted_by` matches `Capability.admin_invariant?/1`'s
  # shape (`%URI{scheme: "system", host: "bootstrap"}`), so the
  # bootstrap admin's structural invariant survives.
  defp transition_bridge_wildcard do
    %Ezagent.Capability{
      kind: :any,
      behavior: :any,
      instance: :any,
      workspace_uri: :any,
      granted_by: URI.parse("system://bootstrap/default"),
      granted_at: ~U[2026-01-01 00:00:00Z]
    }
  end

  defp parse!(%URI{} = u), do: u
  defp parse!(s) when is_binary(s), do: URI.parse(s)

  defp enforce_system_scheme!(%URI{scheme: "system"}), do: :ok

  defp enforce_system_scheme!(%URI{} = uri) do
    raise ArgumentError,
          "Ezagent.SystemPrincipal expects a system:// URI, got: " <>
            inspect(URI.to_string(uri))
  end
end
