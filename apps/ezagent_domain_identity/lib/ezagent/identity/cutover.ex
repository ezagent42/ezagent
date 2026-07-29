defmodule Ezagent.Identity.Cutover do
  @moduledoc """
  #189 PR-3 (FIX 5, the keystone) — the persisted identity-plane CUTOVER EPOCH.

  The read-flip (the store becomes the AUTHORITATIVE durable holder source) and
  the ephemeral ever-created signal (the store decides `:created` vs `:existed`)
  are the post-cutover semantics. Merging PR-3 must NOT flip production the
  instant it lands: the store is only a parity-correct mirror of legacy AFTER an
  operator runs the fenced `mix ezagent.identity.cutover` (backfill →
  fleet-parity barrier → activate). This module is the durable, code-visible
  gate that makes that one-shot merge prod-safe.

    * **Before the epoch is active** (no singleton row, or the row is
      unreadable) every gated consumer runs the PR-1 LEGACY-authoritative
      semantics — the store is NEVER consulted for an authorization read, and
      the ephemeral freshness decision ignores the store. This is exactly the
      behavior production runs today, so merging changes nothing until the
      operator activates.
    * **After the epoch is active** (`activate/0` wrote the singleton row) the
      store-authoritative reads + the store-driven ephemeral ever-created signal
      switch on.

  ## Fail-CLOSED on an unreadable epoch

  `active?/0` resolves an unreadable epoch (DB error, missing table on a
  half-migrated node) to `false` — i.e. PRE-EPOCH legacy semantics. New code
  must NEVER authorize from the store on an unreadable epoch: an epoch we cannot
  prove is active is treated as inactive. The unreadable result is NOT cached,
  so a later read retries.

  ## Runtime cost

  The epoch is MONOTONE (once active, always active). After activation the fast
  path is a single `:persistent_term` read (the sticky `true`). Before
  activation each read does one indexed single-row `Repo.get` — cheap, and only
  during the transient pre-cutover window. `:persistent_term` caching is
  disabled in test (`:identity_cutover_pt_cache` false) so the VM-global term
  can never leak the sticky `true` across the suite; tests drive the epoch via
  the `:identity_cutover_active_override` app-env flag (or a real DB row) and
  read fresh every call.

  ## Cross-node propagation

  Each node reads the epoch row from the shared DB, so `activate/0` on one node
  becomes visible to every other node's next pre-epoch read (the sticky `true`
  is per-node but only ever caches the monotone `true`). The cutover is designed
  to run under the fleet write-quiescence fence the barrier documents; a fleet
  restart (or `prime/0` at boot) picks up the activation cleanly.
  """

  use Ecto.Schema

  require Logger

  alias EzagentCore.Repo

  @singleton_id "identity"
  @pt_key {__MODULE__, :active}

  @primary_key {:id, :string, autogenerate: false}
  schema "identity_cutover" do
    field(:activated_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Whether the identity-plane cutover epoch is active — the single predicate
  every store-authoritative code path gates on.

  Resolution order: the `:identity_cutover_active_override` app-env flag (test /
  dev escape) wins when set; otherwise the sticky `:persistent_term` cache; then
  a fail-closed DB read.
  """
  @spec active?() :: boolean()
  def active? do
    case Application.get_env(:ezagent_domain_identity, :identity_cutover_active_override, :unset) do
      true -> true
      false -> false
      :unset -> runtime_active?()
    end
  end

  defp runtime_active? do
    case :persistent_term.get(@pt_key, :unknown) do
      true -> true
      _ -> db_active?()
    end
  end

  # Fail-CLOSED: an unreadable epoch (`:error`) resolves to `false` (pre-epoch
  # legacy) and is NOT cached, so a later read retries. A definitive `active`
  # result is promoted to the sticky `:persistent_term` cache (the epoch is
  # monotone) when pt caching is enabled.
  defp db_active? do
    case fetch_row() do
      {:ok, %__MODULE__{}} ->
        maybe_promote()
        true

      {:ok, nil} ->
        false

      :error ->
        false
    end
  end

  # TEST-ONLY forced-read-error seam (compiled IN only for `MIX_ENV=test`,
  # provably unreachable in a dev/prod/release build). Consulted ONLY when
  # `:ezagent_domain_identity, :identity_cutover_force_read_error` is set — never
  # set outside the fail-closed regression — so it lets `CutoverTest` prove that
  # an UNREADABLE epoch resolves to `false` (pre-epoch legacy), which a real DB
  # error is not reproducible for in the sandbox (the table exists).
  @forced_read_error_seam Mix.env() == :test

  # Distinguishes a successful "no row" (`{:ok, nil}`) from a read error
  # (`:error`) — the fail-closed contract depends on that distinction (a bare
  # `Repo.get` rescue-to-nil would make an unreadable epoch look inactive-but-
  # cacheable and, worse, indistinguishable from a genuine absent row).
  if @forced_read_error_seam do
    defp fetch_row do
      if Application.get_env(:ezagent_domain_identity, :identity_cutover_force_read_error, false) do
        :error
      else
        real_fetch_row()
      end
    end
  else
    defp fetch_row, do: real_fetch_row()
  end

  defp real_fetch_row do
    {:ok, Repo.get(__MODULE__, @singleton_id)}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp maybe_promote do
    if pt_cache_enabled?(), do: :persistent_term.put(@pt_key, true)
    :ok
  end

  defp pt_cache_enabled? do
    Application.get_env(:ezagent_domain_identity, :identity_cutover_pt_cache, true)
  end

  @doc """
  Prime the `:persistent_term` cache at boot (prod/dev) so the steady-state fast
  path is a single term read. A no-op when pt caching is disabled (test) or the
  epoch is not yet active/unreadable (fail-closed — nothing to cache).
  """
  @spec prime() :: :ok
  def prime do
    if pt_cache_enabled?(), do: _ = db_active?()
    :ok
  end

  @doc """
  Idempotently ACTIVATE the cutover epoch: write the singleton row and promote
  the sticky cache. Called by `mix ezagent.identity.cutover` ONLY after the
  backfill + fleet-parity barrier have completed under the write-quiescence
  fence. Re-running is a no-op (the epoch is monotone — there is deliberately no
  deactivation path).
  """
  @spec activate() :: :ok | {:error, term()}
  def activate do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %__MODULE__{}
    |> Ecto.Changeset.change(id: @singleton_id, activated_at: now)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :id)
    |> case do
      {:ok, _row} ->
        maybe_promote()
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Whether the epoch singleton row exists — a DEFINITIVE read (an unreadable DB
  raises rather than silently reporting `false`), for the cutover task's own
  post-activate confirmation. Distinct from `active?/0`, which is fail-closed
  for the hot authorization path.
  """
  @spec activated?() :: boolean()
  def activated? do
    not is_nil(Repo.get(__MODULE__, @singleton_id))
  end
end
