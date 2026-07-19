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

  def set_provider_metadata(metadata) when is_map(metadata) do
    ensure_control_table()
    :ets.insert(@control_table, {:provider_metadata, metadata})
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
        reconcile_effect(:begin, context.correlation_id, private_frame, fn ->
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
      exchange.(fn private_frame ->
        reconcile_effect(:consume, context.correlation_id, private_frame, fn ->
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

  defp reconcile_effect(operation, correlation_id, private_frame, effect) do
    ensure_control_table()
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(private_frame, [:deterministic]))

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
