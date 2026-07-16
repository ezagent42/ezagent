defmodule Ezagent.Workspace.ResponsibilityAssignment do
  @moduledoc """
  Durable workspace-level responsibility assignments.

  P9 introduces the named `supervisor` responsibility as a B2 pool: many current
  holders in a workspace may receive `{:role, "supervisor"}` fan-out and may
  drive takeover/review verbs. This module owns the durable assignment table and
  the cap bundle bound to assignment.
  """

  use Ecto.Schema

  import Ecto.Query

  alias Ezagent.Capability
  alias EzagentCore.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "workspace_responsibility_assignments" do
    field(:workspace_uri, :string)
    field(:responsibility, :string)
    field(:holder_uri, :string)
    field(:assigned_by, :string)
    field(:config, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @type decoded :: %{
          workspace_uri: URI.t(),
          responsibility: String.t(),
          holder_uri: URI.t(),
          assigned_by: URI.t() | nil,
          config: map()
        }

  @doc "Assign `holder_uri` to `responsibility` in `workspace_uri`."
  @spec assign(URI.t(), String.t(), URI.t(), URI.t() | nil, map()) ::
          {:ok, decoded()} | {:error, term()}
  def assign(
        %URI{} = workspace_uri,
        responsibility,
        %URI{} = holder_uri,
        assigned_by,
        config \\ %{}
      )
      when is_binary(responsibility) and is_map(config) do
    with :ok <- validate_workspace_holder(workspace_uri, holder_uri),
         :ok <- validate_responsibility(responsibility) do
      attrs = %{
        workspace_uri: URI.to_string(workspace_uri),
        responsibility: responsibility,
        holder_uri: URI.to_string(holder_uri),
        assigned_by: uri_string_or_nil(assigned_by),
        config: normalize_config(config)
      }

      %__MODULE__{}
      |> Ecto.Changeset.change(attrs)
      |> Ecto.Changeset.unique_constraint(
        [:workspace_uri, :responsibility, :holder_uri],
        name: :workspace_responsibility_assignments_unique_holder
      )
      |> Repo.insert(
        on_conflict: {:replace, [:assigned_by, :config, :updated_at]},
        conflict_target: [:workspace_uri, :responsibility, :holder_uri]
      )
      |> case do
        {:ok, row} -> {:ok, decode(row)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Remove one holder from a workspace responsibility."
  @spec unassign(URI.t(), String.t(), URI.t()) :: :ok | {:error, term()}
  def unassign(%URI{} = workspace_uri, responsibility, %URI{} = holder_uri)
      when is_binary(responsibility) do
    {_, _} =
      from(a in __MODULE__,
        where:
          a.workspace_uri == ^URI.to_string(workspace_uri) and
            a.responsibility == ^responsibility and
            a.holder_uri == ^URI.to_string(holder_uri)
      )
      |> Repo.delete_all()

    :ok
  end

  @doc "List current holders for a workspace responsibility."
  @spec holders(URI.t(), String.t()) :: [URI.t()]
  def holders(%URI{} = workspace_uri, responsibility) when is_binary(responsibility) do
    from(a in __MODULE__,
      where:
        a.workspace_uri == ^URI.to_string(workspace_uri) and
          a.responsibility == ^responsibility,
      order_by: [asc: a.inserted_at, asc: a.holder_uri],
      select: a.holder_uri
    )
    |> Repo.all()
    |> Enum.flat_map(&parse_uri/1)
  end

  @doc "Return true iff `holder_uri` is currently assigned."
  @spec assigned?(URI.t(), String.t(), URI.t()) :: boolean()
  def assigned?(%URI{} = workspace_uri, responsibility, %URI{} = holder_uri)
      when is_binary(responsibility) do
    from(a in __MODULE__,
      where:
        a.workspace_uri == ^URI.to_string(workspace_uri) and
          a.responsibility == ^responsibility and
          a.holder_uri == ^URI.to_string(holder_uri),
      select: count(a.id)
    )
    |> Repo.one()
    |> Kernel.>(0)
  end

  @doc "The P9 supervisor cap bundle signed by one concrete Session authority."
  @spec supervisor_caps_for_session(URI.t(), URI.t()) :: [Capability.t()]
  def supervisor_caps_for_session(%URI{} = session_uri, %URI{} = workspace_uri) do
    [
      cap(:session, Ezagent.ActionSet.Session, :read_unfiltered, session_uri, workspace_uri),
      cap(:session, Ezagent.ActionSet.Turn, :claim, session_uri, workspace_uri),
      cap(:session, Ezagent.ActionSet.Turn, :settle, session_uri, workspace_uri),
      cap(:session, Ezagent.ActionSet.Surface, :approve, session_uri, workspace_uri),
      cap(:session, Ezagent.ActionSet.Surface, :commit_settlement, session_uri, workspace_uri),
      cap(
        :session,
        Ezagent.ActionSet.SupervisorApproval,
        :submit_verdict,
        session_uri,
        workspace_uri
      )
    ]
  end

  @doc "Responsibilities whose assignment grants a standing cap bundle."
  @spec bundled_caps(String.t(), URI.t()) :: [Capability.t()]
  def bundled_caps("supervisor", %URI{} = _workspace_uri), do: []
  def bundled_caps(_responsibility, _workspace_uri), do: []

  defp cap(kind, behavior, action, session_uri, workspace_uri) do
    Capability.cap(kind, behavior, action, Ezagent.URI.instance(session_uri), workspace_uri)
  end

  defp validate_responsibility(""), do: {:error, :empty_responsibility}
  defp validate_responsibility(responsibility) when is_binary(responsibility), do: :ok
  defp validate_responsibility(_), do: {:error, :bad_responsibility}

  defp validate_workspace_holder(
         %URI{scheme: "workspace"} = workspace_uri,
         %URI{scheme: "entity"} = holder_uri
       ) do
    holder_ws = Capability.workspace_of(holder_uri)

    if same_uri?(workspace_uri, holder_ws) do
      :ok
    else
      {:error, :cross_workspace_holder}
    end
  end

  defp validate_workspace_holder(%URI{scheme: "workspace"}, _), do: {:error, :bad_holder_uri}
  defp validate_workspace_holder(_, _), do: {:error, :bad_workspace_uri}

  defp normalize_config(config) do
    config
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Map.new()
  end

  defp decode(%__MODULE__{} = row) do
    %{
      workspace_uri: Ezagent.URI.new!(row.workspace_uri),
      responsibility: row.responsibility,
      holder_uri: Ezagent.URI.new!(row.holder_uri),
      assigned_by: maybe_parse_uri(row.assigned_by),
      config: row.config || %{}
    }
  end

  defp parse_uri(str) when is_binary(str) do
    [Ezagent.URI.new!(str)]
  rescue
    _ -> []
  end

  defp maybe_parse_uri(nil), do: nil
  defp maybe_parse_uri(str), do: Ezagent.URI.new!(str)

  defp uri_string_or_nil(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string_or_nil(nil), do: nil

  defp same_uri?(%URI{} = a, %URI{} = b), do: URI.to_string(a) == URI.to_string(b)
end
