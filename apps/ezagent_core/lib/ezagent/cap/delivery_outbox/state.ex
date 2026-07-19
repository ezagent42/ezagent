defmodule Ezagent.Cap.DeliveryOutbox.State do
  @moduledoc false

  import Ecto.Query

  alias Ezagent.Invocation
  alias Ezagent.Cap.Delivery
  alias Ezagent.Cap.DeliveryOutbox.Envelope
  alias Ezagent.Persistence.TransientRetry
  alias EzagentCore.Repo

  @doc false
  @spec claim(pos_integer(), pos_integer()) :: {:ok, Delivery.t()} | {:error, atom()}
  def claim(delivery_id, lease_ms) do
    now = DateTime.utc_now()
    token = claim_token()
    lease_until = DateTime.add(now, lease_ms, :millisecond)

    case from(delivery in Delivery,
           where:
             delivery.id == ^delivery_id and delivery.status == :pending and
               (is_nil(delivery.lease_until) or delivery.lease_until <= ^now)
         )
         |> Repo.update_all(
           inc: [attempts: 1],
           set: [
             claim_token: token,
             lease_until: lease_until,
             next_retry_at: lease_until,
             last_error: nil,
             updated_at: now
           ]
         ) do
      {1, _} -> {:ok, Repo.get!(Delivery, delivery_id)}
      {0, _} -> claim_miss(delivery_id)
    end
  end

  @doc false
  @spec mark_applied(pos_integer(), Invocation.t()) ::
          {:ok, String.t()} | :ok | {:error, term()}
  def mark_applied(id, %Invocation{} = invocation) when is_integer(id) do
    with {:ok, claim_token} <- claim_token_from(invocation),
         {:ok, identity} <- Envelope.invocation_identity(invocation) do
      now = DateTime.utc_now()
      target_uri = invocation.target |> Ezagent.URI.instance() |> URI.to_string()
      op = Envelope.operation!(invocation)

      case TransientRetry.with_retry(fn ->
             from(delivery in Delivery,
               where:
                 delivery.id == ^id and delivery.target_uri == ^target_uri and
                   delivery.op == ^op and delivery.payload_identity == ^identity and
                   delivery.status == :pending and delivery.claim_token == ^claim_token
             )
             |> Repo.update_all(
               set: [
                 status: :applied,
                 applied_at: now,
                 last_error: nil,
                 claim_token: nil,
                 lease_until: nil,
                 updated_at: now
               ]
             )
           end) do
        {1, _} -> {:ok, target_uri}
        {0, _} -> applied_or_stale_claim(id, target_uri, op, identity)
      end
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc false
  @spec fail(pos_integer(), String.t(), term(), (non_neg_integer() -> non_neg_integer())) ::
          :ok | {:dead, String.t()} | {:error, :stale_claim}
  def fail(id, token, reason, retry_delay_fn) do
    case classify(reason) do
      :permanent -> mark_dead(id, token, reason)
      :transient -> release_for_retry(id, token, reason, retry_delay_fn)
    end
  end

  defp mark_dead(id, token, reason) do
    now = DateTime.utc_now()

    {count, _} =
      from(delivery in Delivery,
        where:
          delivery.id == ^id and delivery.status == :pending and
            delivery.claim_token == ^token
      )
      |> Repo.update_all(
        set: [
          status: :dead,
          dead_at: now,
          last_error: inspect(reason),
          claim_token: nil,
          lease_until: nil,
          updated_at: now
        ]
      )

    case {count, Repo.get(Delivery, id)} do
      {1, %Delivery{target_uri: target_uri}} -> {:dead, target_uri}
      _ -> :ok
    end
  end

  defp release_for_retry(id, token, reason, retry_delay_fn) do
    case Repo.get(Delivery, id) do
      %Delivery{status: :pending, claim_token: ^token, attempts: attempts} ->
        now = DateTime.utc_now()
        next_retry_at = DateTime.add(now, retry_delay_fn.(attempts), :millisecond)

        from(delivery in Delivery,
          where:
            delivery.id == ^id and delivery.status == :pending and
              delivery.claim_token == ^token
        )
        |> Repo.update_all(
          set: [
            next_retry_at: next_retry_at,
            last_error: inspect(reason),
            claim_token: nil,
            lease_until: nil,
            updated_at: now
          ]
        )

        :ok

      %Delivery{status: :pending} ->
        {:error, :stale_claim}

      _ ->
        :ok
    end
  end

  defp classify(reason)
       when reason in [
              :unauthorized,
              :missing_cap,
              :invalid_cap_signature,
              :presenter_required,
              :cross_workspace_denied,
              :invalid_cap_artifact,
              :cannot_revoke_admin,
              # task #180 — the absorb handler's tombstoned-recipient refusal.
              # Retrying can never succeed (delete is terminal), so the
              # delivery dead-letters instead of looping forever.
              :user_deleted
            ],
       do: :permanent

  defp classify({:invalid_args, _}), do: :permanent
  defp classify({:unknown_action, _}), do: :permanent
  defp classify({:delivery_decode, _}), do: :permanent
  defp classify({:invalid_delivery_envelope, _}), do: :permanent
  defp classify(_), do: :transient

  defp claim_miss(delivery_id) do
    case Repo.get(Delivery, delivery_id) do
      %Delivery{status: :applied} -> {:error, :delivery_applied}
      %Delivery{status: :dead} -> {:error, :delivery_dead}
      %Delivery{status: :pending} -> {:error, :claimed_elsewhere}
      nil -> {:error, :delivery_not_found}
    end
  end

  defp applied_or_stale_claim(id, target_uri, op, identity) do
    case Repo.get(Delivery, id) do
      %Delivery{
        target_uri: ^target_uri,
        op: ^op,
        payload_identity: ^identity,
        status: :applied
      } ->
        :ok

      %Delivery{status: :pending} ->
        {:error, :stale_claim}

      _ ->
        {:error, :delivery_mismatch}
    end
  end

  defp claim_token_from(%Invocation{ctx: %{cap_delivery_claim_token: token}})
       when is_binary(token),
       do: {:ok, token}

  defp claim_token_from(_), do: {:error, :missing_claim_token}

  defp claim_token do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
