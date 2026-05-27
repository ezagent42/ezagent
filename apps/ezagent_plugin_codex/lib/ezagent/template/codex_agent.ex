defmodule Ezagent.PluginCodex.Template.CodexAgent do
  @moduledoc """
  Codex agent Template Class.

  Instantiating `codex.agent` creates the shared `Ezagent.Entity.Agent`
  Kind, starts a per-agent Codex app-server sidecar, starts a
  user-visible Codex TUI in Domain.Pty, and starts a Python bridge
  sidecar that lets ezagent send turns into the same app-server thread.
  """

  @behaviour Ezagent.Kind.Template
  @behaviour Ezagent.UI.Form

  require Logger

  @compile_env Mix.env()

  @impl Ezagent.Kind.Template
  def template_name, do: "codex.agent"

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- check_agent_uri(tmpl),
         :ok <- check_cwd(tmpl),
         :ok <- check_optional_string(tmpl, "model"),
         :ok <- check_optional_string(tmpl, "approval_policy"),
         :ok <- check_optional_string(tmpl, "sandbox") do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => uri_str} = tmpl, workspace_uri) do
    agent_uri = URI.parse(uri_str)

    cond do
      fully_alive?(agent_uri) ->
        {:ok, [agent_uri], %{fresh?: false}}

      true ->
        spawn_for_codex(agent_uri, tmpl, workspace_uri)
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  @impl Ezagent.UI.Form
  def form_fields do
    [
      %{
        name: "agent_uri",
        type: :uri,
        label: "Agent URI (entity://agent/<workspace>/codex_<name>)",
        required: true,
        placeholder: "entity://agent/team-alpha/codex_builder"
      },
      %{
        name: "cwd",
        type: :path,
        label: "Working directory",
        required: true,
        placeholder: "/path/to/workspace"
      },
      %{
        name: "model",
        type: :text,
        label: "Model override",
        required: false,
        placeholder: "optional"
      },
      %{
        name: "approval_policy",
        type: :select,
        label: "Approval policy",
        required: false,
        options: ["", "never", "on-request", "untrusted"],
        default: ""
      },
      %{
        name: "sandbox",
        type: :select,
        label: "Sandbox",
        required: false,
        options: ["", "read-only", "workspace-write", "danger-full-access"],
        default: ""
      }
    ]
  end

  @impl Ezagent.UI.Form
  def form_to_args(params) when is_map(params) do
    params
    |> Map.drop(["tmpl_name"])
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
    |> Map.put("class", template_name())
  end

  defp spawn_for_codex(agent_uri, tmpl, workspace_uri) do
    with {:ok, started_or_adopted} <- ensure_agent_kind(agent_uri) do
      case started_or_adopted do
        :already_started ->
          if owns_this_agent?(agent_uri, workspace_uri) do
            _ = ensure_sidecars(agent_uri, tmpl)
          end

          {:ok, [agent_uri], %{fresh?: false}}

        :started ->
          case ensure_sidecars(agent_uri, tmpl) do
            {:ok, meta} ->
              {:ok, [agent_uri], Map.put(meta, :fresh?, true)}

            {:error, reason} ->
              rollback_sidecars(agent_uri)
              _ = Ezagent.Kind.terminate(agent_uri)
              {:error, reason}
          end
      end
    end
  end

  defp ensure_sidecars(agent_uri, tmpl) do
    cwd = Map.fetch!(tmpl, "cwd")
    socket_path = app_server_socket_path(agent_uri, tmpl)
    test_mode = Application.get_env(:ezagent_plugin_codex, :test_mode, @compile_env == :test)
    bridge_ws_url = Map.get(tmpl, "bridge_ws_url", default_bridge_ws_url())
    codex_path = Map.get(tmpl, "codex_path")

    with :ok <- ensure_app_server(agent_uri, cwd, socket_path, codex_path, test_mode),
         :ok <- ensure_pty(agent_uri, cwd, socket_path, tmpl, codex_path, test_mode),
         :ok <-
           ensure_bridge_sidecar(agent_uri, cwd, socket_path, bridge_ws_url, tmpl, codex_path, test_mode) do
      {:ok,
       %{
         app_server_socket: socket_path,
         bridge_ws_url: bridge_ws_url
       }}
    end
  end

  defp ensure_app_server(agent_uri, cwd, socket_path, codex_path, test_mode) do
    if EzagentPluginCodex.AppServer.alive?(agent_uri) do
      :ok
    else
      case EzagentPluginCodex.AppServer.start(agent_uri, %{
             cwd: cwd,
             socket_path: socket_path,
             codex_path: codex_path,
             test_mode: test_mode
           }) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, {:codex_app_server_start_failed, reason}}
      end
    end
  end

  defp ensure_pty(agent_uri, cwd, socket_path, tmpl, codex_path, test_mode) do
    if Ezagent.Domain.Pty.alive?(agent_uri) do
      :ok
    else
      with {:ok, cmd} <- codex_tui_cmd(socket_path, cwd, tmpl, codex_path) do
        params =
          if test_mode do
            %{cwd: cwd, test_mode: true}
          else
            %{cwd: cwd, cmd_override: cmd}
          end

        case Ezagent.Domain.Pty.start(agent_uri, params) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, {:codex_tui_start_failed, reason}}
        end
      end
    end
  end

  defp ensure_bridge_sidecar(agent_uri, cwd, socket_path, bridge_ws_url, tmpl, codex_path, test_mode) do
    if EzagentPluginCodex.BridgeSidecar.alive?(agent_uri) do
      :ok
    else
      case EzagentPluginCodex.BridgeSidecar.start(agent_uri, %{
             cwd: cwd,
             app_server_socket: socket_path,
             bridge_ws_url: bridge_ws_url,
             codex_path: codex_path,
             model: Map.get(tmpl, "model"),
             approval_policy: Map.get(tmpl, "approval_policy"),
             sandbox: Map.get(tmpl, "sandbox"),
             test_mode: test_mode
           }) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, {:codex_bridge_sidecar_start_failed, reason}}
      end
    end
  end

  defp rollback_sidecars(agent_uri) do
    _ = EzagentPluginCodex.BridgeSidecar.stop(agent_uri)
    _ = Ezagent.Domain.Pty.stop(agent_uri)
    _ = EzagentPluginCodex.AppServer.stop(agent_uri)
    :ok
  end

  defp codex_tui_cmd(socket_path, cwd, tmpl, codex_path) do
    with {:ok, codex} <- codex_executable(codex_path) do
      base = [codex, "--remote", "unix://#{socket_path}", "--cd", cwd]

      cmd =
        base
        |> maybe_append("--model", Map.get(tmpl, "model"))
        |> maybe_append("--ask-for-approval", Map.get(tmpl, "approval_policy"))
        |> maybe_append("--sandbox", Map.get(tmpl, "sandbox"))

      {:ok, cmd}
    end
  end

  defp maybe_append(args, _flag, value) when value in [nil, ""], do: args
  defp maybe_append(args, flag, value), do: args ++ [flag, value]

  defp codex_executable(path) when is_binary(path) and path != "", do: {:ok, path}

  defp codex_executable(_path) do
    case System.find_executable("codex") do
      path when is_binary(path) -> {:ok, path}
      nil -> {:error, :codex_not_found}
    end
  end

  defp ensure_agent_kind(agent_uri) do
    case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do
      {:ok, :started, _pid} -> {:ok, :started}
      {:ok, :already_started, _pid} -> {:ok, :already_started}
      {:error, reason} -> {:error, {:agent_spawn_failed, reason}}
    end
  end

  defp fully_alive?(agent_uri) do
    agent_kind_alive?(agent_uri) and
      EzagentPluginCodex.AppServer.alive?(agent_uri) and
      Ezagent.Domain.Pty.alive?(agent_uri) and
      EzagentPluginCodex.BridgeSidecar.alive?(agent_uri)
  end

  defp agent_kind_alive?(agent_uri) do
    case Ezagent.KindRegistry.lookup(agent_uri) do
      {:ok, _pid} -> true
      :error -> false
    end
  end

  defp owns_this_agent?(%URI{path: "/" <> rest}, %URI{} = workspace_uri) do
    case String.split(rest, "/", parts: 2) do
      [workspace, _entity_name] -> workspace == workspace_uri.host
      _ -> false
    end
  end

  defp owns_this_agent?(_agent_uri, _workspace_uri), do: false

  defp app_server_socket_path(agent_uri, tmpl) do
    Map.get(tmpl, "app_server_socket") || default_app_server_socket_path(agent_uri)
  end

  defp default_app_server_socket_path(agent_uri) do
    slug =
      agent_uri
      |> URI.to_string()
      |> String.replace(["://", "/", "?", "&", "="], "_")

    Path.join([Ezagent.Home.path("codex"), slug, "app-server.sock"])
  end

  defp default_bridge_ws_url do
    Application.get_env(
      :ezagent_plugin_codex,
      :bridge_ws_url,
      "ws://127.0.0.1:10042/agent_bridge/websocket"
    )
  end

  defp check_class(%{"class" => "codex.agent"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  defp check_cwd(%{"cwd" => cwd}) when is_binary(cwd) and cwd != "", do: :ok
  defp check_cwd(_), do: {:error, :missing_cwd}

  defp check_optional_string(tmpl, key) do
    case Map.fetch(tmpl, key) do
      :error -> :ok
      {:ok, value} when is_binary(value) -> :ok
      {:ok, bad} -> {:error, {:invalid_string_field, key, bad}}
    end
  end

  defp check_agent_uri(%{"agent_uri" => uri_str}) when is_binary(uri_str) and uri_str != "" do
    case URI.new(uri_str) do
      {:ok, %URI{scheme: "entity", host: "agent", path: "/" <> rest}} when rest != "" ->
        with [_workspace, entity_name] when entity_name != "" <-
               String.split(rest, "/", parts: 2),
             [flavor, suffix] when flavor != "" and suffix != "" <-
               String.split(entity_name, "_", parts: 2) do
          if flavor == "codex" do
            :ok
          else
            {:error, {:wrong_agent_flavor, flavor, expected: "codex"}}
          end
        else
          _ ->
            {:error,
             {:missing_flavor_prefix, uri_str,
              "agent URIs must be `entity://agent/<workspace>/codex_<name>`"}}
        end

      {:ok, %URI{scheme: "entity"}} ->
        {:error,
         {:invalid_agent_uri, uri_str,
          "agent URIs must be `entity://agent/<workspace>/codex_<name>`"}}

      _ ->
        {:error, {:bad_agent_uri, uri_str}}
    end
  end

  defp check_agent_uri(_), do: {:error, :missing_agent_uri}
end
