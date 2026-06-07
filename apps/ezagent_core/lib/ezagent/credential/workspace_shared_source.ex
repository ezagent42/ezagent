defmodule Ezagent.Credential.WorkspaceSharedSource do
  @moduledoc """
  Workspace-shared credential source pointer per `(workspace, flavor)`.

  This is the read-side store for #17 PR-3 workspace-shared service-account
  fallback. It intentionally exposes no Repo writer: production writes must be added
  through a cap-checked workspace-admin Behavior, mirroring
  `Ezagent.Credential.UserDefaultSource`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias EzagentCore.Repo

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "workspace_shared_credential_sources" do
    field(:workspace_uri, :string)
    field(:flavor, :string)
    field(:source_uri, :string)
    field(:set_by, :string)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "Build the deterministic primary key for a `(workspace, flavor)` pair."
  @spec id(String.t(), String.t()) :: String.t()
  def id(workspace_uri, flavor), do: "#{workspace_uri}|#{flavor}"

  @doc "Pure changeset builder. Does not authorize or persist."
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(%{workspace_uri: workspace_uri, flavor: flavor} = attrs) do
    %__MODULE__{}
    |> cast(
      %{
        id: id(workspace_uri, flavor),
        workspace_uri: workspace_uri,
        flavor: flavor,
        source_uri: Map.get(attrs, :source_uri),
        set_by: Map.get(attrs, :set_by)
      },
      [:id, :workspace_uri, :flavor, :source_uri, :set_by]
    )
    |> validate_required([:id, :workspace_uri, :flavor, :source_uri, :set_by])
  end

  @doc "Resolve the shared source URI, or nil if unset."
  @spec resolve(String.t(), String.t()) :: String.t() | nil
  def resolve(workspace_uri, flavor) do
    case get(workspace_uri, flavor) do
      %__MODULE__{source_uri: source_uri} -> source_uri
      nil -> nil
    end
  end

  @doc "Fetch the shared source approval row, or nil if unset."
  @spec get(String.t(), String.t()) :: t() | nil
  def get(workspace_uri, flavor), do: Repo.get(__MODULE__, id(workspace_uri, flavor))
end
