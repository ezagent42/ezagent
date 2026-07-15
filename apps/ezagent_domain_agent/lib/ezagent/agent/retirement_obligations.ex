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

  @spec claim(pos_integer(), keyword()) ::
          {:ok, RetirementObligation.t() | :already_resolved} | {:error, term()}
  def claim(id, opts \\ []) when is_integer(id) and id > 0 do
    lease_seconds = Keyword.get(opts, :lease_seconds, 60)
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      obligation =
        Repo.one(
          from(o in RetirementObligation,
            where: o.id == ^id,
            lock: "FOR UPDATE"
          )
        )

      claim_locked(obligation, now, lease_seconds, Keyword.get(opts, :allow_failed, false))
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp claim_locked(nil, _now, _lease_seconds, _allow_failed), do: {:error, :not_found}

  defp claim_locked(
         %RetirementObligation{status: :resolved},
         _now,
         _lease_seconds,
         _allow_failed
       ),
       do: {:ok, :already_resolved}

  defp claim_locked(%RetirementObligation{status: :failed}, _now, _lease_seconds, false),
    do: {:error, :failed}

  defp claim_locked(%RetirementObligation{status: :failed} = obligation, now, seconds, true),
    do: claim_for_lease(obligation, now, seconds)

  defp claim_locked(
         %RetirementObligation{status: :running, next_attempt_at: lease} = obligation,
         now,
         seconds,
         _allow_failed
       )
       when not is_nil(lease) do
    if DateTime.compare(lease, now) == :gt,
      do: {:error, :already_claimed},
      else: claim_for_lease(obligation, now, seconds)
  end

  defp claim_locked(%RetirementObligation{} = obligation, now, lease_seconds, _allow_failed),
    do: claim_for_lease(obligation, now, lease_seconds)

  defp claim_for_lease(obligation, now, lease_seconds) do
    obligation
    |> RetirementObligation.transition_changeset(%{
      status: :running,
      attempts: obligation.attempts + 1,
      last_error: nil,
      next_attempt_at: DateTime.add(now, lease_seconds, :second)
    })
    |> Repo.update()
  end

  @spec record_failure(pos_integer(), term()) ::
          {:ok, RetirementObligation.t()} | {:error, Ecto.Changeset.t()}
  def record_failure(id, reason) do
    obligation = get!(id)
    max_attempts = Application.get_env(:ezagent_domain_agent, :retirement_max_attempts, 10)
    exhausted? = obligation.attempts >= max_attempts
    delay_seconds = min(Integer.pow(2, max(obligation.attempts - 1, 0)), 3_600)

    obligation
    |> RetirementObligation.transition_changeset(%{
      status: if(exhausted?, do: :failed, else: :pending),
      last_error: inspect(reason),
      next_attempt_at:
        if(exhausted?, do: nil, else: DateTime.add(DateTime.utc_now(), delay_seconds, :second))
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
        where: o.status == :pending or o.status == :running,
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
