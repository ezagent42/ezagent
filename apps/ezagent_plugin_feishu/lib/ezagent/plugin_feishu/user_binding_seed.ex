defmodule EzagentPluginFeishu.UserBindingSeed do
  @moduledoc """
  Boot-time Feishu user-binding seed importer (handoff B1 permission-
  avoidance pivot, 2026-07-24).

  `run/1` is the single entry point `Application.after_boot/0` calls,
  immediately after `Ezagent.Workspace.Loader.load_all/0`.

  ## A-layer (permission-neutral plan)

  1. Read the explicit file path. Missing file (`:enoent`) → `{:ok, :absent}`.
  2. For a present file, require the seed to be explicitly enabled.
  3. Validate the configured executor function port once, then thread it
     through the remaining pipeline.
  4. Strict decode + validate via `Parser.parse_and_validate/1` — any
     invalid content fails loud with ZERO mutation.
  5. Full-file preflight: classify every row `:absent` / `:same` /
     `:conflict` via the port's list operation — BEFORE any mutation.
     Any `:conflict` fails the whole file.
  6. For `:absent` rows only, request the port to bind, in file order.
     `:same` rows are never dispatched.
  7. Runtime failure on row N fails the call, but earlier rows' success is
     preserved (not compensated). Restart converges via same/absent.
  8. Returns structured, redacted summary/error.

  ## Executor injection

  The executor port may be overridden through
  `Application.get_env(:ezagent_plugin_feishu, :seed_executor_port)` for
  tests. Production defaults to `DispatchAdapter.port/0`, which obtains its
  operator identity from runtime configuration and uses formal synchronous
  dispatch. Both ports expose `list_current` arity 1 and `bind` arity 3.

  ## Known limitation: same-workspace race window

  Preflight (`list_current`) and dispatch (`bind`) are not atomic. A
  concurrent manual bind between preflight and dispatch could create an
  open_id that the preflight classified `:absent`. The importer's bind
  would then upsert (the handler's legitimate same-workspace rebind path).
  The handler's anti-hijack check (`ensure_no_cross_workspace_hijack`)
  only guards cross-workspace hijack. For same-workspace, the bind
  dispatches formally — it is a legitimate operation, not silent
  corruption. If this race is unacceptable, wrap preflight+dispatch in
  a DB transaction (requires core change — deferred).
  """

  alias EzagentPluginFeishu.Redact
  alias EzagentPluginFeishu.UserBindingSeed.Parser

  @type summary :: %{bound: [pos_integer()], same: [pos_integer()], total: non_neg_integer()}
  @typep executor_port :: %{
           list_current: (URI.t() -> {:ok, [map()]} | {:error, term()}),
           bind: (URI.t(), String.t(), URI.t() -> {:ok, term()} | {:error, term()})
         }

  @doc """
  Run the seed importer for the file at `path`.

  Gated by `config :ezagent_plugin_feishu, :seed_enabled` (default false).
  When disabled:
  - missing file → `{:ok, :absent}` (no-op)
  - present file → `{:error, :seed_not_enabled}` (fail loud)
  """
  @spec run(String.t()) :: {:ok, :absent} | {:ok, summary()} | {:error, term()}
  def run(path) when is_binary(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:ok, :absent}

      {:error, reason} ->
        {:error, {:file_read_error, reason}}

      {:ok, body} ->
        cond do
          not seed_enabled?() ->
            {:error, :seed_not_enabled}

          true ->
            with {:ok, port} <- executor_port(),
                 {:ok, rows} <- Parser.parse_and_validate(body),
                 {:ok, classified} <- preflight(rows, port) do
              dispatch_absent(classified, port)
            end
        end
    end
  end

  defp seed_enabled? do
    Application.get_env(:ezagent_plugin_feishu, :seed_enabled, false)
  end

  @spec executor_port() ::
          {:ok, executor_port()}
          | {:error, :seed_executor_not_configured | {:invalid_seed_executor_port, [atom()]}}
  defp executor_port do
    configured =
      Application.get_env(
        :ezagent_plugin_feishu,
        :seed_executor_port,
        EzagentPluginFeishu.UserBindingSeed.DispatchAdapter.port()
      )

    validate_executor_port(configured)
  end

  defp validate_executor_port(nil), do: {:error, :seed_executor_not_configured}

  defp validate_executor_port(port) do
    list_current = if is_map(port), do: Map.get(port, :list_current)
    bind = if is_map(port), do: Map.get(port, :bind)

    invalid_fields =
      [
        {:list_current, is_function(list_current, 1)},
        {:bind, is_function(bind, 3)}
      ]
      |> Enum.reject(fn {_field, valid?} -> valid? end)
      |> Enum.map(fn {field, _valid?} -> field end)

    case invalid_fields do
      [] -> {:ok, %{list_current: list_current, bind: bind}}
      fields -> {:error, {:invalid_seed_executor_port, fields}}
    end
  end

  # --- preflight (read-only, via executor) -----------------------------

  defp preflight(rows, port) do
    rows
    |> Enum.group_by(fn r -> Ezagent.URI.entity_workspace_uri(Map.fetch!(r, :user_uri)) end)
    |> Enum.sort_by(fn {_ws, ws_rows} -> ws_rows |> hd() |> Map.fetch!(:row) end)
    |> Enum.reduce_while({:ok, []}, fn {workspace_uri, workspace_rows}, {:ok, acc} ->
      case classify_rows_for_workspace(workspace_uri, workspace_rows, acc, port) do
        {:ok, acc2} -> {:cont, {:ok, acc2}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, classified} ->
        {:ok, Enum.sort_by(classified, fn {_tag, row} -> Map.fetch!(row, :row) end)}

      {:error, _} = err ->
        err
    end
  end

  defp classify_rows_for_workspace(
         workspace_uri,
         workspace_rows,
         acc,
         %{list_current: list_current}
       ) do
    case list_current.(workspace_uri) do
      {:ok, current} ->
        current_by_open_id =
          Map.new(current, fn b -> {Map.fetch!(b, :open_id), b} end)

        Enum.reduce_while(workspace_rows, {:ok, acc}, fn row, {:ok, acc2} ->
          case classify_row(row, current_by_open_id) do
            :conflict ->
              {:halt, {:error, conflict_error(row, workspace_uri)}}

            tag ->
              {:cont, {:ok, [{tag, row} | acc2]}}
          end
        end)

      {:error, reason} ->
        {:error, {:preflight_read_failed, Ezagent.URI.workspace_name!(workspace_uri), reason}}
    end
  end

  defp classify_row(row, current_by_open_id) do
    open_id = Map.fetch!(row, :open_id)
    user_uri = Map.fetch!(row, :user_uri)

    case Map.get(current_by_open_id, open_id) do
      nil ->
        :absent

      existing ->
        existing_user_uri_str = Map.fetch!(existing, :user_uri)

        if existing_user_uri_str == URI.to_string(user_uri) do
          :same
        else
          :conflict
        end
    end
  end

  defp conflict_error(row, workspace_uri) do
    {:conflict, Map.fetch!(row, :row), Ezagent.URI.workspace_name!(workspace_uri),
     Redact.fingerprint(Map.fetch!(row, :open_id))}
  end

  # --- dispatch (write, absent rows only) ------------------------------

  defp dispatch_absent(classified, %{bind: bind}) do
    same_rows =
      classified
      |> Enum.filter(fn {tag, _row} -> tag == :same end)
      |> Enum.map(fn {_tag, row} -> Map.fetch!(row, :row) end)

    classified
    |> Enum.filter(fn {tag, _row} -> tag == :absent end)
    |> Enum.reduce_while({:ok, []}, fn {:absent, row}, {:ok, bound_acc} ->
      user_uri = Map.fetch!(row, :user_uri)
      workspace_uri = Ezagent.URI.entity_workspace_uri(user_uri)
      open_id = Map.fetch!(row, :open_id)

      case bind.(workspace_uri, open_id, user_uri) do
        {:ok, _result} ->
          {:cont, {:ok, [Map.fetch!(row, :row) | bound_acc]}}

        {:error, reason} ->
          {:halt, {:error, dispatch_failed_error(row, workspace_uri, reason)}}
      end
    end)
    |> case do
      {:ok, bound_rows} ->
        {:ok, %{bound: Enum.reverse(bound_rows), same: same_rows, total: length(classified)}}

      {:error, _} = err ->
        err
    end
  end

  defp dispatch_failed_error(row, workspace_uri, reason) do
    {:dispatch_failed, Map.fetch!(row, :row), Ezagent.URI.workspace_name!(workspace_uri),
     Redact.fingerprint(Map.fetch!(row, :open_id)), reason}
  end
end
