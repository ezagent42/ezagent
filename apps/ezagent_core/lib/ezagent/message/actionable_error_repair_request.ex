defmodule Ezagent.Message.ActionableErrorRepairRequest do
  @moduledoc """
  Durable handoff for Layer 2 actionable-error repair reminders.

  A request records who asked, who can repair, and the affected agent. When the
  real repair action succeeds, open requests are completed and the requesters
  receive a notification.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias EzagentCore.Repo

  schema "actionable_error_repair_requests" do
    field :message_id, :string
    field :workspace_uri, :string
    field :agent_uri, :string
    field :error_code, :string
    field :error_title, :string
    field :requested_by, :string
    field :assigned_to, :string
    field :repair_href, :string
    field :status, :string, default: "open"
    field :completed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: integer() | nil,
          message_id: String.t() | nil,
          workspace_uri: String.t() | nil,
          agent_uri: String.t() | nil,
          error_code: String.t() | nil,
          error_title: String.t() | nil,
          requested_by: String.t() | nil,
          assigned_to: String.t() | nil,
          repair_href: String.t() | nil,
          status: String.t() | nil,
          completed_at: DateTime.t() | nil
        }

  @required ~w(message_id workspace_uri agent_uri error_code error_title requested_by assigned_to repair_href)a

  @doc "Persist an idempotent open repair request."
  @spec request(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def request(attrs) when is_map(attrs) do
    attrs =
      Enum.reduce(
        [:workspace_uri, :agent_uri, :requested_by, :assigned_to],
        attrs,
        &stringify_uri(&2, &1)
      )

    changeset =
      %__MODULE__{}
      |> cast(attrs, @required)
      |> validate_required(@required)
      |> unique_constraint([:message_id, :requested_by],
        name: :actionable_error_repair_requests_message_requester_index
      )

    case Repo.insert(changeset) do
      {:ok, request} ->
        {:ok, request}

      {:error, %Ecto.Changeset{} = _changeset} = error ->
        case Repo.get_by(__MODULE__,
               message_id: Map.get(attrs, :message_id),
               requested_by: Map.get(attrs, :requested_by)
             ) do
          %__MODULE__{} = request -> {:ok, request}
          nil -> error
        end
    end
  end

  @doc "Complete every open request for an agent and notify each requester."
  @spec complete_for_agent(
          URI.t() | String.t(),
          URI.t() | String.t(),
          String.t() | nil
        ) :: {:ok, non_neg_integer()}
  def complete_for_agent(agent_uri, completed_by, completed_by_name \\ nil) do
    agent_uri = uri_string(agent_uri)
    completed_by = uri_string(completed_by)
    completed_by_name = completed_by_name || completed_by
    completed_at = DateTime.utc_now()

    requests =
      Repo.all(
        from request in __MODULE__,
          where: request.agent_uri == ^agent_uri and request.status == "open"
      )

    completed =
      Enum.flat_map(requests, fn request ->
        case request
             |> change(status: "completed", completed_at: completed_at)
             |> Repo.update() do
          {:ok, updated} ->
            notify_requester(updated, completed_by, completed_by_name)
            [updated]

          {:error, _changeset} ->
            []
        end
      end)

    {:ok, length(completed)}
  end

  @doc "List repair requests for an agent, newest first."
  @spec list_for_agent(URI.t() | String.t()) :: [t()]
  def list_for_agent(agent_uri) do
    agent_uri = uri_string(agent_uri)

    Repo.all(
      from request in __MODULE__,
        where: request.agent_uri == ^agent_uri,
        order_by: [desc: request.inserted_at]
    )
  end

  defp notify_requester(request, completed_by, completed_by_name) do
    Ezagent.Notifications.notify(request.requested_by, %{
      type: :agent_repair_completed,
      body: %{
        text: "#{completed_by_name} 已修复 #{request.error_title}",
        workspace_uri: request.workspace_uri,
        agent_uri: request.agent_uri,
        error_code: request.error_code,
        repaired_by: completed_by,
        repaired_by_name: completed_by_name,
        message_id: request.message_id
      },
      source: __MODULE__,
      dedup_key: "agent-repair-complete:#{request.id}"
    })
  end

  defp stringify_uri(attrs, key) do
    case Map.get(attrs, key) do
      %URI{} = uri -> Map.put(attrs, key, URI.to_string(uri))
      _ -> attrs
    end
  end

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(uri) when is_binary(uri), do: uri
end
