defmodule Ezagent.Message.ActionableErrorIssue do
  @moduledoc """
  Durable Layer 3 registration for actionable errors without a repair path.

  The numeric primary key is the user-facing registration number. Each row
  keeps the minimum incident context required by the G5 contract.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias EzagentCore.Repo

  schema "actionable_error_issues" do
    field :message_id, :string
    field :code, :string
    field :workspace_uri, :string
    field :agent_uri, :string
    field :session_uri, :string
    field :detail, :string
    field :occurred_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{
          id: integer() | nil,
          message_id: String.t() | nil,
          code: String.t() | nil,
          workspace_uri: String.t() | nil,
          agent_uri: String.t() | nil,
          session_uri: String.t() | nil,
          detail: String.t() | nil,
          occurred_at: DateTime.t() | nil
        }

  @required ~w(message_id code workspace_uri agent_uri occurred_at)a
  @optional ~w(session_uri detail)a

  @doc "Register one unclassified failure and notify the system operator."
  @spec register(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def register(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_uri(:workspace_uri)
      |> stringify_uri(:agent_uri)
      |> stringify_uri(:session_uri)
      |> Map.put_new(:occurred_at, DateTime.utc_now())

    changeset =
      %__MODULE__{}
      |> cast(attrs, @required ++ @optional)
      |> validate_required(@required)
      |> validate_format(:code, ~r/^[a-z0-9._-]+$/)
      |> unique_constraint(:message_id)

    case Repo.insert(changeset) do
      {:ok, issue} ->
        notify_operator(issue)
        {:ok, issue}

      {:error, %Ecto.Changeset{}} = error ->
        case by_message_id(Map.get(attrs, :message_id)) do
          %__MODULE__{} = issue -> {:ok, issue}
          nil -> error
        end
    end
  end

  @doc "Format the stable user-facing registration number."
  @spec ticket(t()) :: String.t()
  def ticket(%__MODULE__{id: id}) when is_integer(id), do: "##{id}"
  @doc "Look up the registration created for a persisted message."
  @spec by_message_id(String.t()) :: t() | nil
  def by_message_id(message_id) when is_binary(message_id) do
    Repo.get_by(__MODULE__, message_id: message_id)
  end

  defp notify_operator(issue) do
    Ezagent.Notifications.notify(Ezagent.URI.user("system", "admin"), %{
      type: :actionable_error_issue_registered,
      body: %{
        text: "系统已登记 Agent 未识别错误 #{ticket(issue)}",
        ticket: ticket(issue),
        error_code: issue.code,
        workspace_uri: issue.workspace_uri,
        agent_uri: issue.agent_uri,
        session_uri: issue.session_uri,
        occurred_at: DateTime.to_iso8601(issue.occurred_at)
      },
      source: __MODULE__,
      dedup_key: "actionable-error-issue:#{issue.id}"
    })
  end

  defp stringify_uri(attrs, key) do
    case Map.get(attrs, key) do
      %URI{} = uri -> Map.put(attrs, key, URI.to_string(uri))
      _ -> attrs
    end
  end
end
