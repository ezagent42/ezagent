defmodule Ezagent.Behavior.Surface do
  @moduledoc """
  Immutable socialware page surface.

  Owns the `:surface` slice. Operators read the latest retained version;
  customers read only the version pointed to by `:approved`.
  """

  # lifecycle:state_slice_override
  use Ezagent.Lifecycle, state_slice: :surface

  action(:put_version,
    args: %{turn_id: :string, tree: :map},
    returns: %{version: :integer},
    caps: [:put_version],
    modes: [:call],
    description: "Append an immutable page tree version"
  )

  action(:approve,
    args: %{version: :integer},
    returns: %{approved: :integer},
    caps: [:approve],
    modes: [:call],
    description: "Advance the approved page pointer"
  )

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{versions: %{}, approved: nil, version_seq: 0}}

  @impl Ezagent.Lifecycle
  def activate(_state, _ctx), do: {:ok, %{}}

  @spec data_owner(URI.t() | :any | term()) :: URI.t() | :any | :no_owner
  def data_owner(%URI{scheme: "session"} = session_uri) do
    Ezagent.Behavior.Chat.data_owner(session_uri)
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  @spec handle_put_version(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_put_version(%{turn_id: turn_id, tree: tree}, ctx) do
    version = ctx.read.(:version_seq, 0) + 1
    versions = ctx.read.(:versions, %{})

    if Map.has_key?(versions, version) do
      {:error, {:version_exists, version}}
    else
      entry = %{tree: tree, by_turn: turn_id}

      {:ok, %{version: version},
       [
         {:set, :versions, Map.put(versions, version, entry)},
         {:set, :version_seq, version}
       ]}
    end
  end

  @spec handle_approve(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_approve(%{version: version}, ctx) do
    versions = ctx.read.(:versions, %{})

    if Map.has_key?(versions, version) do
      {:ok, %{approved: version}, [{:set, :approved, version}]}
    else
      {:error, :no_such_version}
    end
  end

  @spec operator_tree(map()) :: map() | nil
  def operator_tree(surface) when is_map(surface) do
    surface
    |> latest_version()
    |> version_tree(surface)
  end

  @spec customer_tree(map()) :: map() | nil
  def customer_tree(%{approved: nil}), do: nil

  def customer_tree(%{approved: version} = surface) do
    version_tree(version, surface)
  end

  def customer_tree(_surface), do: nil

  @spec latest_version(map()) :: integer() | nil
  def latest_version(%{versions: versions}) when map_size(versions) == 0, do: nil

  def latest_version(%{versions: versions}) do
    versions
    |> Map.keys()
    |> Enum.max()
  end

  def latest_version(_surface), do: nil

  defp version_tree(nil, _surface), do: nil

  defp version_tree(version, %{versions: versions}) do
    case Map.fetch(versions, version) do
      {:ok, %{tree: tree}} -> tree
      :error -> nil
    end
  end
end
