defmodule Ezagent.ProviderConnection.Test.FakeDriverBeta do
  @moduledoc false

  @behaviour Ezagent.ProviderConnection.Driver
  @journal :task6_fake_driver_beta_reconciliation

  def reset do
    ensure_journal()
    :ets.delete_all_objects(@journal)
    :ok
  end

  def declaration_metadata(extra \\ %{}) do
    Map.merge(extra, %{
      authorization_redirect_schema: %{
        type: :map,
        fields: %{
          "authorization_uri" => %{type: :string},
          "state" => %{type: :string},
          "pkce_digest" => %{type: :string}
        }
      },
      provider_metadata_schema: %{
        type: :map,
        fields: %{"class" => %{type: :string}}
      }
    })
  end

  @impl true
  def begin_authorization(context),
    do: {:ok, %{flow: "device", context: context}}

  @impl true
  def consume_callback(%{exchange: exchange} = context) when is_function(exchange, 1) do
    exchange.(fn private_frame ->
      result =
        {:ok,
         %{
           external_account_id: "beta-member",
           display_login: "beta",
           execution_identity: %{kind: :connected_user, external_account_id: "beta-member"},
           credential_material: "BETA_REMOTE_CREDENTIAL",
           granted_permissions_digest: "beta-permissions",
           provider_metadata: %{"class" => "beta"}
         }}

      remember_remote(context, private_frame, result)
    end)
  end

  def consume_callback(context),
    do:
      {:ok,
       %{
         external_account: %{tenant: "beta-tenant", member: "beta-member"},
         metadata: %{class: "beta"},
         context: context
       }}

  @impl true
  def reconcile_callback(%{exchange: exchange} = context) when is_function(exchange, 1) do
    with {:ok, _identity} <- reconciliation_identity(context) do
      exchange.(fn private_frame -> remote_lookup(context, private_frame) end)
    end
  end

  def reconcile_callback(_context), do: {:error, :provider_protocol_error}

  @impl true
  def refresh(context),
    do: {:ok, %{refresh: %{rotation: "conditional", generations: 2}, context: context}}

  @impl true
  def revoke(context),
    do: {:ok, %{revocation: %{mode: "credential-first", receipts: true}, context: context}}

  defp remember_remote(context, private_frame, result) do
    ensure_journal()
    correlation_id = context.correlation_id
    digest = remote_digest(context, private_frame)

    case :ets.insert_new(@journal, {correlation_id, digest, result}) do
      true -> result
      false -> remote_lookup(context, private_frame)
    end
  end

  defp remote_lookup(context, private_frame) do
    ensure_journal()
    correlation_id = context.correlation_id
    digest = remote_digest(context, private_frame)

    case :ets.lookup(@journal, correlation_id) do
      [{^correlation_id, ^digest, result}] -> result
      [{^correlation_id, _other, _result}] -> {:error, :provider_protocol_error}
      [] -> {:ok, :not_completed}
    end
  end

  defp remote_digest(context, private_frame) do
    identity =
      case reconciliation_identity(context) do
        {:ok, identity} -> identity
        {:error, :provider_protocol_error} -> :legacy
      end

    {identity, private_frame}
    |> stringify_remote_keys()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp stringify_remote_keys(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify_remote_keys(item)} end)

  defp stringify_remote_keys(value) when is_list(value),
    do: Enum.map(value, &stringify_remote_keys/1)

  defp stringify_remote_keys(value), do: value

  defp reconciliation_identity(context) do
    identity =
      Map.take(context, [
        :backend_pair_id,
        :operation_class,
        :correlation_id,
        :attempt_ref,
        :connection_generation,
        :credential_generation,
        :command_digest
      ])

    if map_size(identity) == 7 and
         Enum.all?(
           [
             identity.backend_pair_id,
             identity.operation_class,
             identity.correlation_id,
             identity.attempt_ref,
             identity.command_digest
           ],
           &(is_binary(&1) and &1 != "")
         ) and
         Enum.all?(
           [
             identity.connection_generation,
             identity.credential_generation
           ],
           &is_integer/1
         ) do
      {:ok, identity}
    else
      {:error, :provider_protocol_error}
    end
  end

  defp ensure_journal do
    case :ets.whereis(@journal) do
      :undefined ->
        try do
          :ets.new(@journal, [:named_table, :public, :set])
        rescue
          ArgumentError -> @journal
        end

      tid ->
        tid
    end
  end
end
