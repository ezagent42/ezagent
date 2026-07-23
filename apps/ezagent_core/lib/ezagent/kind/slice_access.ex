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
  def get_slice(uri, slice_key) when is_atom(slice_key),
    do: do_get_slice(uri, slice_key, 5_000)

  # Shared body with a caller-chosen `GenServer.call` timeout. `get_slice/2`
  # keeps the stable 5s default; the CapBAC identity read
  # (`read_identity_caps/1`) uses a shorter bounded per-attempt timeout so its
  # retry fits inside the enclosing dispatch deadline.
  defp do_get_slice(uri, slice_key, timeout) do
    uri_str =
      case uri do
        %URI{} = u -> URI.to_string(u)
        s when is_binary(s) -> s
      end

    case Ezagent.KindRegistry.lookup(uri_str) do
      {:ok, pid} when is_pid(pid) ->
        try do
          {:ok, slice} = GenServer.call(pid, {:ezagent_get_slice, slice_key}, timeout)
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

  @doc """
  Read + CLASSIFY an entity's `:identity` slice for CapBAC authorization, with a
  bounded retry on a TRANSIENT read failure. This is the mechanical read layer
  under `Ezagent.Kind.default_holds_cap?/2` — the SECURITY decision
  (predicate-A match / clean-deny / fail-loud) stays in that caller; this
  function only decides which of the three the read WAS.

  Returns:

  - `{:caps, MapSet.t()}` — the slice was read and carries a `%{caps: MapSet}`
    identity; the caller checks each held cap.
  - `:absent` — a GENUINE non-authorization: either a reachable (live) Kind that
    bears no cap-carrying identity slice, OR `:not_found` with NO durable
    snapshot (the entity never existed / never persisted an identity). The
    caller denies cleanly. This is the security-critical control against
    treating a non-existent entity as retryable.
  - `{:transient, reason}` — a KNOWN entity's identity was TRANSIENTLY
    unreadable (the Kind is alive but its call timed out / exited under pool
    starvation or a mid-restart; or it is briefly un-registered while its
    durable snapshot survives). The caller MUST fail LOUD (raise), never deny.

  ## Why the retry lives here

  A fast Kind-restart / brief pool blip clears within a couple of short
  backoffs, so retrying the read HERE converts the common transient into a
  successful `{:caps, _}` read (de-flaking the caller) — while a genuinely-stuck
  Kind exhausts the bound and surfaces `{:transient, _}` so the caller raises
  (fail-loud, not hang). `{:caps, _}` and `:absent` return immediately.

  Per-attempt timeout + retry bound are `Application.get_env(:ezagent_core, …)`
  tunables (`:identity_read_timeout_ms` 1_000, `:identity_read_max_attempts` 4,
  `:identity_read_backoff_ms` 25) so the bounded retry fits inside the enclosing
  dispatch deadline. A bounded per-attempt timeout also classifies a blocked
  Kind transient promptly instead of burning the full 5s default per attempt.
  """
  @spec read_identity_caps(URI.t() | String.t()) ::
          {:caps, MapSet.t()} | :absent | {:transient, term()}
  def read_identity_caps(entity_uri), do: read_identity_caps(entity_uri, 0)

  defp read_identity_caps(entity_uri, attempt) do
    case classify_identity_read(entity_uri) do
      {:transient, _reason} = transient ->
        if attempt + 1 < identity_read_max_attempts() do
          Process.sleep(identity_read_backoff_ms() * Bitwise.bsl(1, attempt))
          read_identity_caps(entity_uri, attempt + 1)
        else
          transient
        end

      settled ->
        settled
    end
  end

  # One `:identity` read, mapped to a classification.
  defp classify_identity_read(entity_uri) do
    case do_get_slice(entity_uri, :identity, identity_read_timeout_ms()) do
      {:ok, %{caps: caps}} when is_struct(caps, MapSet) ->
        {:caps, caps}

      # A live Kind that is NOT a cap-bearer (nil / non-`:caps` identity slice).
      # It is reachable, so this is a genuine "holds no caps", not transient.
      {:ok, _non_cap_bearing} ->
        :absent

      # Kind ALIVE but the call timed out / exited (pool starvation, mid-restart
      # GenServer.call queued behind a blocked init). Always transient — a live
      # registered pid IS a real entity, so there is no authz-hole risk.
      {:error, {:get_slice_exit, reason}} ->
        {:transient, {:get_slice_exit, reason}}

      # No live Kind — disambiguate a cold KNOWN entity from a non-existent one.
      {:error, :not_found} ->
        classify_not_found(entity_uri)

      # Any other read error: fail LOUD (never silently deny).
      {:error, reason} ->
        {:transient, reason}
    end
  end

  # `:not_found` disambiguation. The durable existence signal is a core-visible
  # `Ezagent.Ecto.KindSnapshot` row — what a Kind restart / rehydration
  # preserves (both the User and Agent cap-bearing Kinds persist
  # `{:snapshot, :on_change}`). A durable snapshot present → the entity is KNOWN
  # but transiently un-spawned → transient. Absent → genuinely non-existent →
  # deny. A DB error reading durability itself is transient (fail-loud), never a
  # silent deny — and cannot open a bypass, since a raise never grants access.
  defp classify_not_found(entity_uri) do
    case durable_snapshot_exists?(entity_uri) do
      :yes -> {:transient, :cold_but_durable}
      :no -> :absent
      {:unknown, reason} -> {:transient, {:durability_unreadable, reason}}
    end
  end

  defp durable_snapshot_exists?(entity_uri) do
    uri_str =
      case entity_uri do
        %URI{} = u -> URI.to_string(u)
        s when is_binary(s) -> s
      end

    case Ezagent.Ecto.KindSnapshot.get(uri_str) do
      nil -> :no
      _row -> :yes
    end
  rescue
    e -> {:unknown, e}
  catch
    :exit, reason -> {:unknown, {:exit, reason}}
  end

  @doc """
  Read + CLASSIFY an arbitrary Behavior slice — the GENERALIZATION of
  `read_identity_caps/1` (SPEC 2026-07-23 §2.2, the actor-extraction public read
  surface). Same 3-way classification, bounded retry, and `:not_found` durable
  disambiguation; the ONLY difference is the success mapping — a live slice read
  returns `{:ok, value}` for ANY slice, where the caps-specific reader returns
  `{:caps, MapSet.t()}`.

  Returns:

  - `{:ok, value}` — the slice was read from a live Kind (`value` may be `nil`
    for a live Kind that has not populated this slice).
  - `:absent` — a genuine non-existence: `:not_found` with NO durable snapshot
    (the instance never existed / never persisted). The caller denies cleanly.
  - `{:transient, reason}` — a KNOWN instance's slice was transiently unreadable
    (alive but call timed out / exited; or briefly un-registered while its
    durable snapshot survives). The caller MUST fail LOUD (raise), never deny.

  Preserves the fail-LOUD-not-deny contract as a PUBLIC primitive so the cap
  layer can stop reaching into private slice/snapshot state. Does NOT spawn.
  """
  @spec read_classified(URI.t() | String.t(), atom()) ::
          {:ok, term()} | :absent | {:transient, term()}
  def read_classified(uri, slice_key) when is_atom(slice_key),
    do: do_read_classified(uri, slice_key, 0)

  defp do_read_classified(uri, slice_key, attempt) do
    case classify_slice_read(uri, slice_key) do
      {:transient, _reason} = transient ->
        if attempt + 1 < identity_read_max_attempts() do
          Process.sleep(identity_read_backoff_ms() * Bitwise.bsl(1, attempt))
          do_read_classified(uri, slice_key, attempt + 1)
        else
          transient
        end

      settled ->
        settled
    end
  end

  # One slice read, mapped to a classification — mirrors `classify_identity_read/1`
  # but success is the generalized `{:ok, value}`, and the `:not_found`
  # durable-disambiguation (`classify_not_found/1`) is REUSED verbatim.
  defp classify_slice_read(uri, slice_key) do
    case do_get_slice(uri, slice_key, identity_read_timeout_ms()) do
      {:ok, value} ->
        {:ok, value}

      {:error, {:get_slice_exit, reason}} ->
        {:transient, {:get_slice_exit, reason}}

      {:error, :not_found} ->
        classify_not_found(uri)

      {:error, reason} ->
        {:transient, reason}
    end
  end

  defp identity_read_timeout_ms,
    do: Application.get_env(:ezagent_core, :identity_read_timeout_ms, 1_000)

  defp identity_read_max_attempts,
    do: Application.get_env(:ezagent_core, :identity_read_max_attempts, 4)

  defp identity_read_backoff_ms,
    do: Application.get_env(:ezagent_core, :identity_read_backoff_ms, 25)
end
