defmodule EzagentPluginHello.FusionSeed do
  @moduledoc """
  Reconstructs the committed Fusion website without relying on an existing DB.

  The repository's `priv/seed_page/body.json` and `shell.css` are the sole page
  content sources. Runtime state is created through the normal Hello app and
  Turn/Surface APIs, so the same command works against an independent database.

  The default workspace is the hello HOME workspace
  (`EzagentPluginHello.home_workspace/0`, default `"ezagent"`) — the 官网
  (`<home>/hello/ezagent-official`) lives there, NOT in `system`.
  """

  alias Ezagent.Entity.User
  alias Ezagent.Workspace
  alias EzagentPluginHello.{App, Spec, TurnDriver}

  @default_name "fusion"

  @type result :: %{session_uri: URI.t(), turn_id: String.t()}

  @doc "Reconstruct the canonical `<home>/hello/fusion` website."
  @spec run() :: {:ok, result()} | {:error, term()}
  def run, do: run([])

  @doc """
  Reconstruct a Fusion website, with path/name overrides intended for tests.

  Supported options are `:workspace`, `:name`, `:body_path`, `:css_path`, and
  `:owner` (the caller principal the session is owned by and the page-drive
  turn is authored as — hello-A; defaults to the admin entity for legacy
  tooling/test callers).
  """
  @spec run(keyword()) :: {:ok, result()} | {:error, term()}
  def run(opts) when is_list(opts) do
    workspace = Keyword.get(opts, :workspace, EzagentPluginHello.home_workspace())
    name = Keyword.get(opts, :name, @default_name)
    owner = Keyword.get(opts, :owner, User.admin_uri())
    body_path = Keyword.get(opts, :body_path, seed_path("body.json"))
    css_path = Keyword.get(opts, :css_path, seed_path("shell.css"))

    with {:ok, seed} <- load_seed(body_path, css_path),
         :ok <- ensure_workspace(workspace, owner),
         {:ok, session_uri, _builder_uri} <- App.ensure_app(workspace, name, owner: owner),
         {:ok, turn_id} <- apply_seed(session_uri, seed, owner) do
      {:ok, %{session_uri: session_uri, turn_id: turn_id}}
    end
  end

  @doc "Apply the committed Fusion Page and CSS to an existing Hello Session."
  @spec apply_to(URI.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def apply_to(%URI{} = session_uri, opts \\ []) do
    owner = Keyword.get(opts, :owner, User.admin_uri())
    body_path = Keyword.get(opts, :body_path, seed_path("body.json"))
    css_path = Keyword.get(opts, :css_path, seed_path("shell.css"))

    with {:ok, seed} <- load_seed(body_path, css_path),
         {:ok, turn_id} <- apply_seed(session_uri, seed, owner) do
      {:ok, turn_id}
    end
  end

  defp apply_seed(session_uri, %{body: body, css: css}, owner) do
    with {:ok, turn_id} <-
           TurnDriver.drive(session_uri, body, "Fusion website seed", owner),
         {:ok, _} <- TurnDriver.set_shell(session_uri, owner, "", css) do
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

  # Create the workspace with the OWNER as its founder (`created_by`) so the
  # 官网's owner resolution (`OfficialSiteSeed`) reads a real non-admin founder
  # — never an admin-created workspace that would force the fallback.
  defp ensure_workspace(workspace, owner) do
    case Workspace.create(workspace, %{created_by: owner}) do
      {:ok, _workspace_uri} -> ensure_owner_member(workspace, owner)
      {:error, {:already_started, _pid}} -> :ok
      {:error, :workspace_exists} -> :ok
      {:error, reason} -> {:error, {:workspace, reason}}
    end
  end

  # A workspace the seed CREATES gets its owner as a real MEMBER — the 官网
  # mimics "an ezagent member creating the session", and a member it must be.
  # `add_member` pre-spawns the owner's user Kind, so the cap-grant/absorb
  # flow at materialize time has a live actor to land on. Pre-existing
  # workspaces are deploy state and are left untouched.
  #
  # Membership is only possible (and only meaningful) when the owner LIVES in
  # the workspace being created — cross-workspace membership is structurally
  # rejected (`:cross_workspace_member_not_permitted`). Legacy callers that
  # fall back to the admin default (`entity://system/user/admin`) skip it,
  # exactly the pre-hello-A behavior.

  defp ensure_owner_member(workspace, %URI{} = owner) do
    if Ezagent.Capability.workspace_of(owner) == Ezagent.URI.workspace(workspace) do
      case Workspace.add_member(workspace, owner) do
        :ok -> :ok
        {:error, reason} -> {:error, {:workspace_member, reason}}
      end
    else
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
