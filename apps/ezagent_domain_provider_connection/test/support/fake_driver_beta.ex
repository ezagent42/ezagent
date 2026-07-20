defmodule Ezagent.ProviderConnection.Test.FakeDriverBeta do
  @moduledoc false

  @behaviour Ezagent.ProviderConnection.Driver
  @journal :task6_fake_driver_beta_reconciliation

  def reset do
    ensure_journal()
    :ets.delete_all_objects(@journal)
    :ok
  end

  def provider_discard_effect_count do
    ensure_journal()
    :ets.select_count(@journal, [{{{:discard_effect, :_}, :_}, [], [true]}])
  end

  def whole_connection_revoke_count do
    ensure_journal()
    :ets.select_count(@journal, [{{{:whole_connection_revoke, :_}, :_}, [], [true]}])
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
           provider_result_ref: provider_result_ref(context, private_frame, "beta-member"),
           external_account_id: "beta-member",
           display_login: "beta",
           execution_identity: %{kind: :connected_user, external_account_id: "beta-member"},
           authorization_ref: context.authorization_ref,
           authorization_version: Map.get(context, :expected_authorization_version, 0) + 1,
           credential_material: "BETA_REMOTE_CREDENTIAL",
           granted_permissions_digest: "beta-permissions",
           expires_at: nil,
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
  def reconcile_refresh(_context), do: {:ok, :not_completed}

  @impl true
  def discard_callback_result(context), do: discard_result(:callback, context)

  @impl true
  def discard_refresh_result(context), do: discard_result(:refresh, context)

  @impl true
  def revoke(context) do
    ensure_journal()
    :ets.insert(@journal, {{:whole_connection_revoke, make_ref()}, context})
    {:ok, %{revocation: %{mode: "credential-first", receipts: true}, context: context}}
  end

  defp remember_remote(context, private_frame, result) do
    ensure_journal()
    correlation_id = context.correlation_id
    digest = remote_digest(context, private_frame)

    outcome =
      case :ets.insert_new(@journal, {correlation_id, digest, result}) do
        true -> result
        false -> remote_lookup(context, private_frame)
      end

    remember_provider_result(context, outcome)
    outcome
  end

  defp remember_provider_result(context, {:ok, result}) when is_map(result) do
    binding = Map.take(context, discard_binding_keys(:callback))
    :ets.insert(@journal, {{:provider_result, result.provider_result_ref}, binding})
  end

  defp remember_provider_result(_context, _result), do: :ok

  defp discard_result(kind, context) do
    ensure_journal()

    with :ok <- Ezagent.ProviderConnection.Driver.validate_discard_context(kind, context),
         [{{:provider_result, _ref}, expected}] <-
           :ets.lookup(@journal, {:provider_result, context.provider_result_ref}),
         true <- Map.take(context, discard_binding_keys(kind)) == expected do
      digest = :crypto.hash(:sha256, :erlang.term_to_binary(context, [:deterministic]))
      key = context.discard_idempotency_key

      case {:ets.lookup(@journal, {:discard, key}),
            :ets.lookup(@journal, {:discarded_result, context.provider_result_ref})} do
        {[{{:discard, ^key}, ^digest}], _result} ->
          :ok

        {[], []} ->
          :ets.insert(@journal, [
            {{:discard, key}, digest},
            {{:discarded_result, context.provider_result_ref}, key},
            {{:discard_effect, key}, context.provider_result_ref}
          ])

          :ok

        _conflict ->
          {:error, :correlation_conflict}
      end
    else
      _mismatch -> {:error, :correlation_conflict}
    end
  end

  defp discard_binding_keys(:callback) do
    ~w(owner_uri workspace_uri provider_id acquisition_method governed_host backend_pair_id operation_id connection_id expected_connection_version attempt_ref authorization_ref expected_authorization_version correlation_id command_digest expected_credential_version)a
  end

  defp discard_binding_keys(:refresh),
    do: List.delete(discard_binding_keys(:callback), :attempt_ref)

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

  defp provider_result_ref(context, private_frame, native_result_id) do
    {Map.drop(context, [:exchange]), Map.drop(private_frame, [:pkce_verifier]), native_result_id}
    |> stringify_remote_keys()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> then(&("beta-provider-result:" <> &1))
  end

  defp reconciliation_identity(context) do
    identity = Map.drop(context, [:exchange])

    expected =
      MapSet.new(
        ~w(owner_uri workspace_uri provider_id acquisition_method governed_host backend_pair_id operation_id connection_id attempt_ref authorization_ref expected_connection_version expected_authorization_version expected_credential_version correlation_id command_digest callback_envelope_digest)a
      )

    if MapSet.new(Map.keys(identity)) == expected do
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
