defmodule Ezagent.ExternalMirror do
  @moduledoc """
  `Ezagent.ExternalMirror` — read-side facade for the ExternalMirror
  Domain (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §4.4).

  Used by LV / CLI / admin tooling to enumerate adapters + bindings.
  Mutations go through `:bind` / `:unbind` dispatch on the Session
  Kind (P14 — those land in PR-EM-3). The facade is reads-only and
  never invokes a `*Registry.register/2` API directly.

  ## PR-EM-1 implementation status

  - `list_adapters/0` — **fully wired** (reads AdapterRegistry,
    returns SPEC §4.4 shape).
  - `list_bindings/1` — **stubbed**, returns `{:ok, []}`. Real
    implementation depends on the `:external_mirror` Session slice
    landing in PR-EM-3; the stub keeps LV / CLI callers from
    crashing during the PR-EM-2/3 interim.
  - `sessions_for_adapter/1` — **stubbed**, returns `{:ok, []}`.
    Same reason — depends on the slice projection table added in
    PR-EM-3.

  ## Stub-return policy (decision)

  Three options were considered for the unimplemented helpers:

  1. **Raise `:not_implemented`** — surfaces the gap loudly but
     crashes any LV/CLI that calls the function before PR-EM-3 ships.
  2. **Return `{:error, :not_implemented}`** — caller must handle a
     new error tag that goes away in PR-EM-3.
  3. **Return `{:ok, []}` with a moduledoc note** ← **CHOSEN**.

  Option 3 wins because the eventual real implementation has the
  exact same return shape (`{:ok, [binding()]}` / `{:ok, [URI.t()]}`),
  so the call sites built against the stub work unchanged after
  PR-EM-3 lands. Empty-list semantically matches reality during the
  PR-EM-1/2 window — no bindings exist yet because the `:bind`
  action ships in PR-EM-3.

  No "structural-illegality" violation: per SPEC §5.2 the
  fail-loud rule applies to LOOKUPS for entities the system claims
  to track (registry misses). Returning an empty enumeration for a
  feature whose data store doesn't exist yet is a different shape —
  the system isn't lying about a binding's existence, the binding
  set is genuinely empty.
  """

  alias Ezagent.ExternalMirror.AdapterRegistry

  @typedoc "A bound external mirror — shape pinned in SPEC §4.1."
  @type binding :: %{
          adapter_id: String.t(),
          target_id: String.t(),
          metadata: map(),
          binding_state: map()
        }

  @typedoc """
  The operator-facing adapter descriptor returned by
  `list_adapters/0` (SPEC §4.4).
  """
  @type adapter_descriptor :: %{
          id: String.t(),
          display_name: String.t(),
          description: String.t()
        }

  @doc """
  List bindings on `session_uri`.

  **PR-EM-1 stub.** Returns `{:ok, []}` unconditionally; the real
  implementation reads the Session Kind's `:external_mirror` slice
  (PR-EM-3). See moduledoc "Stub-return policy" for the rationale.
  """
  @spec list_bindings(URI.t()) :: {:ok, [binding()]} | {:error, term()}
  def list_bindings(%URI{} = _session_uri) do
    {:ok, []}
  end

  @doc """
  List sessions with at least one binding for `adapter_id`.

  **PR-EM-1 stub.** Returns `{:ok, []}` unconditionally; the real
  implementation reads the cross-session projection table populated
  by `:bind` / `:unbind` (PR-EM-3). See moduledoc "Stub-return
  policy" for the rationale.
  """
  @spec sessions_for_adapter(adapter_id :: String.t()) :: {:ok, [URI.t()]}
  def sessions_for_adapter(adapter_id) when is_binary(adapter_id) do
    {:ok, []}
  end

  @doc """
  List all registered adapters as `%{id, display_name, description}`
  (SPEC §4.4 shape).

  Read directly from `AdapterRegistry`; fully wired in PR-EM-1.

  The admin LV (PR-EM-FINAL) filters this list by the caller's caps
  (Cap 2 per SPEC §5.4 — narrow-by-default).
  """
  @spec list_adapters() :: [adapter_descriptor()]
  def list_adapters do
    AdapterRegistry.list()
    |> Enum.map(fn %{id: id, display_name: name, description: desc} ->
      %{id: id, display_name: name, description: desc}
    end)
  end
end
