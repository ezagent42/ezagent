defmodule Ezagent.ActionSet.Surface do
  @moduledoc """
  Immutable socialware page surface.

  Owns the `:surface` slice. Internal readers see the latest retained version;
  external readers see only the version pointed to by `:approved`.
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

  action(:commit_settlement,
    args: %{turn_id: :string},
    returns: %{status: :atom},
    caps: [:commit_settlement],
    modes: [:call],
    description: "Commit a prepared socialware settlement after the approved pointer advances"
  )

  action(:set_shell,
    args: %{html: :string, css: :string},
    returns: %{ok: :boolean},
    caps: [:set_shell],
    modes: [:call],
    description:
      "Store the (pre-sanitised) HTML site-frame + its compiled CSS for the customer page"
  )

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{versions: %{}, approved: nil, version_seq: 0}}

  @impl Ezagent.Lifecycle
  def activate(_state, _ctx), do: {:ok, %{}}

  @spec data_owner(URI.t() | :any | term()) :: URI.t() | :any | :no_owner
  def data_owner(%URI{scheme: "session"} = session_uri) do
    Ezagent.ActionSet.Session.data_owner(session_uri)
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

  @doc """
  Surface action that stores the (already-sanitised) site shell: sets the
  `:shell` (HTML frame) and `:shell_css` slice keys. Requires a binary `html`;
  returns `{:error, :invalid_shell}` otherwise.
  """
  @spec handle_set_shell(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_set_shell(%{html: html} = args, _ctx) when is_binary(html) do
    css = Map.get(args, :css, "")
    {:ok, %{ok: true}, [{:set, :shell, html}, {:set, :shell_css, css}]}
  end

  def handle_set_shell(_args, _ctx), do: {:error, :invalid_shell}

  @spec handle_approve(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_approve(%{version: version}, ctx) do
    with :ok <- authorize_content_actor(ctx) do
      versions = ctx.read.(:versions, %{})

      if Map.has_key?(versions, version) do
        {:ok, %{approved: version}, [{:set, :approved, version}]}
      else
        {:error, :no_such_version}
      end
    end
  end

  @spec handle_commit_settlement(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_commit_settlement(%{turn_id: turn_id}, ctx) do
    with :ok <- authorize_content_actor(ctx) do
      approved = ctx.read.(:approved, nil)

      case Ezagent.Socialware.Settlement.commit_after_pointer(turn_id, approved) do
        {:ok, %{status: :committed}} ->
          {:ok, %{status: :committed}, []}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp authorize_content_actor(ctx) do
    holder = Map.get(ctx, :authenticated_principal)
    session_uri = Map.get(ctx, :self_uri)

    if same_uri?(holder, session_uri) do
      :ok
    else
      Ezagent.Session.Membership.authorize(%{}, holder, session_uri, holder)
    end
  end

  defp same_uri?(%URI{} = left, %URI{} = right) do
    Ezagent.URI.stable_key(left) == Ezagent.URI.stable_key(right)
  end

  defp same_uri?(_, _), do: false

  @spec internal_tree(map()) :: map() | nil
  def internal_tree(surface) when is_map(surface) do
    surface
    |> latest_version()
    |> version_tree(surface)
  end

  @spec external_tree(map()) :: map() | nil
  def external_tree(%{approved: nil}), do: nil

  def external_tree(%{approved: version} = surface) do
    version_tree(version, surface)
  end

  def external_tree(_surface), do: nil

  @doc """
  P2.5a — render a SPECIFIC version's tree, independent of the live `approved`
  pointer. The committed customer page is rendered from the version recorded on
  the committed settlement (NOT `surface.approved`, which may have advanced past
  the last committed delivery). Returns `nil` for a missing/nil version.
  """
  @spec tree_for_version(map(), integer() | nil) :: map() | nil
  def tree_for_version(_surface, nil), do: nil

  def tree_for_version(%{versions: versions}, version) when is_map(versions) do
    case Map.fetch(versions, version) do
      {:ok, %{tree: tree}} -> tree
      _ -> nil
    end
  end

  def tree_for_version(_surface, _version), do: nil

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
