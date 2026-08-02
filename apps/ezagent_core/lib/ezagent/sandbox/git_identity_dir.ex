defmodule Ezagent.Sandbox.GitIdentityDir do
  @moduledoc """
  SSH 凭据 1b — the single authority for the per-agent **git-identity dir**:
  path computation, allocation, and the destroy-time path-shape guard.

  Mirrors `Ezagent.Sandbox.ConfigDir` in shape, but is a DELIBERATELY SEPARATE
  directory family. See `Ezagent.Resource.FsResolver.git_identity_authority/2`
  for why sharing the config-dir authority function would be a credential leak.

  ## Layout

      <Ezagent.Home.path("git-identity")>/<workspace>/<agent-name>/   (chmod 700)
      ├── id_ed25519      (chmod 600)
      └── known_hosts     (chmod 644)

  ## Why NOT inside the agent's config_dir

  `config_dir` is the home of the **flavor credential rail** (#17 cascade), whose
  semantics are "copy between agents by policy" — `materialize_single_reference`
  `cp_r`s a whole reference dir, `materialize_cascade` merges layers plus
  `secret_relpaths`. Putting an SSH identity there hands it to a copy policy
  designed for a different credential class: agent A's config_dir used as the
  reference for agent B would give B a private key B was never granted a cap for.
  That is a code-logic accident, not an attack — exactly the class the project's
  gates exist to prevent.

  ## 部署契约（继承 1a §7，1b 增一条）

  租户隔离靠**不共享部署**（workspace = 部署单元），代码无强制。

  **同一部署内，两个 agent 是否隔离，完全取决于有没有各自发那条 `read_ssh_key`
  cap。** 本模块把目录移出 `config_dir`，就是为了让这句话在结构上成立 —— 否则
  cascade 复制会在运维不知情的情况下把它变成假话。
  """

  alias Ezagent.Resource.FsResolver
  alias Ezagent.URI, as: EzURI

  @dir_mode 0o700
  @type_name "git-identity"

  @doc "The registered FsResolver resource type / backend component name."
  @spec type() :: String.t()
  def type, do: @type_name

  @doc """
  The per-agent git-identity dir path. Pure.

  Raises `ArgumentError` on a non-agent URI — there is NO silent default
  workspace (mirrors `Ezagent.Sandbox.ConfigDir.path/2`).
  """
  @spec path(URI.t()) :: String.t()
  def path(%URI{} = agent_uri) do
    auth_ws = workspace_segment(agent_uri)
    name = name_segment(agent_uri)
    res_uri = EzURI.resource(auth_ws, @type_name, name)

    case FsResolver.resolve(res_uri, %{workspace: auth_ws}) do
      {:ok, path} ->
        path

      other ->
        raise RuntimeError,
              "git-identity dir resolution failed for #{URI.to_string(res_uri)}: " <>
                inspect(other)
    end
  end

  @doc "Allocate the per-agent git-identity dir: `mkdir_p` + `chmod 700`. Idempotent."
  @spec allocate(URI.t()) :: {:ok, String.t()} | {:error, term()}
  def allocate(%URI{} = agent_uri) do
    target = path(agent_uri)

    with :ok <- File.mkdir_p(target),
         :ok <- File.chmod(target, @dir_mode) do
      {:ok, target}
    else
      {:error, reason} -> {:error, {:git_identity_dir_allocate_failed, reason}}
    end
  end

  @doc """
  Destroy-time guard: the path being removed MUST equal the canonical `path/1`
  for this agent, so cleanup can never be handed a bogus or shared path.
  """
  @spec safe_to_destroy?(term(), URI.t()) :: boolean()
  def safe_to_destroy?(candidate, %URI{} = agent_uri) when is_binary(candidate) do
    Path.expand(candidate) == Path.expand(path(agent_uri))
  end

  def safe_to_destroy?(_candidate, _agent_uri), do: false

  # ── URI segments (same contract as Sandbox.ConfigDir) ───────────────────────

  defp workspace_segment(%URI{} = agent_uri) do
    case EzURI.type(agent_uri) do
      {:ok, "agent"} -> EzURI.workspace_name!(agent_uri)
      _ -> raise_agent_uri!(agent_uri)
    end
  end

  defp workspace_segment(other), do: raise_agent_uri!(other)

  defp name_segment(%URI{} = agent_uri) do
    case EzURI.type(agent_uri) do
      {:ok, "agent"} -> EzURI.name!(agent_uri)
      _ -> raise_agent_uri!(agent_uri)
    end
  end

  defp name_segment(other), do: raise_agent_uri!(other)

  defp raise_agent_uri!(other) do
    raise ArgumentError,
          "git-identity dir requires an entity agent URI — got #{inspect(other)}. " <>
            "There is NO silent default workspace; callers must pass a fully-formed URI."
  end
end
