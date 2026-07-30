defmodule Ezagent.Cap.DeliveryOutbox.Envelope do
  @moduledoc false

  alias Ezagent.{Capability, Invocation}
  alias Ezagent.Cap.Delivery

  @version 4
  @delivery_actions [:absorb_cap, :revoke_cap]
  @keys [
    :caller,
    :authenticated_principal,
    :cap,
    :caps,
    :op,
    :presenter,
    :producer,
    :target_uri,
    :version
  ]

  @doc false
  @spec version() :: pos_integer()
  def version, do: @version

  @doc false
  @spec canonical_binary(map()) :: binary()
  def canonical_binary(envelope), do: :erlang.term_to_binary(envelope, [:deterministic])

  @doc false
  @spec eligible?(Invocation.t()) :: boolean()
  def eligible?(%Invocation{} = invocation) do
    match?({:ok, _}, producer_parts(invocation))
  end

  @doc false
  @spec encode(Invocation.t()) :: {:ok, map()} | {:error, :invalid_delivery_envelope}
  def encode(%Invocation{} = invocation) do
    with {:ok, {producer, op, cap}} <- producer_parts(invocation),
         {:ok, caller, holder, caps} <- allowlisted_context(invocation.ctx, invocation.target) do
      {:ok,
       %{
         version: @version,
         producer: producer,
         target_uri: invocation.target |> Ezagent.URI.instance() |> URI.to_string(),
         op: op,
         cap: cap,
         caller: caller,
         authenticated_principal: holder,
         presenter: caller,
         caps: caps
       }}
    else
      _ -> {:error, :invalid_delivery_envelope}
    end
  end

  @doc false
  @spec decode(Delivery.t()) :: {:ok, map()} | {:error, {:delivery_decode, term()}}
  def decode(%Delivery{} = delivery) do
    with {:ok, envelope} <- safe_binary_to_term(delivery.payload),
         :ok <- validate_keys(envelope),
         :ok <- validate(envelope, delivery) do
      {:ok, envelope}
    else
      {:error, reason} -> {:error, {:delivery_decode, reason}}
    end
  end

  @doc false
  @spec to_invocation(map(), Delivery.t()) :: Invocation.t()
  def to_invocation(envelope, %Delivery{} = delivery) do
    args =
      case envelope.op do
        :absorb_cap -> %{artifact: envelope.cap}
        :revoke_cap -> %{cap: envelope.cap}
      end

    ctx = %{
      caller: envelope.presenter,
      authenticated_principal: envelope.authenticated_principal,
      caps: MapSet.new(envelope.caps),
      reply: :ignore,
      cap_delivery_producer: envelope.producer,
      cap_delivery_id: delivery.id,
      cap_delivery_claim_token: delivery.claim_token
    }

    %Invocation{
      target:
        envelope.target_uri
        |> Ezagent.URI.new!()
        |> Ezagent.URI.with_action(:identity, envelope.op),
      mode: :cast,
      args: args,
      ctx: ctx,
      origin: :trusted_internal
    }
  end

  @doc false
  @spec invocation_identity(Invocation.t()) ::
          {:ok, String.t()} | {:error, :invalid_delivery_envelope}
  def invocation_identity(%Invocation{args: args}) do
    case Map.get(args, :artifact) || Map.get(args, :cap) do
      %Capability{} = cap -> {:ok, payload_identity(cap)}
      _ -> {:error, :invalid_delivery_envelope}
    end
  end

  @doc false
  @spec operation!(Invocation.t()) :: :absorb_cap | :revoke_cap
  def operation!(%Invocation{} = invocation) do
    case Ezagent.URI.behavior_action(invocation.target) do
      {:ok, {:identity, action}} when action in @delivery_actions -> action
    end
  end

  @doc false
  @spec payload_identity(Capability.t()) :: String.t()
  def payload_identity(%Capability{} = cap) do
    :crypto.hash(:sha256, :erlang.term_to_binary(cap))
    |> Base.encode16(case: :lower)
  end

  @doc false
  @spec semantic_identity(Capability.t()) :: String.t()
  def semantic_identity(%Capability{} = cap) do
    digest =
      {Capability.identity_key(cap), cap.key_id}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "cap-v2:#{digest}"
  end

  defp producer_parts(%Invocation{
         target: target,
         args: %{artifact: %Capability{} = cap},
         ctx: %{caller: :vm_internal, cap_delivery_producer: :identity_absorb}
       }) do
    case Ezagent.URI.behavior_action(target) do
      {:ok, {:identity, :absorb_cap}} -> {:ok, {:identity_absorb, :absorb_cap, cap}}
      _ -> :error
    end
  end

  defp producer_parts(%Invocation{
         target: target,
         args: %{cap: %Capability{} = cap},
         ctx: %{
           caller: %URI{scheme: "entity"},
           authenticated_principal: %URI{scheme: "entity"},
           cap_delivery_producer: :identity_revoke
         }
       }) do
    case Ezagent.URI.behavior_action(target) do
      {:ok, {:identity, :revoke_cap}} -> {:ok, {:identity_revoke, :revoke_cap, cap}}
      _ -> :error
    end
  end

  defp producer_parts(_), do: :error

  defp allowlisted_context(%{caller: :vm_internal, caps: %MapSet{} = caps}, target) do
    validate_context(:vm_internal, Ezagent.URI.instance(target), caps)
  end

  defp allowlisted_context(
         %{
           caller: %URI{} = caller,
           authenticated_principal: %URI{} = holder,
           caps: %MapSet{} = caps
         },
         _target
       ) do
    validate_context(caller, holder, caps)
  end

  defp allowlisted_context(_, _target), do: :error

  defp validate_context(caller, holder, caps) do
    caps =
      caps
      |> MapSet.to_list()
      |> Enum.sort_by(&:erlang.term_to_binary(&1, [:deterministic]))

    if valid_caller?(caller) and match?(%URI{}, holder) and
         Enum.all?(caps, &match?(%Capability{}, &1)) do
      {:ok, caller, holder, caps}
    else
      :error
    end
  end

  defp valid_caller?(:vm_internal), do: true
  defp valid_caller?(%URI{scheme: "entity"}), do: true
  defp valid_caller?(_), do: false

  defp safe_binary_to_term(payload) when is_binary(payload) do
    {:ok, :erlang.binary_to_term(payload, [:safe])}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp validate_keys(envelope) when is_map(envelope) do
    if Enum.sort(Map.keys(envelope)) == Enum.sort(@keys),
      do: :ok,
      else: {:error, :unexpected_keys}
  end

  defp validate_keys(_), do: {:error, :not_a_map}

  defp validate(
         %{
           version: @version,
           producer: producer,
           target_uri: target_uri,
           op: op,
           cap: %Capability{} = cap,
           caller: caller,
           authenticated_principal: authenticated_principal,
           presenter: presenter,
           caps: caps
         },
         %Delivery{} = delivery
       )
       when producer in [:identity_absorb, :identity_revoke] and
              op in @delivery_actions and is_binary(target_uri) and is_list(caps) do
    expected_producer = if op == :absorb_cap, do: :identity_absorb, else: :identity_revoke

    if producer == expected_producer and target_uri == delivery.target_uri and
         op == delivery.op and delivery.payload_version == @version and
         payload_identity(cap) == delivery.payload_identity and caller == presenter and
         valid_caller?(presenter) and match?(%URI{}, authenticated_principal) and
         Enum.all?(caps, &match?(%Capability{}, &1)) do
      :ok
    else
      {:error, :field_mismatch}
    end
  end

  defp validate(_, _), do: {:error, :invalid_shape}
end
