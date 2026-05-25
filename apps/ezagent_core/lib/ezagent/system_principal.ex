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
  Until then, callers that previously passed `caps: User.admin_caps()`
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

  # The bootstrap principal that grants caps to other system principals.
  # Re-used as `granted_by` for every legacy-bridge cap shape we mint.
  # Matches the existing constant in `Ezagent.Entity.User` (Phase 9 PR-8).
  @bootstrap_granted_by URI.parse("system://bootstrap/default")
  @bootstrap_granted_at ~U[2026-01-01 00:00:00Z]

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
    cap_strings = Catalog.caps_for!(parsed)
    initial_caps = caps_from_strings(cap_strings)

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
  Legacy-shape caps for `uri` — the PR-CC-1 bridge for callers that
  still feed `ctx.caps` directly.

  Returns `MapSet.t(Ezagent.Capability.t())` derived from the
  Catalog:

  - `"*"` in the catalog list → one wildcard cap
    (`%Capability{kind: :any, behavior: :any, instance: :any,
     workspace_uri: :any, granted_by: system://bootstrap/default}`) —
    the same shape `User.admin_caps/0` returned in PR-1.
  - Concrete cap strings (e.g. `"session.chat.send"`) → one
    wildcard cap (same shape). The string narrowing comes online
    when the new dispatch path (PR-CC-2b) reads
    `required_caps/0` + `holds_cap?/2`.
  - `[]` → empty MapSet (the `system://lv-anon-mount` case from
    SPEC §4.4: anonymous LV mounts get NO caps so the auth bug
    surfaces).

  ## Why all non-empty entries return wildcard

  PR-CC-1 keeps the OLD dispatch path (`Capability.matches?/2`)
  working. That matcher doesn't understand cap STRINGS — it only
  understands the struct shape with `:any` / module / URI fields.
  Translating each catalog string to a precisely-narrowed struct
  shape would re-invent half of PR-CC-2b. The contract of this
  function is "give callers an authorization handle equivalent to
  what `User.admin_caps/0` gave them for system call sites" — that's
  satisfied by the wildcard cap.

  The Catalog's STRINGS still narrow the principal's documented
  authority (the `caps_for!/1` consumers + invariant tests +
  PR-CC-2c data migration use them). The legacy bridge is the
  one-line slack until PR-CC-2b removes `ctx.caps` entirely.
  """
  @spec caps(URI.t() | String.t()) :: MapSet.t(Ezagent.Capability.t())
  def caps(uri) do
    parsed = parse!(uri)
    enforce_system_scheme!(parsed)
    cap_strings = Catalog.caps_for!(parsed)
    caps_from_strings(cap_strings)
  end

  # --- internals ---------------------------------------------------------

  defp caps_from_strings([]), do: MapSet.new()

  defp caps_from_strings(strings) when is_list(strings) do
    # Every non-empty Catalog entry maps to the same wildcard cap
    # struct in PR-CC-1. The strings themselves are recorded
    # verbatim on the Kind's slice (via `initial_caps` snapshot)
    # for PR-CC-2 / forensic inspection, but the OLD
    # `Capability.matches?/2` path needs the struct shape.
    MapSet.new([wildcard_cap()])
  end

  defp wildcard_cap do
    %Ezagent.Capability{
      kind: :any,
      behavior: :any,
      instance: :any,
      workspace_uri: :any,
      granted_by: @bootstrap_granted_by,
      granted_at: @bootstrap_granted_at
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
