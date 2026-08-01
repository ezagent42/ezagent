defmodule Ezagent.Cap.DeliveryOutbox do
  @moduledoc """
  Durable retry boundary for issued `:absorb_cap` and authorized
  `:revoke_cap` delivery.

  Producers persist a versioned, allowlisted envelope before the first attempt.
  Retry invocations are always fire-and-forget casts with `reply: :ignore`, so
  ready-drain can safely run inside the target Kind's lifecycle process. A
  claim lease serializes ready-drain and periodic sweepers; the target Kind
  marks a row applied only after its handler and slice commit succeed.
  """

  require Logger

  import Ecto.Query

  alias Ezagent.{Capability, Invocation, Persistence}
  alias Ezagent.Cap.{Delivery, RevocationLedger}
  alias Ezagent.Cap.DeliveryOutbox.Envelope
  alias Ezagent.Cap.DeliveryOutbox.State
  alias Ezagent.Persistence.TransientRetry
  alias EzagentCore.Repo

  @default_retry_base_ms 1_000
  @default_retry_max_ms 60_000
  @default_lease_ms 30_000
  @default_batch_size 100
  @target_hint_table :ezagent_cap_delivery_targets

  @doc "ETS table used to avoid a DB query on ordinary Kind ready transitions."
  @spec table() :: atom()
  def table, do: @target_hint_table

  @doc "Whether an invocation is from a canonical capability-delivery producer."
  @spec eligible?(Invocation.t()) :: boolean()
  def eligible?(%Invocation{} = invocation) do
    not replay?(invocation) and Envelope.eligible?(invocation)
  end

  @doc "True only for an invocation replaying an existing durable row."
  @spec replay?(Invocation.t()) :: boolean()
  def replay?(%Invocation{ctx: %{cap_delivery_id: id, cap_delivery_claim_token: token}})
      when is_integer(id) and is_binary(token),
      do: true

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
    with {:ok, envelope} <- Envelope.encode(invocation),
         :ok <- enqueue_revocation_gate(envelope),
         {:ok, delivery, disposition} <- insert_or_reuse(invocation, envelope),
         :ok <- verify_reused_payload(delivery, envelope, disposition) do
      result = dispatch_accepted(delivery, disposition, invocation)

      case invocation.mode do
        :cast -> normalize_cast_acceptance(result)
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
    |> Enum.each(&safe_attempt/1)

    :ok
  end

  @doc "Retry due rows across all workspaces for the singleton sweeper."
  @spec sweep_due(pos_integer()) :: non_neg_integer()
  def sweep_due(limit \\ @default_batch_size) when is_integer(limit) and limit > 0 do
    now = DateTime.utc_now()

    deliveries =
      from(delivery in Delivery,
        where:
          delivery.status == :pending and delivery.next_retry_at <= ^now and
            (is_nil(delivery.lease_until) or delivery.lease_until <= ^now),
        order_by: [asc: delivery.next_retry_at, asc: delivery.id],
        limit: ^limit
      )
      |> Repo.all()

    Enum.each(deliveries, &safe_attempt/1)
    length(deliveries)
  end

  @doc "Atomically claim and attempt one pending delivery."
  @spec attempt(Delivery.t() | pos_integer()) :: term()
  def attempt(id) when is_integer(id) do
    case Repo.get(Delivery, id) do
      nil -> {:error, :delivery_not_found}
      delivery -> attempt(delivery)
    end
  end

  def attempt(%Delivery{status: :applied}), do: :ok
  def attempt(%Delivery{status: :dead}), do: {:error, :delivery_dead}

  def attempt(%Delivery{} = delivery) do
    do_attempt(delivery, nil)
  end

  @doc "Mark the current claim applied after handler and slice commit success."
  @spec mark_applied(pos_integer(), Invocation.t()) :: :ok | {:error, term()}
  def mark_applied(id, %Invocation{} = invocation) when is_integer(id) do
    case State.mark_applied(id, invocation) do
      {:ok, target_uri} ->
        maybe_forget_target(target_uri)
        :ok

      result ->
        result
    end
  end

  @doc "Record an asynchronous target handler or commit failure by delivery claim."
  @spec record_handler_failure(Invocation.t(), term()) :: :ok | {:error, term()}
  def record_handler_failure(%Invocation{} = invocation, reason) do
    with %{cap_delivery_id: id, cap_delivery_claim_token: token}
         when is_integer(id) and is_binary(token) <- invocation.ctx do
      handle_failure_result(State.fail(id, token, reason, &retry_delay_ms/1))
    else
      _ -> :ok
    end
  end

  @doc "Future synchronous-ACK policy seam. The current dispatch path ignores it."
  @spec require_sync_ack() :: [atom()]
  def require_sync_ack do
    config() |> Keyword.get(:require_sync_ack, [])
  end

  @doc """
  Return validated capabilities from pending `:absorb_cap` deliveries for one
  target.

  This is the core-owned read seam for temporary effective-capability views.
  A malformed pending envelope or failed durable read fails the whole operation
  closed; callers must not interpret an error as an empty pending set.
  """
  @spec list_pending_absorb_caps(URI.t() | String.t()) ::
          {:ok, [Capability.t()]} | {:error, term()}
  def list_pending_absorb_caps(target_uri) do
    target = target_uri |> to_uri() |> Ezagent.URI.instance()
    target_string = URI.to_string(target)

    with {:ok, workspace_uri} <- Persistence.workspace_uri_for(target) do
      Delivery
      |> Persistence.scope_by_workspace(workspace_uri)
      |> where(
        [delivery],
        delivery.target_uri == ^target_string and delivery.op == :absorb_cap and
          delivery.status == :pending
      )
      |> order_by([delivery], asc: delivery.id)
      |> Repo.all()
      |> decode_pending_absorbs()
    end
  rescue
    error ->
      Logger.error(
        "DeliveryOutbox.list_pending_absorb_caps failed for " <>
          "#{inspect(target_uri)}: #{Exception.message(error)}"
      )

      {:error, :pending_absorb_read_failed}
  catch
    kind, reason ->
      Logger.error(
        "DeliveryOutbox.list_pending_absorb_caps #{kind} for " <>
          "#{inspect(target_uri)}: #{inspect(reason)}"
      )

      {:error, :pending_absorb_read_failed}
  end

  @doc "Distinct holders named by pending absorb deliveries, for the fenced v2 cutover."
  @spec pending_absorb_target_uris_in_txn() :: [String.t()]
  def pending_absorb_target_uris_in_txn do
    from(delivery in Delivery,
      where: delivery.op == :absorb_cap and delivery.status == :pending,
      select: delivery.target_uri,
      distinct: true,
      order_by: [asc: delivery.target_uri]
    )
    |> Repo.all()
  end

  @doc "Delete all pending deliveries inside the fenced rebuild transaction."
  @spec clear_pending_in_txn() :: non_neg_integer()
  def clear_pending_in_txn do
    {count, _} =
      from(delivery in Delivery, where: delivery.status == :pending)
      |> Repo.delete_all()

    count
  end

  @doc "Delete pending deliveries for a revoked grant inside the caller's transaction."
  @spec cancel_pending_grant_in_txn(String.t(), String.t(), String.t()) :: :ok
  def cancel_pending_grant_in_txn(workspace_uri, target_uri, grant_id)
      when is_binary(workspace_uri) and is_binary(target_uri) and is_binary(grant_id) do
    from(delivery in Delivery,
      where:
        delivery.workspace_uri == ^workspace_uri and delivery.target_uri == ^target_uri and
          delivery.grant_id == ^grant_id and delivery.status == :pending and
          (delivery.op == :absorb_cap or is_nil(delivery.claim_token))
    )
    |> Repo.delete_all()

    :ok
  end

  @doc false
  @spec retry_base_ms() :: pos_integer()
  def retry_base_ms, do: Keyword.get(config(), :retry_base_ms, @default_retry_base_ms)

  @doc false
  @spec retry_max_ms() :: pos_integer()
  def retry_max_ms, do: Keyword.get(config(), :retry_max_ms, @default_retry_max_ms)

  @doc false
  @spec lease_ms() :: pos_integer()
  def lease_ms, do: Keyword.get(config(), :lease_ms, @default_lease_ms)

  defp dispatch_accepted(%Delivery{status: :applied}, :reused, _invocation), do: :ok

  defp dispatch_accepted(%Delivery{status: :dead}, :reused, _invocation),
    do: {:error, :delivery_dead}

  defp dispatch_accepted(delivery, :reused, _invocation), do: do_attempt(delivery, nil)
  defp dispatch_accepted(delivery, :reused_semantic, _invocation), do: do_attempt(delivery, nil)
  defp dispatch_accepted(delivery, :inserted, invocation), do: do_attempt(delivery, invocation)

  defp do_attempt(%Delivery{} = delivery, initial_invocation) do
    with :ok <- delivery_revocation_gate(delivery) do
      remember_target(delivery.target_uri)

      case State.claim(delivery.id, lease_ms()) do
        {:ok, claimed} -> dispatch_claimed(claimed, initial_invocation)
        {:error, :claimed_elsewhere} = error -> error
        {:error, :delivery_dead} = error -> error
        {:error, :delivery_applied} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  defp dispatch_claimed(%Delivery{} = claimed, initial_invocation) do
    case invocation_for_claim(claimed, initial_invocation) do
      {:ok, invocation} ->
        result = safe_dispatch(invocation)
        record_pre_delivery_result(claimed, result)
        result

      {:error, reason} ->
        _ =
          handle_failure_result(
            State.fail(claimed.id, claimed.claim_token, reason, fn _ -> 0 end)
          )

        {:error, reason}
    end
  end

  defp safe_dispatch(invocation) do
    Invocation.dispatch(invocation)
  rescue
    error -> {:error, {:dispatch_exception, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:dispatch_exit, reason}}
    kind, reason -> {:error, {:dispatch_throw, kind, reason}}
  end

  defp safe_attempt(delivery) do
    attempt(delivery)
  rescue
    error ->
      Logger.error(
        "cap delivery attempt crashed delivery_id=#{delivery.id}: #{Exception.message(error)}"
      )

      {:error, error}
  catch
    kind, reason ->
      Logger.error("cap delivery attempt #{kind} delivery_id=#{delivery.id}: #{inspect(reason)}")

      {:error, {kind, reason}}
  end

  defp record_pre_delivery_result(_claimed, result) when result in [:ok], do: :ok
  defp record_pre_delivery_result(_claimed, {:ok, _result}), do: :ok

  defp record_pre_delivery_result(claimed, {:error, reason}) do
    handle_failure_result(State.fail(claimed.id, claimed.claim_token, reason, &retry_delay_ms/1))
  end

  # A `:dead` row is a capability delivery permanently abandoned after
  # retry exhaustion — the capability never reached its target. This was
  # completely silent (just forget-the-target + `:ok`); it is now the first
  # emitter on the canonical operator seam so an operator can see it.
  # Ordering: the ETS-hint forget (bookkeeping) runs FIRST and always;
  # the operator emit is best-effort observability layered after it, so an
  # observability call can never skip or corrupt outbox state. The full
  # `reason`/`last_error` persists on the `:dead` DB row for deep
  # inspection — the live warning stays lean by design.
  defp handle_failure_result({:dead, target_uri}) do
    maybe_forget_target(target_uri)

    Ezagent.OperatorEvents.warn(
      :cap_delivery_outbox,
      "capability delivery permanently failed (dead) after retry exhaustion",
      %{target_uri: target_uri}
    )

    :ok
  end

  defp handle_failure_result(result), do: result

  defp invocation_for_claim(claimed, %Invocation{} = initial_invocation) do
    {:ok, attach_claim(initial_invocation, claimed)}
  end

  defp invocation_for_claim(claimed, nil) do
    with {:ok, envelope} <- Envelope.decode(claimed) do
      {:ok, Envelope.to_invocation(envelope, claimed)}
    end
  end

  defp decode_pending_absorbs(deliveries) do
    deliveries
    |> Enum.reduce_while({:ok, []}, fn delivery, {:ok, caps} ->
      case Envelope.decode(delivery) do
        {:ok, %{cap: %Capability{} = cap}} ->
          {:cont, {:ok, [cap | caps]}}

        {:error, reason} ->
          Logger.error(
            "DeliveryOutbox.list_pending_absorb_caps decode failed for " <>
              "delivery_id=#{delivery.id}: #{inspect(reason)}"
          )

          {:halt, {:error, {:invalid_pending_delivery, delivery.id, reason}}}
      end
    end)
    |> case do
      {:ok, caps} -> {:ok, Enum.reverse(caps)}
      {:error, _reason} = error -> error
    end
  end

  defp attach_claim(%Invocation{} = invocation, %Delivery{} = delivery) do
    %{
      invocation
      | ctx:
          invocation.ctx
          |> Map.put(:cap_delivery_id, delivery.id)
          |> Map.put(:cap_delivery_claim_token, delivery.claim_token)
    }
  end

  defp insert_or_reuse(invocation, envelope) do
    attrs = %{
      workspace_uri: Persistence.workspace_uri_for!(envelope.target_uri),
      target_uri: envelope.target_uri,
      op: envelope.op,
      payload: Envelope.canonical_binary(envelope),
      payload_version: Envelope.version(),
      payload_identity: Envelope.payload_identity(envelope.cap),
      semantic_identity: semantic_identity(envelope),
      grant_id: normalized_grant_id(envelope.cap),
      idempotency_key: Map.get(invocation.ctx, :idempotency_key),
      status: :pending,
      attempts: 0,
      next_retry_at: DateTime.utc_now()
    }

    changeset = Delivery.changeset(%Delivery{}, attrs)

    case find_idempotent(attrs) do
      %Delivery{} = delivery ->
        remember_target(delivery.target_uri)
        {:ok, delivery, :reused}

      nil ->
        case {attrs.semantic_identity, attrs.idempotency_key} do
          {nil, nil} -> insert_new(changeset)
          {nil, key} -> insert_idempotent(changeset, attrs, key)
          {_semantic_identity, _key} -> insert_semantic(changeset, attrs, 1)
        end
    end
  end

  defp insert_new(changeset) do
    case TransientRetry.with_retry(fn -> Repo.insert(changeset) end) do
      {:ok, delivery} ->
        remember_target(delivery.target_uri)
        {:ok, delivery, :inserted}

      {:error, _changeset} ->
        {:error, :durable_accept_failed}
    end
  end

  defp insert_idempotent(changeset, attrs, key) do
    result =
      TransientRetry.with_retry(fn ->
        Repo.insert(changeset,
          on_conflict: :nothing,
          conflict_target:
            {:unsafe_fragment,
             "(workspace_uri, target_uri, op, idempotency_key) WHERE idempotency_key IS NOT NULL"}
        )
      end)

    case result do
      {:ok, %Delivery{id: id} = delivery} when is_integer(id) ->
        remember_target(delivery.target_uri)
        {:ok, delivery, :inserted}

      {:ok, %Delivery{id: nil}} ->
        delivery =
          Repo.one!(
            from(delivery in Delivery,
              where:
                delivery.workspace_uri == ^attrs.workspace_uri and
                  delivery.target_uri == ^attrs.target_uri and delivery.op == ^attrs.op and
                  delivery.idempotency_key == ^key
            )
          )

        remember_target(delivery.target_uri)
        {:ok, delivery, :reused}

      {:error, _changeset} ->
        {:error, :durable_accept_failed}
    end
  end

  defp insert_semantic(changeset, attrs, retries_left) do
    result =
      TransientRetry.with_retry(fn ->
        Repo.insert(changeset,
          on_conflict: :nothing,
          conflict_target:
            {:unsafe_fragment,
             "(workspace_uri, target_uri, op, semantic_identity) " <>
               "WHERE status = 'pending' AND op = 'absorb_cap' " <>
               "AND semantic_identity IS NOT NULL"}
        )
      end)

    case result do
      {:ok, %Delivery{id: id} = delivery} when is_integer(id) ->
        remember_target(delivery.target_uri)
        {:ok, delivery, :inserted}

      {:ok, %Delivery{id: nil}} ->
        reuse_constrained(changeset, attrs, retries_left)

      {:error, changeset} ->
        if constraint_error?(changeset, "cap_delivery_outbox_idempotency_unique") do
          reuse_idempotent(attrs)
        else
          {:error, :durable_accept_failed}
        end
    end
  end

  defp reuse_constrained(changeset, attrs, retries_left) do
    case find_idempotent(attrs) do
      %Delivery{} = delivery ->
        remember_target(delivery.target_uri)
        {:ok, delivery, :reused}

      nil ->
        case find_pending_semantic(attrs) do
          %Delivery{} = delivery ->
            remember_target(delivery.target_uri)
            {:ok, delivery, :reused_semantic}

          nil when retries_left > 0 ->
            insert_semantic(changeset, attrs, retries_left - 1)

          nil ->
            {:error, :durable_accept_failed}
        end
    end
  end

  defp reuse_idempotent(attrs) do
    case find_idempotent(attrs) do
      %Delivery{} = delivery ->
        remember_target(delivery.target_uri)
        {:ok, delivery, :reused}

      nil ->
        {:error, :durable_accept_failed}
    end
  end

  defp find_idempotent(%{idempotency_key: nil}), do: nil

  defp find_idempotent(attrs) do
    Repo.one(
      from(delivery in Delivery,
        where:
          delivery.workspace_uri == ^attrs.workspace_uri and
            delivery.target_uri == ^attrs.target_uri and delivery.op == ^attrs.op and
            delivery.idempotency_key == ^attrs.idempotency_key
      )
    )
  end

  defp find_pending_semantic(attrs) do
    Repo.one(
      from(delivery in Delivery,
        where:
          delivery.workspace_uri == ^attrs.workspace_uri and
            delivery.target_uri == ^attrs.target_uri and delivery.op == ^attrs.op and
            delivery.semantic_identity == ^attrs.semantic_identity and
            delivery.status == :pending
      )
    )
  end

  defp constraint_error?(changeset, constraint_name) do
    Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
      to_string(metadata[:constraint_name]) == constraint_name
    end)
  end

  defp verify_reused_payload(_delivery, _envelope, :inserted), do: :ok

  defp verify_reused_payload(%Delivery{} = delivery, envelope, :reused) do
    if delivery.payload == Envelope.canonical_binary(envelope),
      do: :ok,
      else: {:error, :idempotency_conflict}
  end

  defp verify_reused_payload(%Delivery{} = delivery, envelope, :reused_semantic) do
    with {:ok, %{cap: %Capability{} = stored_cap}} <- Envelope.decode(delivery),
         true <- Capability.identity_key(stored_cap) == Capability.identity_key(envelope.cap),
         true <- stored_cap.key_id == envelope.cap.key_id,
         true <- normalized_grant_id(stored_cap) == normalized_grant_id(envelope.cap) do
      :ok
    else
      _ -> {:error, :idempotency_conflict}
    end
  end

  defp semantic_identity(%{producer: :identity_absorb, cap: %Capability{} = cap}),
    do: Envelope.semantic_identity(cap)

  defp semantic_identity(_envelope), do: nil

  defp normalize_cast_acceptance({:error, reason})
       when reason in [
              :idempotency_conflict,
              :invalid_delivery_envelope,
              :durable_accept_failed,
              :delivery_dead,
              :capability_revoked,
              :cap_revocation_ledger_unreadable,
              :invalid_capability_protocol
            ],
       do: {:error, reason}

  defp normalize_cast_acceptance(_result), do: :ok

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

  defp enqueue_revocation_gate(%{target_uri: target_uri, cap: %Capability{} = cap}) do
    target_uri
    |> Persistence.workspace_uri_for!()
    |> RevocationLedger.ensure_unrevoked([cap])
    |> normalize_revocation_gate()
  end

  defp delivery_revocation_gate(%Delivery{} = delivery) do
    case Envelope.decode(delivery) do
      {:ok, %{cap: %Capability{} = cap}} ->
        case delivery.workspace_uri
             |> RevocationLedger.ensure_unrevoked([cap])
             |> normalize_revocation_gate() do
          {:error, :capability_revoked} = error ->
            Repo.delete_all(from(row in Delivery, where: row.id == ^delivery.id))
            maybe_forget_target(delivery.target_uri)
            error

          result ->
            result
        end

      {:error, _reason} ->
        # Preserve the existing poison-envelope path: claim it, then classify it
        # dead with the durable decode error.
        :ok
    end
  end

  defp normalize_revocation_gate(:ok), do: :ok

  defp normalize_revocation_gate({:error, {:revoked_capability_grants, _grant_ids}}),
    do: {:error, :capability_revoked}

  defp normalize_revocation_gate({:error, reason}), do: {:error, reason}

  defp normalized_grant_id(%Capability{} = cap) do
    cap.grant_id
  end

  defp retry_delay_ms(attempts) do
    retry_base_ms()
    |> Kernel.*(Bitwise.bsl(1, min(max(attempts - 1, 0), 16)))
    |> min(retry_max_ms())
  end

  defp config, do: Application.get_env(:ezagent_core, __MODULE__, [])

  defp to_uri(%URI{} = uri), do: uri
  defp to_uri(uri) when is_binary(uri), do: Ezagent.URI.new!(uri)
end
