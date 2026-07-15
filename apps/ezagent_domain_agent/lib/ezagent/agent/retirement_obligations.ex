defmodule Ezagent.Agent.RetirementObligations do
  @moduledoc "Persistence boundary for recoverable Agent retirement cleanup."

  import Ecto.Query

  alias Ezagent.Agent.RetirementObligation
  alias EzagentCore.Repo

  @spec create_pending(map()) :: {:ok, RetirementObligation.t()} | {:error, Ecto.Changeset.t()}
  def create_pending(attrs) when is_map(attrs) do
    identity = Map.take(attrs, [:agent_uri, :creation_attempt_id, :retirement_reason])

    case Repo.get_by(RetirementObligation, identity) do
      %RetirementObligation{} = existing ->
        {:ok, existing}

      nil ->
        %RetirementObligation{}
        |> RetirementObligation.create_changeset(attrs)
        |> Repo.insert()
        |> recover_concurrent_insert(identity)
    end
  end

  @spec get(pos_integer()) :: RetirementObligation.t() | nil
  def get(id), do: Repo.get(RetirementObligation, id)

  @spec get!(pos_integer()) :: RetirementObligation.t()
  def get!(id), do: Repo.get!(RetirementObligation, id)

  @spec mark_running(pos_integer()) ::
          {:ok, RetirementObligation.t()} | {:error, Ecto.Changeset.t()}
  def mark_running(id) do
    obligation = get!(id)

    obligation
    |> RetirementObligation.transition_changeset(%{
      status: :running,
      attempts: obligation.attempts + 1,
      last_error: nil
    })
    |> Repo.update()
  end

  @spec record_failure(pos_integer(), term()) ::
          {:ok, RetirementObligation.t()} | {:error, Ecto.Changeset.t()}
  def record_failure(id, reason) do
    id
    |> get!()
    |> RetirementObligation.transition_changeset(%{
      status: :pending,
      last_error: inspect(reason),
      next_attempt_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  @spec update_pending_steps(pos_integer(), map()) ::
          {:ok, RetirementObligation.t()} | {:error, Ecto.Changeset.t()}
  def update_pending_steps(id, pending_steps) when is_map(pending_steps) do
    id
    |> get!()
    |> RetirementObligation.transition_changeset(%{pending_steps: pending_steps})
    |> Repo.update()
  end

  @spec resolve(pos_integer()) ::
          {:ok, RetirementObligation.t()} | {:error, Ecto.Changeset.t()}
  def resolve(id) do
    id
    |> get!()
    |> RetirementObligation.transition_changeset(%{
      status: :resolved,
      pending_steps: %{},
      last_error: nil,
      next_attempt_at: nil,
      resolved_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  @spec list_due(pos_integer()) :: [RetirementObligation.t()]
  def list_due(limit) when is_integer(limit) and limit > 0 do
    now = DateTime.utc_now()

    Repo.all(
      from(o in RetirementObligation,
        where: o.status == :pending,
        where: is_nil(o.next_attempt_at) or o.next_attempt_at <= ^now,
        order_by: [asc: o.inserted_at],
        limit: ^limit
      )
    )
  end

  defp recover_concurrent_insert({:ok, obligation}, _identity), do: {:ok, obligation}

  defp recover_concurrent_insert({:error, %Ecto.Changeset{} = changeset} = error, identity) do
    if changeset.errors[:agent_uri] do
      case Repo.get_by(RetirementObligation, identity) do
        %RetirementObligation{} = existing -> {:ok, existing}
        nil -> error
      end
    else
      error
    end
  end
end
