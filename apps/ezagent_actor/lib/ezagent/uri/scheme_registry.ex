defmodule Ezagent.URI.SchemeRegistry do
  @moduledoc """
  Runtime ETS source of truth for allowed URI schemes (SPEC v2 §5.6 §5.11).

  Replaces the compile-time `@known_schemes` module attribute that
  previously lived in `Ezagent.URI`. The hardcoded list drifted from
  reality across PRs #141-#144 (deleted `user`, `agent`, `feishu`,
  `routing-admin`, `pty-input`); the lockdown ensures it never drifts
  again — schemes can only be added through `Ezagent.SpawnRegistry.register/2`
  (the audited path) or the boot-time seed in `EzagentActor.Application`.

  ## Boot order

  The ETS table is created by `EzagentActor.EtsOwner` (lives in `@tables`
  alongside the other reliability primitives). `EzagentActor.Application`
  calls `init/0` (idempotent) + seeds the 6 SPEC §5.6 schemes
  (entity/workspace/session/template/resource/system) before any code
  that would call `Ezagent.URI.new!/1`.

  ## Lockdown invariant

  After PR #145, `parse!/1` rejects all of:
  `user://`, `agent://`, `feishu://`, `message://`, `routing-admin://`,
  `pty-input://` (all deleted in earlier PRs). See
  `Ezagent.URI.SchemeRegistryTest`.
  """

  @table :ezagent_scheme_registry

  @doc "Return the ETS table name (used by `EzagentActor.EtsOwner`)."
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Idempotently ensure the ETS table exists. Safe to call at boot in
  `EzagentActor.Application.start/2` — if `EtsOwner` already created
  the table this is a no-op.
  """
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Register a scheme as allowed. Plugins MUST go through
  `Ezagent.SpawnRegistry.register/2` (which co-registers); direct
  callers of this function should only be boot-time seed code in
  `EzagentActor.Application`.
  """
  @spec register(String.t()) :: :ok
  def register(scheme) when is_binary(scheme) do
    :ets.insert(@table, {scheme})
    :ok
  end

  @doc "Returns whether `scheme` has been registered."
  @spec registered?(String.t()) :: boolean()
  def registered?(scheme) when is_binary(scheme) do
    :ets.member(@table, scheme)
  end

  @doc "Sorted list of currently-registered schemes (for diagnostics + error messages)."
  @spec list_all() :: [String.t()]
  def list_all do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {s} -> s end)
    |> Enum.sort()
  end
end
