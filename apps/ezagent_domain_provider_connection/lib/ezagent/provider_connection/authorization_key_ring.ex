defmodule Ezagent.ProviderConnection.AuthorizationKeyRing do
  @moduledoc """
  Singleton validator for authorization-correlation key configuration.

  Raw keys exist only in this process's private state. Crypto callers parse the
  already-validated application configuration in their own call stack and
  compare its non-secret fingerprint with this singleton before use.
  """

  use GenServer
  import Ecto.Query

  alias Ezagent.ProviderConnection.AuthorizationBackendRecord
  alias EzagentCore.Repo

  @fixture_enabled Application.compile_env(
                     :ezagent_domain_provider_connection,
                     :authorization_key_ring_fixture_enabled,
                     false
                   )
  @key_id_pattern ~r/\A[a-zA-Z0-9._-]{1,64}\z/

  @spec start_link(keyword()) :: GenServer.on_start() | {:error, :singleton_only}
  def start_link(opts \\ [])
  def start_link([]), do: start_singleton()
  def start_link(_caller_options), do: {:error, :singleton_only}

  @doc false
  def validate_rotation_config do
    with {:ok, state} <- parse_config(config()),
         :ok <- validate_referenced_keys(state, :caller_connection) do
      :ok
    end
  end

  @doc false
  @spec validated_fingerprint() :: {:ok, binary()} | {:error, :authorization_backend_unavailable}
  def validated_fingerprint do
    {:ok, GenServer.call(__MODULE__, :validated_fingerprint)}
  catch
    :exit, _reason -> {:error, :authorization_backend_unavailable}
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:validated_fingerprint, _from, state),
    do: {:reply, state.fingerprint, state}

  defp start_singleton do
    with {:ok, state} <- validated_state() do
      GenServer.start_link(__MODULE__, state, name: __MODULE__)
    end
  end

  defp validated_state do
    with {:ok, state} <- parse_config(config()),
         :ok <- validate_referenced_keys(state, :owned_connection) do
      {:ok, Map.put(state, :fingerprint, fingerprint(state))}
    end
  end

  defp config,
    do:
      Application.get_env(
        :ezagent_domain_provider_connection,
        __MODULE__,
        []
      )

  defp parse_config(config) when is_list(config) do
    source = Keyword.get(config, :source)

    with {:ok, pairs} <- load_pairs(source, config),
         {:ok, keys} <- normalize_keys(pairs),
         {:ok, active} <- validate_key_id(Keyword.get(config, :active_key_id)),
         true <- Map.has_key?(keys, active) do
      {:ok, %{active_key_id: active, keys: keys}}
    else
      false -> invalid({:active_key_missing, safe_id(Keyword.get(config, :active_key_id))})
      {:error, {:invalid_authorization_key_ring, _reason}} = error -> error
      {:error, reason} -> invalid(reason)
    end
  end

  defp parse_config(_config), do: invalid(:malformed_configuration)

  if @fixture_enabled do
    defp load_pairs(:explicit_test, config) do
      case Keyword.get(config, :keys) do
        keys when is_map(keys) -> {:ok, Map.to_list(keys)}
        _other -> {:error, :malformed_keys}
      end
    end
  else
    defp load_pairs(:explicit_test, _config), do: {:error, :explicit_key_forbidden}
  end

  defp load_pairs(:runtime_env, config) do
    case Keyword.get(config, :keys_json) do
      json when is_binary(json) -> decode_json_pairs(json)
      _other -> {:error, :missing_keys_json}
    end
  end

  defp load_pairs(_source, _config), do: {:error, :missing_source}

  defp decode_json_pairs(json) do
    case Jason.decode(json, objects: :ordered_objects) do
      {:ok, %Jason.OrderedObject{values: pairs}} -> decode_pairs(pairs)
      _other -> {:error, :malformed_keys_json}
    end
  end

  defp decode_pairs(pairs) do
    Enum.reduce_while(pairs, {:ok, []}, fn {id, encoded}, {:ok, acc} ->
      case is_binary(encoded) && Base.decode64(encoded) do
        {:ok, key} -> {:cont, {:ok, [{id, key} | acc]}}
        _other -> {:halt, {:error, :invalid_base64}}
      end
    end)
  end

  defp normalize_keys(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {id, key}, {:ok, acc} ->
      with {:ok, id} <- validate_key_id(id),
           true <- is_binary(key) and byte_size(key) == 32,
           false <- Map.has_key?(acc, id) do
        {:cont, {:ok, Map.put(acc, id, key)}}
      else
        true -> {:halt, {:error, {:duplicate_key_id, safe_id(id)}}}
        false -> {:halt, {:error, {:invalid_key_length, safe_id(id)}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_key_id(id) when is_binary(id) do
    if Regex.match?(@key_id_pattern, id),
      do: {:ok, id},
      else: {:error, {:invalid_key_id, safe_id(id)}}
  end

  defp validate_key_id(_id), do: {:error, {:invalid_key_id, :non_string}}

  defp validate_referenced_keys(state, connection_mode) do
    query =
      AuthorizationBackendRecord
      |> where([record], record.expires_at > ^DateTime.utc_now())
      |> select([record], {
        record.key_id,
        record.key_fingerprint,
        record.callback_key_id,
        record.callback_key_fingerprint
      })
      |> distinct(true)

    key_ids =
      query
      |> referenced_key_ids(connection_mode)
      |> Enum.flat_map(fn {key_id, key_fingerprint, callback_key_id, callback_fingerprint} ->
        [{key_id, key_fingerprint}] ++
          if is_binary(callback_key_id), do: [{callback_key_id, callback_fingerprint}], else: []
      end)
      |> Enum.uniq()

    Enum.reduce_while(key_ids, :ok, fn {id, fingerprint}, :ok ->
      case Map.fetch(state.keys, id) do
        :error ->
          {:halt, invalid({:referenced_key_missing, safe_id(id)})}

        {:ok, key} ->
          if :crypto.hash(:sha256, key) == fingerprint,
            do: {:cont, :ok},
            else: {:halt, invalid({:referenced_key_changed, safe_id(id)})}
      end
    end)
  end

  defp referenced_key_ids(query, :caller_connection), do: Repo.all(query)

  defp referenced_key_ids(query, :owned_connection) do
    if Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> Repo.all(query) end)
    else
      Repo.all(query)
    end
  end

  defp fingerprint(%{active_key_id: active, keys: keys}) do
    key_digests = Map.new(keys, fn {id, key} -> {id, :crypto.hash(:sha256, key)} end)
    :crypto.hash(:sha256, :erlang.term_to_binary({active, key_digests}, [:deterministic]))
  end

  defp safe_id(id) when is_binary(id) and byte_size(id) <= 64, do: id
  defp safe_id(_id), do: :invalid
  defp invalid(reason), do: {:error, {:invalid_authorization_key_ring, reason}}
end
