defmodule Ezagent.Cap.DeliveryOutbox.Envelope do
  @moduledoc false

  alias Ezagent.{Capability, Invocation}
  alias Ezagent.Cap.Delivery

  @version 1
  @delivery_actions [:absorb_cap, :revoke_cap]
  @keys [
    :authorization_rule,
    :caller,
    :cap,
    :caps,
    :op,
    :producer,
    :target_uri,
    :version
  ]

  @doc false
  @spec version() :: pos_integer()
  def version, do: @version

  @doc false
  @spec eligible?(Invocation.t()) :: boolean()
  def eligible?(%Invocation{} = invocation) do
    match?({:ok, _}, producer_parts(invocation))
  end

  @doc false
  @spec encode(Invocation.t()) :: {:ok, map()} | {:error, :invalid_delivery_envelope}
  def encode(%Invocation{} = invocation) do
    with {:ok, {producer, op, cap}} <- producer_parts(invocation),
         {:ok, caller, caps, rule} <- allowlisted_context(invocation.ctx) do
      {:ok,
       %{
         version: @version,
         producer: producer,
         target_uri: invocation.target |> Ezagent.URI.instance() |> URI.to_string(),
         op: op,
         cap: cap,
         caller: caller,
         caps: caps,
         authorization_rule: rule
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
      caller: envelope.caller,
      caps: MapSet.new(envelope.caps),
      reply: :ignore,
      cap_delivery_producer: envelope.producer,
      cap_delivery_id: delivery.id,
      cap_delivery_claim_token: delivery.claim_token
    }

    ctx =
      if is_atom(envelope.authorization_rule) do
        Map.put(ctx, :authorization_rule, envelope.authorization_rule)
      else
        ctx
      end

    %Invocation{
      target:
        envelope.target_uri
        |> Ezagent.URI.new!()
        |> Ezagent.URI.with_action(:identity, envelope.op),
      mode: :cast,
      args: args,
      ctx: ctx
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
           cap_delivery_producer: :identity_revoke
         }
       }) do
    case Ezagent.URI.behavior_action(target) do
      {:ok, {:identity, :revoke_cap}} -> {:ok, {:identity_revoke, :revoke_cap, cap}}
      _ -> :error
    end
  end

  defp producer_parts(_), do: :error

  defp allowlisted_context(%{caller: caller, caps: %MapSet{} = caps} = ctx) do
    caps = MapSet.to_list(caps)
    rule = Map.get(ctx, :authorization_rule)

    if valid_caller?(caller) and Enum.all?(caps, &match?(%Capability{}, &1)) and
         (is_nil(rule) or is_atom(rule)) do
      {:ok, caller, caps, rule}
    else
      :error
    end
  end

  defp allowlisted_context(_), do: :error

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
           caps: caps,
           authorization_rule: rule
         },
         %Delivery{} = delivery
       )
       when producer in [:identity_absorb, :identity_revoke] and
              op in @delivery_actions and is_binary(target_uri) and is_list(caps) do
    expected_producer = if op == :absorb_cap, do: :identity_absorb, else: :identity_revoke

    if producer == expected_producer and target_uri == delivery.target_uri and
         op == delivery.op and delivery.payload_version == @version and
         payload_identity(cap) == delivery.payload_identity and valid_caller?(caller) and
         Enum.all?(caps, &match?(%Capability{}, &1)) and (is_nil(rule) or is_atom(rule)) do
      :ok
    else
      {:error, :field_mismatch}
    end
  end

  defp validate(_, _), do: {:error, :invalid_shape}
end
