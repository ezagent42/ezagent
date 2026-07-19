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
    :ets.insert(@control_table, {{:reconciliation, correlation_id}, outcome})
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
               external_account_id: "acct-1",
               display_login: "alice-alpha",
               execution_identity: %{kind: :connected_user, external_account_id: "acct-1"},
               credential_material: "TASK6_DRIVER_OWNED_CREDENTIAL",
               granted_permissions_digest: "driver-granted-digest",
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
  def refresh(context),
    do: {:ok, %{refresh: %{rotation: "always"}, context: context}}

  @impl true
  def revoke(context),
    do: {:ok, %{revocation: %{mode: "provider-first"}, context: context}}

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
        result

      [_conflict] ->
        {:error, :provider_protocol_error}
    end
  end

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

  defp provider_metadata do
    case :ets.lookup(@control_table, :provider_metadata) do
      [{:provider_metadata, metadata}] -> metadata
      [] -> %{"tier" => "alpha"}
    end
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
