defmodule Ezagent.Ecto.URI do
  @moduledoc """
  Custom Ecto type for `%URI{}` ↔ string round-trip in database columns.

  In-memory representation: `%URI{}` struct (per ARCHITECTURE §3.5 — Message
  identity fields are URI structs, type-rich). Storage: TEXT column (the
  `URI.to_string/1` form, e.g. `"entity://agent/team-alpha/cc_builder"`).

  ## Phase 2 v1_prototype usage

  - `Ezagent.Message.sender` / `mentions` / `ref` use this type via
    `field :sender, Ezagent.Ecto.URI`
  - `body` map's nested URI values are NOT auto-converted (body is a `:map`
    column — JSON-encoded by Ecto); callers handle URI ↔ string in
    application code for body internals if needed

  ## Phase 5+ extension

  Same type used wherever a typed URI field hits the database. Phase 3+ adds
  RoutingRegistry tables that store URIs — they use this type.
  """

  use Ecto.Type

  @impl true
  def type, do: :string

  # Cast: input → in-memory %URI{} (used by Ecto.Changeset.cast/3).
  #
  # SPEC 2026-05-27-uri-canonicalization §3.7 — Ezagent-scheme strings
  # route through `Ezagent.URI.new!/1` (the canonical chokepoint).
  # Non-Ezagent strings fall back to strict `URI.new/1` so external
  # URLs (e.g. http feishu webhook addresses) still load. The bare
  # `URI.new/1` calls below are the §5.2.1 allowlisted external-URI
  # fallback — see Appendix A.1 of the SPEC.
  @impl true
  def cast(%URI{} = uri), do: {:ok, uri}

  def cast(s) when is_binary(s) do
    try do
      {:ok, Ezagent.URI.new!(s)}
    rescue
      ArgumentError ->
        case URI.new(s) do
          {:ok, uri} -> {:ok, uri}
          {:error, _} -> :error
        end
    end
  end

  def cast(_), do: :error

  # Load: DB string → %URI{} (used when reading rows back).
  @impl true
  def load(s) when is_binary(s) do
    try do
      {:ok, Ezagent.URI.new!(s)}
    rescue
      ArgumentError ->
        case URI.new(s) do
          {:ok, uri} -> {:ok, uri}
          {:error, _} -> :error
        end
    end
  end

  def load(_), do: :error

  # Dump: %URI{} → DB string (used when persisting).
  @impl true
  def dump(%URI{} = uri), do: {:ok, URI.to_string(uri)}
  def dump(s) when is_binary(s), do: {:ok, s}
  def dump(_), do: :error
end
