defmodule EzagentPluginFeishu.UserBindingSeed do
  @moduledoc """
  Boot-time Feishu user-binding seed importer (handoff B1 permission-
  avoidance pivot, 2026-07-24).

  `run/1` is the single entry point `Application.after_boot/0` calls,
  immediately after `Ezagent.Workspace.Loader.load_all/0`.

  ## A-layer (permission-neutral plan)

  1. Read the explicit file path. Missing file (`:enoent`) → `{:ok, :absent}`.
  2. Strict decode + validate via `Parser.parse_and_validate/1` — any
     invalid content fails loud with ZERO mutation.
  3. Full-file preflight: classify every row `:absent` / `:same` /
     `:conflict` via the executor's list operation — BEFORE any mutation.
     Any `:conflict` fails the whole file.
  4. For `:absent` rows only, request the executor to bind, in file order.
     `:same` rows are never dispatched.
  5. Runtime failure on row N fails the call, but earlier rows' success is
     preserved (not compensated). Restart converges via same/absent.
  6. Returns structured, redacted summary/error.

  ## Executor injection

  The executor is `Application.get_env(:ezagent_plugin_feishu,
  :seed_executor)` (default nil → fail loud). Tests inject the
  named-module `FakeExecutor` to record planned operations.
  `DispatchAdapter` is a B-layer placeholder (raises on any call).
  No default executor exists in production.

  ## B-layer (deferred)

  `DispatchAdapter` is not integrated with a runtime operator or boot
  authorization source yet. It deliberately fails closed on every call.
  A later thin integration must supply its operator identity and action
  authorization from runtime dispatch/configuration; this A-layer neither
  assumes nor creates that authority.

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

          is_nil(executor_mod()) ->
            {:error, :seed_executor_not_configured}

          true ->
            with {:ok, rows} <- Parser.parse_and_validate(body),
                 {:ok, classified} <- preflight(rows) do
              dispatch_absent(classified)
            end
        end
    end
  end

  defp seed_enabled? do
    Application.get_env(:ezagent_plugin_feishu, :seed_enabled, false)
  end

  # The module that provides list_current/1 + bind/3.
  # Returns nil when not configured → importer fails loud.
  # Tests inject a real module (DispatchAdapter or FakeExecutor).
  defp executor_mod do
    Application.get_env(:ezagent_plugin_feishu, :seed_executor)
  end

  # --- preflight (read-only, via executor) -----------------------------

  defp preflight(rows) do
    rows
    |> Enum.group_by(fn r -> Ezagent.URI.entity_workspace_uri(Map.fetch!(r, :user_uri)) end)
    |> Enum.sort_by(fn {_ws, ws_rows} -> ws_rows |> hd() |> Map.fetch!(:row) end)
    |> Enum.reduce_while({:ok, []}, fn {workspace_uri, workspace_rows}, {:ok, acc} ->
      case classify_rows_for_workspace(workspace_uri, workspace_rows, acc) do
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

  defp classify_rows_for_workspace(workspace_uri, workspace_rows, acc) do
    exec = executor_mod()

    case exec.list_current(workspace_uri) do
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

  defp dispatch_absent(classified) do
    same_rows =
      classified
      |> Enum.filter(fn {tag, _row} -> tag == :same end)
      |> Enum.map(fn {_tag, row} -> Map.fetch!(row, :row) end)

    exec = executor_mod()

    classified
    |> Enum.filter(fn {tag, _row} -> tag == :absent end)
    |> Enum.reduce_while({:ok, []}, fn {:absent, row}, {:ok, bound_acc} ->
      user_uri = Map.fetch!(row, :user_uri)
      workspace_uri = Ezagent.URI.entity_workspace_uri(user_uri)
      open_id = Map.fetch!(row, :open_id)

      case exec.bind(workspace_uri, open_id, user_uri) do
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
