defmodule Ezagent.EntityCapsReadyBarrier do
  @moduledoc false

  @key {__MODULE__, :armed}

  def arm(uri, owner \\ self()) do
    :persistent_term.put(@key, {URI.to_string(uri), owner})
    :ok
  end

  def clear do
    :persistent_term.erase(@key)
    :ok
  end

  def defer_ready?(uri) do
    current_uri = uri_string(uri)

    case :persistent_term.get(@key, nil) do
      {uri_string, _owner} when uri_string == current_uri -> {:defer, 5_000}
      _ -> :ready
    end
  end

  def await_transport_or_fail(uri) do
    current_uri = uri_string(uri)

    case :persistent_term.get(@key, nil) do
      {uri_string, owner} when uri_string == current_uri ->
        send(owner, {:entity_caps_barrier_waiting, self()})

        receive do
          :release_entity_caps_barrier ->
            clear()
            :ok
        after
          5_000 -> {:error, :entity_caps_barrier_timeout}
        end

      _ ->
        :ok
    end
  end

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(uri) when is_binary(uri), do: uri
end
