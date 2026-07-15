defmodule EzagentWeb.ApiV1Controller do
  @moduledoc """
  Phase 6 PR 9 — canonical auto-derived JSON API.

  Single controller that handles every `POST /api/v1/:kind/:action`
  call by:

    1. Looking up the Behavior for `{kind_module, action}` in
       `Ezagent.BehaviorRegistry`.
    2. Parsing the JSON request body as the action's args map.
    3. Resolving the caller from the bearer credential alone.
    4. Building an `Ezagent.Invocation` and dispatching.
    5. Encoding the result as JSON.

  Routes are NOT pre-declared per behavior — the auto-derive pattern
  means any plugin that registers a Behavior on a Kind gets a
  matching HTTP endpoint for free. New plugin → new route → no
  controller change.

  ## Examples

      POST /api/v1/agent/say
      Authorization: Bearer esr_pat_v1_<raw>
      Content-Type: application/json

      {"target": "entity://agent/team-alpha/py_default", "args": {"message": "hi"}}

  Response:

      {"ok": true, "result": {"reply": "hi"}}

  ## Why one controller (not auto-generated per route)

  Phoenix routes ARE compile-time, but a single catch-all controller
  dispatching on `:kind`/`:action` path params gives us the same
  surface with one route declaration. Trade-off: no per-route docs in
  router, but the discoverable surface is documented at `GET /api/v1`
  (the introspection endpoint).
  """

  use Phoenix.Controller, formats: [:json]

  alias Ezagent.{BehaviorRegistry, Invocation}

  def invoke(conn, params) do
    with {:ok, kind_module, behavior_module} <- resolve_behavior(params),
         {:ok, action} <- resolve_action(params, behavior_module),
         :ok <- reject_identity_inputs(conn, params),
         {:ok, target_uri} <- resolve_target(params, kind_module),
         {:ok, caller_uri, caller_caps} <- resolve_caller(conn) do
      args = Map.get(params, "args", %{}) |> atomize_keys()
      mode = pick_mode(params, behavior_module, action)

      inv = %Invocation{
        target: append_action(target_uri, behavior_module, action),
        mode: mode,
        args: args,
        ctx: %{caller: caller_uri, caps: caller_caps, reply: :sync}
      }

      case Invocation.dispatch(inv) do
        :ok -> json(conn, %{ok: true, result: nil})
        {:ok, result} -> json(conn, %{ok: true, result: encodable(result)})
        {:error, reason} -> error(conn, 422, "dispatch_failed", inspect(reason))
      end
    else
      {:error, status, code, msg} -> error(conn, status, code, msg)
    end
  end

  @doc """
  Introspection — `GET /api/v1` returns the full list of available
  Kind/Action/Behavior tuples + their declared interfaces. Lets
  clients (LV pages, generated SDKs, docs) discover what's callable
  without out-of-band documentation.
  """
  def index(conn, _params) do
    routes =
      BehaviorRegistry.list_all()
      |> Enum.map(fn {{kind_module, action}, behavior_module} ->
        %{
          kind: safe_type_name(kind_module),
          action: action,
          behavior: inspect(behavior_module),
          path: "/api/v1/#{safe_type_name(kind_module)}/#{action}",
          interface: maybe_interface(behavior_module, action)
        }
      end)
      |> Enum.reject(&is_nil(&1.kind))

    json(conn, %{routes: routes, count: length(routes)})
  end

  # --- Internals -----------------------------------------------------

  defp resolve_behavior(%{"kind" => kind_str, "action" => action_str}) do
    BehaviorRegistry.list_all()
    |> Enum.find(fn {{km, action}, _bm} ->
      safe_type_name(km) == kind_str and to_string(action) == action_str
    end)
    |> case do
      nil ->
        {:error, 404, "unknown_behavior", "no behavior for kind=#{kind_str} action=#{action_str}"}

      {{km, _}, bm} ->
        {:ok, km, bm}
    end
  end

  defp resolve_action(%{"action" => action_str}, _behavior_module) do
    {:ok, String.to_atom(action_str)}
  rescue
    _ -> {:error, 400, "bad_action", "action must be a known atom"}
  end

  defp resolve_target(%{"target" => target_str}, _km) when is_binary(target_str) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # for inbound HTTP target URI; try/rescue keeps the structured 400
    # error path for malformed input (Invariant #9 — graceful surface).
    try do
      {:ok, Ezagent.URI.new!(target_str)}
    rescue
      ArgumentError -> {:error, 400, "bad_target_uri", target_str}
    end
  end

  defp resolve_target(_, _) do
    {:error, 400, "missing_target", "request body must include `target` (URI string)"}
  end

  defp resolve_caller(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Ezagent.Authentication.authenticate(token) do
          {:ok, uri} ->
            {:ok, uri, uri |> Ezagent.EntityCaps.load() |> MapSet.new()}

          {:error, reason} ->
            {:error, 401, "invalid_token", inspect(reason)}
        end

      _ ->
        # PR #123 hardening: the pre-public-tunnel admin fallback was
        # the largest open attack surface on /api/v1 — any anonymous
        # internet caller could dispatch as admin. Now requires a
        # valid `esr_pat_…` bearer token issued via
        # `mix ezagent.user.token <uri> --mint`.
        {:error, 401, "missing_token",
         "bearer token required; mint via `mix ezagent.user.token <uri> --mint`"}
    end
  end

  defp reject_identity_inputs(conn, params) do
    forbidden_body_keys = ["caller", "principal", "entity_uri", "owner", "workspace", "parent"]

    if Plug.Conn.get_req_header(conn, "x-ezagent-entity-uri") != [] or
         Enum.any?(forbidden_body_keys, &Map.has_key?(params, &1)) do
      {:error, 400, "identity_input_forbidden",
       "principal and authority context derive from token"}
    else
      :ok
    end
  end

  defp pick_mode(params, behavior_module, action) do
    requested =
      case Map.get(params, "mode") do
        "call" -> :call
        "cast" -> :cast
        _ -> nil
      end

    cond do
      requested ->
        requested

      function_exported?(behavior_module, :interface, 0) ->
        case Map.get(behavior_module.interface(), action) do
          %{modes: [first | _]} -> first
          _ -> :call
        end

      true ->
        :call
    end
  end

  defp append_action(target_uri, behavior_module, action) do
    # Convention: dispatch URL is ?action=<behavior_short>.<action>
    behavior_short =
      behavior_module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    Ezagent.URI.with_action(target_uri, behavior_short, action)
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {String.to_atom(k), v}
    end)
  end

  defp atomize_keys(other), do: other

  defp encodable(%MapSet{} = ms), do: MapSet.to_list(ms) |> Enum.map(&encodable/1)
  defp encodable(%URI{} = u), do: URI.to_string(u)
  defp encodable(list) when is_list(list), do: Enum.map(list, &encodable/1)

  defp encodable(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&encodable/1)
  end

  defp encodable(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), encodable(v)} end)
  end

  defp encodable(struct) when is_struct(struct), do: inspect(struct)

  defp encodable(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: Atom.to_string(atom)

  defp encodable(other), do: other

  defp maybe_interface(behavior_module, action) do
    if function_exported?(behavior_module, :interface, 0) do
      case Map.get(behavior_module.interface(), action) do
        nil -> nil
        spec -> encodable(spec)
      end
    end
  end

  defp safe_type_name(km) do
    if Code.ensure_loaded?(km) and function_exported?(km, :type_name, 0) do
      try do
        to_string(km.type_name())
      rescue
        _ -> nil
      catch
        _, _ -> nil
      end
    end
  end

  defp error(conn, status, code, msg) do
    conn
    |> put_status(status)
    |> json(%{ok: false, error: %{code: code, message: msg}})
  end
end
