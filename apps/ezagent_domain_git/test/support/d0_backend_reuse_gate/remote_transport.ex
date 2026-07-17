defmodule Ezagent.DomainGit.D0BackendReuseGate.RemoteTransport do
  @moduledoc false

  alias Ezagent.DomainGit.D0BackendReuseGate.SensitiveCredential

  @payload_key {__MODULE__, :payloads}
  @failure_key {__MODULE__, :failure}
  @journal_key {__MODULE__, :journal}

  @spec round_trip(atom(), term(), (atom(), term() -> term())) :: term()
  def round_trip(operation, request, dispatcher) when is_atom(operation) do
    correlation_key = {operation, correlation_id(request)}

    case Map.fetch(Process.get(@journal_key, %{}), correlation_key) do
      {:ok, response_json} ->
        response_json |> Jason.decode!() |> decode_value()

      :error ->
        do_round_trip(operation, request, dispatcher, correlation_key)
    end
  end

  defp do_round_trip(operation, request, dispatcher, correlation_key) do
    failure = Process.get(@failure_key)
    Process.delete(@failure_key)

    if failure == :before_send do
      {:transport_error, :before_send}
    else
      complete_round_trip(operation, request, dispatcher, correlation_key, failure)
    end
  end

  defp complete_round_trip(operation, request, dispatcher, correlation_key, failure) do
    request_json = request |> encode_value() |> Jason.encode!()
    record_payload(request_json)
    decoded_request = request_json |> Jason.decode!() |> decode_value()

    response = dispatcher.(operation, decoded_request)
    response_json = response |> encode_value() |> Jason.encode!()
    record_payload(response_json)

    if failure in [:after_commit, :after_response] do
      journal = Map.put(Process.get(@journal_key, %{}), correlation_key, response_json)
      Process.put(@journal_key, journal)
      {:transport_error, failure}
    else
      response_json |> Jason.decode!() |> decode_value()
    end
  end

  def reset_payloads do
    Process.put(@payload_key, [])
    Process.put(@journal_key, %{})
    Process.delete(@failure_key)
    :ok
  end

  def fail_next(mode) when mode in [:before_send, :after_commit, :after_response] do
    Process.put(@failure_key, mode)
    :ok
  end

  def payloads, do: Process.get(@payload_key, []) |> Enum.reverse()

  defp correlation_id(request) when is_map(request),
    do: Map.get(request, :correlation_id) || Map.get(request, "correlation_id")

  defp correlation_id(_request), do: nil

  defp record_payload(payload) do
    Process.put(@payload_key, [payload | Process.get(@payload_key, [])])
  end

  defp encode_value(%SensitiveCredential{}) do
    raise ArgumentError, "SensitiveCredential cannot cross the serialized boundary"
  end

  defp encode_value(value) when is_function(value) or is_pid(value) or is_reference(value) do
    raise ArgumentError, "runtime identity cannot cross the serialized boundary"
  end

  defp encode_value(%URI{} = uri), do: %{"$uri" => URI.to_string(uri)}
  defp encode_value(%DateTime{} = value), do: %{"$datetime" => DateTime.to_iso8601(value)}
  defp encode_value(value) when is_atom(value), do: %{"$atom" => Atom.to_string(value)}

  defp encode_value(value) when is_tuple(value),
    do: %{"$tuple" => value |> Tuple.to_list() |> encode_value()}

  defp encode_value(value) when is_list(value), do: Enum.map(value, &encode_value/1)

  defp encode_value(value) when is_map(value) do
    %{"$map" => Enum.map(value, fn {key, item} -> [encode_value(key), encode_value(item)] end)}
  end

  defp encode_value(value), do: value

  defp decode_value(%{"$uri" => value}), do: Ezagent.URI.new!(value)
  defp decode_value(%{"$datetime" => value}), do: value |> DateTime.from_iso8601() |> elem(1)
  defp decode_value(%{"$atom" => value}), do: String.to_existing_atom(value)

  defp decode_value(%{"$tuple" => value}) do
    value |> decode_value() |> List.to_tuple()
  end

  defp decode_value(%{"$map" => entries}) do
    Map.new(entries, fn [key, value] -> {decode_value(key), decode_value(value)} end)
  end

  defp decode_value(value) when is_list(value), do: Enum.map(value, &decode_value/1)
  defp decode_value(value), do: value
end
