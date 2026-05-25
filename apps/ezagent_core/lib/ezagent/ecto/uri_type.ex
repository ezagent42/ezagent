defmodule Ezagent.Ecto.URI do
  @moduledoc """
  Custom Ecto type for `%URI{}` ↔ string round-trip in SQLite columns.

  In-memory representation: `%URI{}` struct (per ARCHITECTURE §3.5 — Message
  identity fields are URI structs, type-rich). Storage: TEXT column (the
  `URI.to_string/1` form, e.g. `"entity://agent/team-alpha/cc_builder"`).

  ## Phase 2 v1_prototype usage

  - `Ezagent.Message.sender` / `mentions` / `ref` use this type via
    `field :sender, Ezagent.Ecto.URI`
  - `body` map's nested URI values are NOT auto-converted (body is `:map`
    column — JSON-encoded by ecto_sqlite3); callers handle URI ↔ string in
    application code for body internals if needed

  ## Phase 5+ extension

  Same type used wherever a typed URI field hits SQLite. Phase 3+ adds
  RoutingRegistry tables that store URIs — they use this type.
  """

  use Ecto.Type

  @impl true
  def type, do: :string

  # Cast: input → in-memory %URI{} (used by Ecto.Changeset.cast/3).
  @impl true
  def cast(%URI{} = uri), do: {:ok, uri}

  def cast(s) when is_binary(s) do
    case URI.new(s) do
      {:ok, uri} -> {:ok, uri}
      {:error, _} -> :error
    end
  end

  def cast(_), do: :error

  # Load: DB string → %URI{} (used when reading rows back).
  @impl true
  def load(s) when is_binary(s) do
    case URI.new(s) do
      {:ok, uri} -> {:ok, uri}
      {:error, _} -> :error
    end
  end

  def load(_), do: :error

  # Dump: %URI{} → DB string (used when persisting).
  @impl true
  def dump(%URI{} = uri), do: {:ok, URI.to_string(uri)}
  def dump(s) when is_binary(s), do: {:ok, s}
  def dump(_), do: :error
end
