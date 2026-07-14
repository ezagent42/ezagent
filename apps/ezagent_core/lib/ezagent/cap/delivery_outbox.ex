defmodule Ezagent.Cap.DeliveryOutbox do
  @moduledoc """
  Durable retry boundary for `:absorb_cap` and `:revoke_cap` delivery.

  Every eligible invocation is inserted before its first dispatch attempt.
  Retried invocations carry an internal delivery id so they bypass both a
  second outbox insert and the bounded ETS `PendingDelivery` queue. A row is
  marked applied only by `Ezagent.Kind.Server`, after the target handler and
  slice commit succeed.

  `sweep_due/1` is intentionally a system-scope read across workspaces: the
  singleton retry worker must recover pending security operations for every
  tenant. Target-specific ready drains use `Persistence.scope_by_workspace/2`.
  """

  import Ecto.Query

  alias Ezagent.{Invocation, Persistence}
  alias Ezagent.Cap.Delivery
  alias Ezagent.Persistence.TransientRetry
  alias EzagentCore.Repo

  @delivery_actions [:absorb_cap, :revoke_cap]
  @default_retry_base_ms 1_000
  @default_retry_max_ms 60_000
  @default_batch_size 100
  @target_hint_table :ezagent_cap_delivery_targets

  @doc "ETS table used to avoid a DB query on ordinary Kind ready transitions."
  @spec table() :: atom()
  def table, do: @target_hint_table

  @doc "Whether an invocation must enter the durable capability outbox."
  @spec eligible?(Invocation.t()) :: boolean()
  def eligible?(%Invocation{ctx: ctx, target: target}) do
    is_nil(ctx[:cap_delivery_id]) and
      match?(
        {:ok, {_behavior, action}} when action in @delivery_actions,
        Ezagent.URI.behavior_action(target)
      )
  end

  @doc "True only for an invocation replaying an existing durable row."
  @spec replay?(Invocation.t()) :: boolean()
  def replay?(%Invocation{ctx: %{cap_delivery_id: id}}) when is_integer(id), do: true
  def replay?(%Invocation{}), do: false

  @doc "Whether this target has a pending durable row in the current BEAM."
  @spec pending_target?(URI.t() | String.t()) :: boolean()
  def pending_target?(target_uri) do
    target = target_uri |> to_uri() |> Ezagent.URI.instance() |> URI.to_string()
    :ets.member(@target_hint_table, target)
  rescue
    ArgumentError -> false
  end

  @doc "Rebuild ready-drain hints from durable pending rows at worker boot."
  @spec rehydrate_hints() :: :ok
  def rehydrate_hints do
    targets =
      from(delivery in Delivery,
        where: delivery.status == :pending,
        select: delivery.target_uri,
        distinct: true
      )
      |> Repo.all()

    :ets.delete_all_objects(@target_hint_table)
    Enum.each(targets, &remember_target/1)
    :ok
  end

  @doc "Persist an invocation and perform its first delivery attempt."
  @spec enqueue_and_attempt(Invocation.t()) :: term()
  def enqueue_and_attempt(%Invocation{} = invocation) do
    with {:ok, delivery} <- enqueue(invocation) do
      result = attempt(delivery)

      case invocation.mode do
        :cast -> :ok
        _ -> result
      end
    end
  end

  @doc "Retry all pending rows for one target after its ready transition."
  @spec drain_target(URI.t() | String.t()) :: :ok
  def drain_target(target_uri) do
    target = target_uri |> to_uri() |> Ezagent.URI.instance()
    target_string = URI.to_string(target)
    workspace_uri = Persistence.workspace_uri_for!(target)

    Delivery
    |> Persistence.scope_by_workspace(workspace_uri)
    |> where([delivery], delivery.target_uri == ^target_string and delivery.status == :pending)
    |> order_by([delivery], asc: delivery.id)
    |> Repo.all()
    |> Enum.each(&attempt/1)

    :ok
  end

  @doc "Retry due rows across all workspaces for the singleton sweeper."
  @spec sweep_due(pos_integer()) :: non_neg_integer()
  def sweep_due(limit \\ @default_batch_size) when is_integer(limit) and limit > 0 do
    now = DateTime.utc_now()

    deliveries =
      from(delivery in Delivery,
        where: delivery.status == :pending and delivery.next_retry_at <= ^now,
        order_by: [asc: delivery.next_retry_at, asc: delivery.id],
        limit: ^limit
      )
      |> Repo.all()

    Enum.each(deliveries, &attempt/1)
    length(deliveries)
  end

  @doc "Attempt one pending delivery. Producer `:ok` never means applied."
  @spec attempt(Delivery.t() | pos_integer()) :: term()
  def attempt(id) when is_integer(id), do: Delivery |> Repo.get!(id) |> attempt()

  def attempt(%Delivery{status: :applied}), do: :ok

  def attempt(%Delivery{} = delivery) do
    remember_target(delivery.target_uri)
    delivery = record_attempt(delivery)
    invocation = decode_invocation!(delivery.payload)
    replay = %{invocation | ctx: Map.put(invocation.ctx, :cap_delivery_id, delivery.id)}
    result = Invocation.dispatch(replay)
    record_attempt_result(delivery.id, result)
    result
  end

  @doc "Mark the matching delivery applied after target handler and slice commit success."
  @spec mark_applied(pos_integer(), Invocation.t()) :: :ok | {:error, term()}
  def mark_applied(id, %Invocation{} = invocation) when is_integer(id) do
    now = DateTime.utc_now()
    target_uri = invocation.target |> Ezagent.URI.instance() |> URI.to_string()
    op = operation!(invocation)
    identity = payload_identity(invocation)

    case TransientRetry.with_retry(fn ->
           from(delivery in Delivery,
             where:
               delivery.id == ^id and delivery.target_uri == ^target_uri and
                 delivery.op == ^op and delivery.payload_identity == ^identity and
                 delivery.status == :pending
           )
           |> Repo.update_all(
             set: [status: :applied, applied_at: now, last_error: nil, updated_at: now]
           )
         end) do
      {1, _} ->
        maybe_forget_target(target_uri)
        :ok

      {0, _} ->
        result = already_applied_or_mismatch(id, target_uri, op, identity)
        if result == :ok, do: maybe_forget_target(target_uri)
        result
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc "Future synchronous-ACK policy seam. The current dispatch path ignores it."
  @spec require_sync_ack() :: [atom()]
  def require_sync_ack do
    config() |> Keyword.get(:require_sync_ack, [])
  end

  @doc false
  @spec retry_base_ms() :: pos_integer()
  def retry_base_ms, do: Keyword.get(config(), :retry_base_ms, @default_retry_base_ms)

  @doc false
  @spec retry_max_ms() :: pos_integer()
  def retry_max_ms, do: Keyword.get(config(), :retry_max_ms, @default_retry_max_ms)

  defp enqueue(%Invocation{} = invocation) do
    target = Ezagent.URI.instance(invocation.target)
    op = operation!(invocation)
    payload = :erlang.term_to_binary(invocation)

    attrs = %{
      workspace_uri: Persistence.workspace_uri_for!(target),
      target_uri: URI.to_string(target),
      op: op,
      payload: payload,
      payload_identity: payload_identity(invocation),
      status: :pending,
      attempts: 0,
      next_retry_at: DateTime.utc_now()
    }

    changeset = Delivery.changeset(%Delivery{}, attrs)

    case TransientRetry.with_retry(fn -> Repo.insert(changeset) end) do
      {:ok, delivery} = ok ->
        remember_target(delivery.target_uri)
        ok

      {:error, _changeset} = error ->
        error
    end
  end

  defp record_attempt(%Delivery{} = delivery) do
    attempts = delivery.attempts + 1
    now = DateTime.utc_now()
    next_retry_at = DateTime.add(now, retry_delay_ms(attempts), :millisecond)

    changeset =
      Delivery.changeset(delivery, %{
        attempts: attempts,
        next_retry_at: next_retry_at,
        last_error: nil
      })

    {:ok, updated} = TransientRetry.with_retry(fn -> Repo.update(changeset) end)

    updated
  end

  defp record_attempt_result(_id, result) when result in [:ok], do: :ok
  defp record_attempt_result(_id, {:ok, _result}), do: :ok

  defp record_attempt_result(id, {:error, reason}) do
    now = DateTime.utc_now()

    from(delivery in Delivery,
      where: delivery.id == ^id and delivery.status == :pending
    )
    |> Repo.update_all(set: [last_error: inspect(reason), updated_at: now])

    :ok
  end

  defp already_applied_or_mismatch(id, target_uri, op, identity) do
    case Repo.get(Delivery, id) do
      %Delivery{
        target_uri: ^target_uri,
        op: ^op,
        payload_identity: ^identity,
        status: :applied
      } ->
        :ok

      _ ->
        {:error, :delivery_mismatch}
    end
  end

  defp maybe_forget_target(target_uri) do
    workspace_uri = Persistence.workspace_uri_for!(target_uri)

    pending? =
      Delivery
      |> Persistence.scope_by_workspace(workspace_uri)
      |> where([delivery], delivery.target_uri == ^target_uri and delivery.status == :pending)
      |> Repo.exists?()

    unless pending?, do: :ets.delete(@target_hint_table, target_uri)
    :ok
  end

  defp remember_target(target_uri) when is_binary(target_uri) do
    :ets.insert(@target_hint_table, {target_uri, true})
    :ok
  end

  defp operation!(invocation) do
    case Ezagent.URI.behavior_action(invocation.target) do
      {:ok, {_behavior, action}} when action in @delivery_actions -> action
    end
  end

  defp payload_identity(%Invocation{args: args}) do
    artifact = Map.get(args, :artifact) || Map.fetch!(args, :cap)

    :crypto.hash(:sha256, :erlang.term_to_binary(artifact))
    |> Base.encode16(case: :lower)
  end

  defp decode_invocation!(payload) when is_binary(payload) do
    case :erlang.binary_to_term(payload, [:safe]) do
      %Invocation{} = invocation -> invocation
    end
  end

  defp retry_delay_ms(attempts) do
    retry_base_ms()
    |> Kernel.*(Bitwise.bsl(1, min(attempts - 1, 16)))
    |> min(retry_max_ms())
  end

  defp config, do: Application.get_env(:ezagent_core, __MODULE__, [])

  defp to_uri(%URI{} = uri), do: uri
  defp to_uri(uri) when is_binary(uri), do: Ezagent.URI.new!(uri)
end
