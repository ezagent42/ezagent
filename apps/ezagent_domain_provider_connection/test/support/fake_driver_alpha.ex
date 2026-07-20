defmodule Ezagent.ProviderConnection.Test.FakeDriverAlpha do
  @moduledoc false

  @behaviour Ezagent.ProviderConnection.Driver

  @control_table :task6_fake_driver_alpha_control

  def reset do
    ensure_control_table()
    :ets.delete_all_objects(@control_table)
    :ok
  end

  def fail_next(operation, reason) when operation in [:begin, :consume] and is_atom(reason) do
    ensure_control_table()
    :ets.insert(@control_table, {operation, reason})
    :ok
  end

  def provider_effect_count do
    ensure_control_table()
    :ets.select_count(@control_table, [{{{:effect, :_, :_, :_}, :_}, [], [true]}])
  end

  def provider_effect_count(operation) when operation in [:begin, :consume] do
    ensure_control_table()
    :ets.select_count(@control_table, [{{{:effect, operation, :_, :_}, :_}, [], [true]}])
  end

  def provider_discard_effect_count do
    ensure_control_table()
    :ets.select_count(@control_table, [{{{:discard_effect, :_}, :_}, [], [true]}])
  end

  def whole_connection_revoke_count do
    ensure_control_table()
    :ets.select_count(@control_table, [{{{:whole_connection_revoke, :_}, :_}, [], [true]}])
  end

  def set_provider_metadata(metadata) when is_map(metadata) do
    ensure_control_table()
    :ets.insert(@control_table, {:provider_metadata, metadata})
    :ok
  end

  def set_barrier(operation, owner)
      when operation in [:begin, :consume, :consume_before_effect] and is_pid(owner) do
    ensure_control_table()
    :ets.insert(@control_table, {{:barrier, operation}, owner})
    :ok
  end

  def set_reconciliation(correlation_id, outcome)
      when is_binary(correlation_id) and outcome in [:not_completed, :ambiguous] do
    ensure_control_table()

    Enum.each([correlation_id, "store:#{correlation_id}", "replace:#{correlation_id}"], fn key ->
      :ets.insert(@control_table, {{:reconciliation, key}, outcome})
    end)

    :ok
  end

  def declaration_metadata(extra \\ %{}) do
    Map.merge(extra, %{
      authorization_redirect_schema: %{
        type: :map,
        fields: %{
          "authorization_uri" => %{type: :string},
          "state" => %{type: :string},
          "pkce_digest" => %{type: :string},
          "driver_marker" => %{type: :string}
        }
      },
      provider_metadata_schema: %{
        type: :map,
        fields: %{"tier" => %{type: :string}}
      }
    })
  end

  @impl true
  def begin_authorization(%{exchange: exchange} = context) when is_function(exchange, 1) do
    with :ok <- take_failure(:begin) do
      exchange.(fn private_frame ->
        reconcile_effect(:begin, context, private_frame, fn ->
          {:ok,
           %{
             redirect: %{
               "authorization_uri" => "https://alpha.example/authorize",
               "state" => private_frame.state,
               "pkce_digest" => pkce_digest(private_frame.pkce_verifier),
               "driver_marker" => "alpha-owned"
             }
           }}
        end)
      end)
    end
  end

  def begin_authorization(context), do: {:ok, %{flow: "redirect", context: context}}

  @impl true
  def consume_callback(%{exchange: exchange} = context) when is_function(exchange, 1) do
    with :ok <- take_failure(:consume) do
      maybe_barrier(:consume_before_effect, context)

      result =
        exchange.(fn private_frame ->
          reconcile_effect(:consume, context, private_frame, fn ->
            {:ok,
             %{
               provider_result_ref: provider_result_ref(context, private_frame, "acct-1"),
               external_account_id: "acct-1",
               display_login: "alice-alpha",
               execution_identity: %{kind: :connected_user, external_account_id: "acct-1"},
               authorization_ref: context.authorization_ref,
               authorization_version: Map.get(context, :expected_authorization_version, 0) + 1,
               credential_material: "TASK6_DRIVER_OWNED_CREDENTIAL",
               granted_permissions_digest: "driver-granted-digest",
               expires_at: nil,
               provider_metadata: provider_metadata()
             }}
          end)
        end)

      maybe_barrier(:consume, context)
      result
    end
  end

  def consume_callback(context),
    do:
      {:ok,
       %{
         external_account: %{subject: "alpha-subject"},
         metadata: %{tier: "alpha"},
         context: context
       }}

  @impl true
  def reconcile_callback(%{exchange: exchange} = context) when is_function(exchange, 1) do
    with {:ok, _identity} <- reconciliation_identity(context) do
      exchange.(fn private_frame -> reconcile_existing(:consume, context, private_frame) end)
    end
  end

  def reconcile_callback(_context), do: {:error, :provider_protocol_error}

  @impl true
  def refresh(%{refresh_use: refresh_use} = context) do
    Ezagent.ProviderConnection.CredentialRefreshExchange.consume_refresh_exchange(%{
      refresh_use: refresh_use,
      provider_exchange: fn private_frame ->
        reconcile_effect(:refresh, context, private_frame, fn ->
          {:ok,
           %{
             provider_result_ref: provider_result_ref(context, private_frame, "refresh-acct-1"),
             replacement_credential: "ALPHA_REFRESH_REPLACEMENT",
             granted_permissions_digest: "driver-refresh-digest",
             expires_at: nil,
             provider_metadata: provider_metadata()
           }}
        end)
      end
    })
  end

  def refresh(_context), do: {:error, :provider_protocol_failed}

  @impl true
  def reconcile_refresh(%{refresh_use: refresh_use} = context) do
    Ezagent.ProviderConnection.CredentialRefreshExchange.consume_refresh_exchange(%{
      refresh_use: refresh_use,
      provider_exchange: fn private_frame ->
        reconcile_existing(:refresh, context, private_frame)
      end
    })
  end

  def reconcile_refresh(_context), do: {:error, :provider_protocol_failed}

  @impl true
  def discard_callback_result(context), do: discard_result(:callback, context)

  @impl true
  def discard_refresh_result(context), do: discard_result(:refresh, context)

  @impl true
  def revoke(context) do
    ensure_control_table()
    :ets.insert(@control_table, {{:whole_connection_revoke, make_ref()}, context})
    {:ok, %{revocation: %{mode: "provider-first"}, context: context}}
  end

  defp take_failure(operation) do
    ensure_control_table()

    case :ets.take(@control_table, operation) do
      [{^operation, reason}] -> {:error, reason}
      [] -> :ok
    end
  end

  defp maybe_barrier(operation, context) do
    case :ets.lookup(@control_table, {:barrier, operation}) do
      [{{:barrier, ^operation}, owner}] ->
        send(owner, {:fake_driver_barrier, operation, self(), context})

        receive do
          {:release_fake_driver, ^operation} -> :ok
        end

      [] ->
        :ok
    end
  end

  defp reconcile_existing(operation, context, private_frame) do
    ensure_control_table()
    correlation_id = context.correlation_id
    digest = effect_digest(context, private_frame)

    case :ets.lookup(@control_table, {:reconciliation, correlation_id}) do
      [{{:reconciliation, ^correlation_id}, :not_completed}] ->
        {:ok, :not_completed}

      [{{:reconciliation, ^correlation_id}, :ambiguous}] ->
        {:error, :provider_outcome_ambiguous}

      [] ->
        case :ets.match_object(@control_table, {{:effect, operation, correlation_id, :_}, :_}) do
          [{{:effect, ^operation, ^correlation_id, ^digest}, result}] -> result
          [] -> {:ok, :not_completed}
          [_conflict] -> {:error, :provider_protocol_error}
        end
    end
  end

  defp reconcile_effect(operation, context, private_frame, effect) do
    ensure_control_table()
    correlation_id = context.correlation_id
    digest = effect_digest(context, private_frame)

    case :ets.match_object(@control_table, {{:effect, operation, correlation_id, :_}, :_}) do
      [{{:effect, ^operation, ^correlation_id, ^digest}, result}] ->
        result

      [] ->
        result = effect.()
        :ets.insert(@control_table, {{:effect, operation, correlation_id, digest}, result})
        remember_provider_result(operation, context, result)
        result

      [_conflict] ->
        {:error, :provider_protocol_error}
    end
  end

  defp remember_provider_result(:consume, context, {:ok, result}) do
    binding = Map.take(context, discard_binding_keys(:callback))
    :ets.insert(@control_table, {{:provider_result, result.provider_result_ref}, binding})
  end

  defp remember_provider_result(:refresh, context, {:ok, result}) do
    binding = Map.take(context, discard_binding_keys(:refresh))
    :ets.insert(@control_table, {{:provider_result, result.provider_result_ref}, binding})
  end

  defp remember_provider_result(_operation, _context, _result), do: :ok

  defp discard_result(kind, context) do
    ensure_control_table()

    with :ok <- Ezagent.ProviderConnection.Driver.validate_discard_context(kind, context),
         [{{:provider_result, _ref}, expected}] <-
           :ets.lookup(@control_table, {:provider_result, context.provider_result_ref}),
         true <- Map.take(context, discard_binding_keys(kind)) == expected do
      digest = :crypto.hash(:sha256, :erlang.term_to_binary(context, [:deterministic]))
      key = context.discard_idempotency_key

      case {:ets.lookup(@control_table, {:discard, key}),
            :ets.lookup(@control_table, {:discarded_result, context.provider_result_ref})} do
        {[{{:discard, ^key}, ^digest}], _result} ->
          :ok

        {[], []} ->
          :ets.insert(@control_table, [
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

  defp effect_digest(context, private_frame) do
    identity =
      case reconciliation_identity(context) do
        {:ok, identity} -> identity
        {:error, :provider_protocol_error} -> :legacy
      end

    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({identity, private_frame}, [:deterministic])
    )
  end

  defp reconciliation_identity(context) do
    identity = Map.drop(context, [:exchange, :refresh_use])

    expected =
      if Map.has_key?(context, :refresh_use) do
        MapSet.new(
          ~w(owner_uri workspace_uri provider_id acquisition_method governed_host backend_pair_id operation_id connection_id authorization_ref expected_connection_version expected_authorization_version expected_credential_version correlation_id command_digest)a
        )
      else
        MapSet.new(
          ~w(owner_uri workspace_uri provider_id acquisition_method governed_host backend_pair_id operation_id connection_id attempt_ref authorization_ref expected_connection_version expected_authorization_version expected_credential_version correlation_id command_digest callback_envelope_digest)a
        )
      end

    if MapSet.new(Map.keys(identity)) == expected do
      {:ok, identity}
    else
      {:error, :provider_protocol_error}
    end
  end

  defp provider_metadata do
    case :ets.lookup(@control_table, :provider_metadata) do
      [{:provider_metadata, metadata}] -> metadata
      [] -> %{"tier" => "alpha"}
    end
  end

  defp provider_result_ref(context, private_frame, native_result_id) do
    binding =
      {Map.drop(context, [:exchange, :refresh_use]), Map.drop(private_frame, [:pkce_verifier]),
       native_result_id}

    digest =
      binding
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    "alpha-provider-result:#{digest}"
  end

  defp ensure_control_table do
    case :ets.whereis(@control_table) do
      :undefined ->
        try do
          :ets.new(@control_table, [:named_table, :public, :set])
        rescue
          ArgumentError -> @control_table
        end

      _tid ->
        @control_table
    end
  end

  defp pkce_digest(verifier),
    do: :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
end
