defmodule Ezagent.Test.SnapshotFixtures do
  @moduledoc """
  Test-only helpers for seeding `kind_snapshots` rows.

  Production and domain code must persist Kind state through the Lifecycle /
  Kind.Server path. Tests that need pre-existing snapshot rows can use this
  module so direct low-level writes stay centralized and auditable.
  """

  alias Ezagent.Ecto.KindSnapshot

  @doc """
  Persist a Kind snapshot fixture through `Ezagent.Kind.Snapshot.save_now/4`.
  """
  @spec save_kind_snapshot(URI.t() | String.t(), module(), map(), keyword()) ::
          :ok | {:error, term()}
  def save_kind_snapshot(uri, kind_module, state, opts \\ []) when is_map(state) do
    Ezagent.Kind.Snapshot.save_now(uri, kind_module, state, opts)
  end

  @doc """
  Upsert a raw `kind_snapshots` fixture row.

  Use this only when a test specifically needs to seed a pre-serialized row or
  a legacy row shape. Prefer `save_kind_snapshot/4` for normal Kind state.
  """
  @spec upsert_kind_snapshot(
          String.t(),
          String.t(),
          binary(),
          non_neg_integer(),
          String.t(),
          keyword()
        ) ::
          {:ok, KindSnapshot.t()} | {:error, term()}
  def upsert_kind_snapshot(uri, kind_type, state_binary, version, workspace_uri, opts \\ [])
      when is_binary(uri) and is_binary(kind_type) and is_binary(state_binary) and
             is_integer(version) and is_binary(workspace_uri) do
    KindSnapshot.upsert(uri, kind_type, state_binary, version, workspace_uri, opts)
  end
end
