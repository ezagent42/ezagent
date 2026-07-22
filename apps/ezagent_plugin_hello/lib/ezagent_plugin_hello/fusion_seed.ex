defmodule EzagentPluginHello.FusionSeed do
  @moduledoc """
  Reconstructs the committed Fusion website without relying on an existing DB.

  The repository's `priv/seed_page/body.json` and `shell.css` are the sole page
  content sources. Runtime state is created through the normal Hello app and
  Turn/Surface APIs, so the same command works against an independent database.
  """

  alias Ezagent.Entity.User
  alias Ezagent.Workspace
  alias EzagentPluginHello.{App, Spec, TurnDriver}

  @default_workspace "system"
  @default_name "fusion"

  @type result :: %{session_uri: URI.t(), turn_id: String.t()}

  @doc "Reconstruct the canonical `system/hello/fusion` website."
  @spec run() :: {:ok, result()} | {:error, term()}
  def run, do: run([])

  @doc """
  Reconstruct a Fusion website, with path/name overrides intended for tests.

  Supported options are `:workspace`, `:name`, `:body_path`, and `:css_path`.
  """
  @spec run(keyword()) :: {:ok, result()} | {:error, term()}
  def run(opts) when is_list(opts) do
    workspace = Keyword.get(opts, :workspace, @default_workspace)
    name = Keyword.get(opts, :name, @default_name)
    body_path = Keyword.get(opts, :body_path, seed_path("body.json"))
    css_path = Keyword.get(opts, :css_path, seed_path("shell.css"))

    with {:ok, seed} <- load_seed(body_path, css_path),
         :ok <- ensure_workspace(workspace),
         {:ok, session_uri, _builder_uri} <- App.ensure_app(workspace, name),
         {:ok, turn_id} <- apply_seed(session_uri, seed) do
      {:ok, %{session_uri: session_uri, turn_id: turn_id}}
    end
  end

  @doc "Apply the committed Fusion Page and CSS to an existing Hello Session."
  @spec apply_to(URI.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def apply_to(%URI{} = session_uri, opts \\ []) do
    body_path = Keyword.get(opts, :body_path, seed_path("body.json"))
    css_path = Keyword.get(opts, :css_path, seed_path("shell.css"))

    with {:ok, seed} <- load_seed(body_path, css_path),
         {:ok, turn_id} <- apply_seed(session_uri, seed) do
      {:ok, turn_id}
    end
  end

  defp apply_seed(session_uri, %{body: body, css: css}) do
    with {:ok, turn_id} <-
           TurnDriver.drive(session_uri, body, "Fusion website seed", User.admin_uri()),
         {:ok, _} <- TurnDriver.set_shell(session_uri, User.admin_uri(), "", css) do
      {:ok, turn_id}
    end
  end

  defp load_seed(body_path, css_path) do
    with {:ok, body_json} <- read_seed(body_path, :body),
         {:ok, css} <- read_seed(css_path, :css),
         {:ok, body} <- decode_body(body_json),
         {:ok, body} <- Spec.validate(body) do
      {:ok, %{body: body, css: css}}
    end
  end

  defp read_seed(path, kind) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:seed_file, kind, reason}}
    end
  end

  defp decode_body(body_json) do
    case Jason.decode(body_json) do
      {:ok, body} when is_map(body) -> {:ok, body}
      {:ok, _other} -> {:error, {:invalid_seed_body, :not_a_map}}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_seed_body, error}}
    end
  end

  defp ensure_workspace(workspace) do
    case Ezagent.Workspace.Store.get_by_name(workspace) do
      nil ->
        case Workspace.create(workspace, %{}) do
          {:ok, _workspace_uri} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, {:workspace, reason}}
        end

      _workspace ->
        :ok
    end
  end

  defp seed_path(file) do
    :ezagent_plugin_hello
    |> :code.priv_dir()
    |> Path.join("seed_page")
    |> Path.join(file)
  end
end
