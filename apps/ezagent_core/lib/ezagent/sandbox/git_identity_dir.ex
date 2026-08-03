defmodule Ezagent.Sandbox.GitIdentityDir do
  @moduledoc """
  SSH 凭据 1b — the single authority for the per-agent **git-identity dir**:
  path computation, allocation, and the destroy-time path-shape guard.

  Mirrors `Ezagent.Sandbox.ConfigDir` in shape, but is a DELIBERATELY SEPARATE
  directory family. See `Ezagent.Resource.FsResolver.git_identity_authority/2`
  for why sharing the config-dir authority function would misclassify this as
  a config-dir resource type (and see "Why NOT inside the agent's config_dir"
  below for why the directory itself is kept separate).

  ## Layout

      <Ezagent.Home.path("git-identity")>/<workspace>/<agent-name>/   (chmod 700)
      ├── id_ed25519      (chmod 600)
      └── known_hosts     (chmod 644)

  ## Why NOT inside the agent's config_dir

  `config_dir` is the home of the **flavor credential rail** (#17 cascade).
  Three reasons this identity does not live there (verified against today's
  code, not asserted):

  1. **Different copy-policy ownership.** The existing machinery already
     classifies everything under `config_dir` as either "config" (merged layer
     by layer) or "secret" (targeted copy via `secret_relpaths`). An SSH
     private key is neither — filing it under `config_dir` would force a false
     classification into one of the two, or require inventing a third
     copy-policy class just for this one file.
  2. **Different lifecycle and source.** `config_dir` content is materialized
     by the credential rail once, at agent CREATE. A git identity is
     rewritten on EVERY spawn (§1.3 of the design doc), sourced from a slice
     on a different Kind entirely (User) — not from any of the cascade's
     layers.
  3. **No reproducible leak exists today, but only because of a hardcoded
     list, not a structural guarantee.** `Ezagent.Credential.Resolver.
     resolve_layers/1` (`ezagent/credential/resolver.ex:95-108`) hardcodes
     exactly four config layers — `:flavor_base`, `:workspace`, `:user`,
     `:session` — and NONE of them is ever an agent URI, so there is no path
     today where one agent's config_dir is `cp_r`'d into another's. But that
     safety lives entirely in that one function's current layer list — nothing
     stops a future layer's source from becoming an agent URI. Filing the
     identity outside the reach of that copy machinery is what makes "同部署
     内两个 agent 是否隔离，完全取决于有没有各自发那条 cap" true WITHOUT
     depending on `resolver.ex`'s current four-layer list staying that way.

  ## 部署契约（继承 1a §7，1b 增一条）

  租户隔离靠**不共享部署**（workspace = 部署单元），代码无强制。

  **同一部署内，两个 agent 是否隔离，完全取决于有没有各自发那条 `read_ssh_key`
  cap。** 本模块把目录移出 `config_dir`，为的是让这句话**不必依赖**
  `resolver.ex:95-108` 那份四层 cascade 清单（`:flavor_base`/`:workspace`/
  `:user`/`:session`，见上面"Why NOT inside config_dir"第③点）未来也保持
  现状——今天那份清单里没有一层是 agent URI，不存在可复现的泄漏路径，但那
  只是清单当前恰好如此，不是结构性保证。把身份放在这套复制机制管不着的
  地方，让隔离这句话从"系于一处硬编码清单"升级成不依赖该清单的结构保证。
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

  Total function (F5 复审发现,G4 复审补全): a `(binary candidate, non-agent
  URI)` pair reaches `path/1`, which RAISES `ArgumentError` on a non-agent
  URI (`workspace_segment/1` / `name_segment/1`) — but an agent URI with an
  UNSAFE name segment (e.g. `".."` — `Ezagent.URI.segment!/1` does not
  reject `.`/`..`) passes those checks and instead makes `path/1` itself
  raise `RuntimeError` when `FsResolver.resolve/2` rejects the resolved
  `resource://` URI (same shape issue independently found in
  `Ezagent.Credential.GitIdentityRuntime.wipe/1`). Either would turn a
  destroy-time guard into a crash instead of a `false`; if destroy handling
  ever calls this and lets the exception propagate, cleanup aborts with the
  private key left on disk. Both are caught here so every input shape gets a
  boolean, per the `@spec`.
  """
  @spec safe_to_destroy?(term(), URI.t()) :: boolean()
  def safe_to_destroy?(candidate, %URI{} = agent_uri) when is_binary(candidate) do
    Path.expand(candidate) == Path.expand(path(agent_uri))
  rescue
    _e in [ArgumentError, RuntimeError] -> false
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
