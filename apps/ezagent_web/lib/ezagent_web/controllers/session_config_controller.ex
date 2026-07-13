defmodule EzagentWeb.SessionConfigController do
  @moduledoc "Thin token-authenticated HTTP projection of Session-Config operations."

  use Phoenix.Controller, formats: [:json]

  alias Ezagent.Session.Config
  alias EzagentWeb.SessionConfigProjection

  @forbidden_context_keys MapSet.new(~w(
    caller principal entity_uri owner owner_uri workspace workspace_uri
    session session_uri parent parent_template_uri caps authenticated_principal
  ))

  @doc "List the exact canonical schemas exposed by the HTTP safe subset."
  def index(conn, _params) do
    json(conn, %{operations: SessionConfigProjection.schemas()})
  end

  @doc "Authenticate a bearer credential and project one request into Session.Config.execute/4."
  def invoke(conn, %{"operation" => operation_name} = params) do
    with :ok <- reject_identity_inputs(conn, params),
         true <- not is_nil(SessionConfigProjection.operation(operation_name)),
         {:ok, principal} <- authenticate(conn),
         {:ok, target} <- parse_target(Map.get(params, "target")),
         {:ok, args} <- parse_args(Map.get(params, "args", %{})) do
      operation_name
      |> Config.execute(args, principal, target)
      |> respond(conn)
    else
      false -> error(conn, 404, "operation_not_exposed", operation_name)
      {:error, status, code, detail} -> error(conn, status, code, detail)
    end
  end

  defp authenticate(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> credential] ->
        case Ezagent.Authentication.authenticate(credential) do
          {:ok, %URI{} = principal} -> {:ok, principal}
          {:error, reason} -> {:error, 401, "invalid_token", inspect(reason)}
        end

      _ ->
        {:error, 401, "missing_token", "bearer token required"}
    end
  end

  defp parse_target(nil), do: {:ok, nil}

  defp parse_target(target) when is_binary(target) do
    {:ok, Ezagent.URI.new!(target)}
  rescue
    ArgumentError -> {:error, 400, "bad_target_uri", target}
  end

  defp parse_target(_target), do: {:error, 400, "bad_target_uri", "target must be a URI string"}

  defp parse_args(%{} = args), do: {:ok, args}
  defp parse_args(_args), do: {:error, 400, "bad_args", "args must be an object"}

  defp reject_identity_inputs(conn, params) do
    if get_req_header(conn, "x-ezagent-entity-uri") != [] or forbidden_context?(params) do
      {:error, 400, "identity_input_forbidden", "authority context derives from the token"}
    else
      :ok
    end
  end

  defp forbidden_context?(map) when is_map(map) do
    Enum.any?(map, fn {key, value} ->
      MapSet.member?(@forbidden_context_keys, to_string(key)) or forbidden_context?(value)
    end)
  end

  defp forbidden_context?(list) when is_list(list), do: Enum.any?(list, &forbidden_context?/1)
  defp forbidden_context?(_value), do: false

  defp respond(:ok, conn), do: json(conn, %{ok: true, result: nil})
  defp respond({:ok, result}, conn), do: json(conn, %{ok: true, result: encodable(result)})

  defp respond({:error, {:invalid_arg, _, _} = reason}, conn),
    do: error(conn, 400, "validation_failed", inspect(reason))

  defp respond({:error, {:missing_arg, _} = reason}, conn),
    do: error(conn, 400, "validation_failed", inspect(reason))

  defp respond({:error, {:invalid_args, _} = reason}, conn),
    do: error(conn, 400, "validation_failed", inspect(reason))

  defp respond({:error, {:invalid_addressed_target, _} = reason}, conn),
    do: error(conn, 400, "validation_failed", inspect(reason))

  defp respond({:error, {:invalid_addressed_target, _, _} = reason}, conn),
    do: error(conn, 400, "validation_failed", inspect(reason))

  defp respond({:error, {:gate_failed, :readiness, _} = reason}, conn),
    do: error(conn, 409, "not_ready", inspect(reason))

  defp respond({:error, {:gate_failed, _gate, _reason} = reason}, conn),
    do: error(conn, 403, "admission_denied", inspect(reason))

  defp respond({:error, reason}, conn), do: error(conn, 422, "execution_failed", inspect(reason))
  defp respond(result, conn), do: json(conn, %{ok: true, result: encodable(result)})

  defp error(conn, status, code, detail) do
    conn
    |> put_status(status)
    |> json(%{ok: false, error: %{code: code, detail: detail}})
  end

  defp encodable(%URI{} = uri), do: URI.to_string(uri)
  defp encodable(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encodable(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp encodable(%MapSet{} = value), do: value |> MapSet.to_list() |> encodable()
  defp encodable(value) when is_struct(value), do: value |> Map.from_struct() |> encodable()
  defp encodable(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, encodable(v)} end)
  defp encodable(value) when is_list(value), do: Enum.map(value, &encodable/1)
  defp encodable(value) when is_tuple(value), do: value |> Tuple.to_list() |> encodable()
  defp encodable(value) when is_atom(value), do: Atom.to_string(value)
  defp encodable(value), do: value
end
