defmodule Ezagent.Kind.SliceAccess do
  @moduledoc """
  Cross-process reads of a live Kind instance's Behavior slices, plus the
  two-container (T3) normalization that flattens a converted Lifecycle slice to
  its consumer-facing `:state` view.

  Extracted verbatim from `Ezagent.Kind` for the oversized-module arch gate
  (`oversized_modules_gt_1000` burn-down, 2026-06-23). `Ezagent.Kind` keeps
  `get_slice/2`, `get_raw_slice/2`, and `normalize_slice_view/1` as `defdelegate`s
  to this module, so the public API and every call site are unchanged.

  These are NOT hot-path APIs — a `Behavior.invoke/4` reads its own slice via the
  `slice` argument. This module is for cross-process lookups during default-grant
  evaluation, admin LV display, snapshot-read normalization, and test infra.
  """

  @doc """
  Read a specific Behavior slice from a live Kind instance.

  Synchronous `GenServer.call` to the Kind.Server — returns the
  current value of `state.state[slice_key]`. Used by lookups like
  `Ezagent.Entity.Session.owner/1` (PR-OWN-2, caps-data-ownership
  SPEC #306 §7) where a Behavior's `data_owner/1` callback needs
  to read durable per-instance state without going through dispatch.

  Returns `{:ok, slice}` (the slice may be `nil` or `%{}` if not
  initialised), `{:error, :not_found}` if the URI has no live
  Kind, or `{:error, reason}` if the call times out.

  NOT a hot-path API — `Behavior.invoke/4` should read its own
  slice via the `slice` argument; this is for cross-process
  lookups during default-grant evaluation, admin LV display, etc.

  ## Two-container normalization (Lifecycle Phase B foundation, T3)

  A Behavior converted to `use Ezagent.Lifecycle` stores its slice as the
  two-container shape `%{state: persistent, transients: volatile}` (SPEC
  2026-05-29 §0.1). Cross-module callers (`Ezagent.Identity`,
  `Ezagent.ActionSet.ApiKeys`, `Ezagent.ActionSet.ExternalMirror`,
  `Ezagent.Entity.Session`, the admin LVs, …) read a converted producer's
  slice via FLAT field access — e.g. `get_slice(uri, :session).owner_uri`.
  Returning the raw two-container map would make every such field resolve
  to `nil` (the flat field lives under `:state`, not at the top level) —
  a silent-nil that corrupts the consumer without crashing.

  `get_slice/2` therefore returns the `:state` view at this single
  chokepoint when the slice is two-container, and the slice UNCHANGED when
  it is legacy-flat. This makes a converted producer transparent to all
  consumers (the Phase-A sibling-normalization precedent, generalized to
  the cross-process read path) — the consumer never learns whether the
  producer migrated. This is NOT a back-compat shim: it turns a
  silent-nil into the correct durable data (`feedback_let_it_crash_no_workarounds`).
  """
  @spec get_slice(URI.t() | String.t(), atom()) ::
          {:ok, term()} | {:error, term()}
  def get_slice(uri, slice_key) when is_atom(slice_key) do
    uri_str =
      case uri do
        %URI{} = u -> URI.to_string(u)
        s when is_binary(s) -> s
      end

    case Ezagent.KindRegistry.lookup(uri_str) do
      {:ok, pid} when is_pid(pid) ->
        try do
          {:ok, slice} = GenServer.call(pid, {:ezagent_get_slice, slice_key}, 5_000)
          {:ok, normalize_slice_view(slice)}
        catch
          :exit, reason -> {:error, {:get_slice_exit, reason}}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Read a slice WITHOUT the T3 two-container normalization — the RAW slice
  as the host GenServer holds it.

  For a converted Lifecycle Behavior this returns the full
  `%{state: persistent, transients: volatile}` map (NOT the flattened
  `:state` view that `get_slice/2` returns). This is the introspection
  path the Lifecycle test infrastructure
  (`Ezagent.LifecycleCase.assert_transients_rebuilt/2`) needs to assert on
  the `transients` container — a normalized read would hide it.

  Production cross-module consumers want the flat `.state` view and MUST
  use `get_slice/2`; this raw variant exists for test infra + any rare
  caller that legitimately needs to see the container split.
  """
  @spec get_raw_slice(URI.t() | String.t(), atom()) ::
          {:ok, term()} | {:error, term()}
  def get_raw_slice(uri, slice_key) when is_atom(slice_key) do
    uri_str =
      case uri do
        %URI{} = u -> URI.to_string(u)
        s when is_binary(s) -> s
      end

    case Ezagent.KindRegistry.lookup(uri_str) do
      {:ok, pid} when is_pid(pid) ->
        try do
          {:ok, slice} = GenServer.call(pid, {:ezagent_get_slice, slice_key}, 5_000)
          {:ok, slice}
        catch
          :exit, reason -> {:error, {:get_slice_exit, reason}}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Normalize a slice to its consumer-facing flat view (T3).

  A converted Lifecycle slice is `%{state: persistent, transients:
  volatile}`; cross-module consumers want the `state` map. A legacy flat
  slice has no `:transients` sub-key and passes through unchanged. The
  detection is purely structural (a map carrying BOTH `:state` and
  `:transients` keys), so no engine/Behavior coupling is introduced —
  symmetric with `Ezagent.Kind.Snapshot.strip_transients/1`.

  Exposed (not private) so the persisted-snapshot read path
  (`McpServer.load_chat_slice` and any other `decode_state`-then-read
  consumer) can apply the SAME normalization to an on-disk slice that a
  converted Kind wrote in the two-container shape.

  ## Persisted shape (the transients-stripped case)

  The in-MEMORY converted slice is `%{state, transients}`. But the snapshot
  persist path strips `:transients` (`Ezagent.Kind.Snapshot.strip_transients/1`),
  so the ON-DISK slice is a single-key `%{state: persistent}` with NO
  `:transients`. The first clause (both keys present) therefore does NOT match a
  persisted slice — hence the second clause below, which unwraps a single-key
  `%{state: map}`. Without it, a `decode_state`-then-read consumer reads the
  wrapped shape and finds none of the persistent fields (the regression that
  broke orchestrator MCP registration + Feishu mirror #502).

  > CONSTRAINT for Kind authors: a Kind's flat persistent state must NEVER be a
  > bare single-key `%{state: map}`, or it would be wrongly unwrapped here. (All
  > current Kinds' flat states are multi-key or `%{caps: ...}`/`%{content:
  > ...}`/`%{}` — verified.)
  """
  @spec normalize_slice_view(term()) :: term()
  def normalize_slice_view(%{state: state, transients: _transients}) when is_map(state),
    do: state

  # Persisted (transients-stripped) two-container slice: a single-key
  # `%{state: map}`. The `map_size == 1` guard matches ONLY this exact shape,
  # never a legacy-flat slice that merely carries a `:state` field among others.
  def normalize_slice_view(%{state: state} = slice) when is_map(state) and map_size(slice) == 1,
    do: state

  def normalize_slice_view(slice), do: slice
end
