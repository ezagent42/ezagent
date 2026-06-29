defmodule Ezagent.Sandbox.ConfigDir do
  @moduledoc """
  PR-3 (domain.agent §3.1.2/§3.1.3, D2) — the single authority for the per-agent
  **config_dir TARGET**: path computation, directory allocation, and the
  destroy-time path-shape guard.

  Per D2 "domain allocates, plugin materializes" the per-agent config-home
  location is owned by the domain (the *sandbox* concept), NOT the flavor plugin.
  Flavor plugins receive the allocated path as DATA and materialize content into
  it; they never choose where it lives (North-Star plugin isolation). The path
  authority moved here from `EzagentPluginCc.CcAgent.agent_config_dir/1`.

  ## Layout (byte-identical to the pre-PR-3 cc layout for namespace `"cc"`)

      <Ezagent.Home.path("<namespace>-agents")>/<workspace>/<name>/   (chmod 700)

  The `namespace` (e.g. `"cc"`) is resolved from the agent's Template Class, not
  from template data — see `Ezagent.Kind.Template` `config_dir_namespace/0`.

  ## Resolution seam (Resource-unification P1)

  `path/2` no longer builds the raw `Home.path("<ns>-agents")/<ws>/<name>` string
  directly. It now resolves through the hardened
  `Ezagent.Resource.FsResolver` via `resource://<ws>/<ns>-agents/<name>`, which is
  the sanctioned single `Home.path` chokepoint for tenant-scoped artifacts. The
  resolved string is **byte-identical** to the pre-P1 layout (Locked-contract #7,
  pinned by `ConfigDirParityTest`).

  The authenticated `scope.workspace` is derived from the **agent URI** (the
  subject this function is materializing) and the `resource://` URI is
  *constructed* from that same workspace — so a caller cannot forge a
  cross-`<ws>` resource URI here; the resolver's `authority/2` is therefore
  non-tautological (codex CRITICAL).
  """

  alias Ezagent.Resource.FsResolver
  alias Ezagent.URI, as: EzURI

  @config_dir_mode 0o700

  @doc """
  The per-agent config_dir TARGET path. Pure.

  Raises `ArgumentError` on a non-canonical agent URI (no silent default
  workspace — SPEC #324 rev 3 / PR #335).
  """
  @spec path(URI.t(), String.t()) :: String.t()
  def path(%URI{} = agent_uri, namespace) when is_binary(namespace) and namespace != "" do
    # The authenticated subject = the AGENT uri. Derive its authoritative
    # workspace + name independently, then *construct* the resource:// URI from
    # that same authenticated workspace (so the resolver's authority/2 is not
    # tautological — the URI's <ws> is, by construction, the agent's own ws).
    auth_ws = workspace_segment(agent_uri)
    name = name_segment(agent_uri)
    res_uri = EzURI.resource(auth_ws, "#{namespace}-agents", name)

    case FsResolver.resolve(res_uri, %{workspace: auth_ws}) do
      {:ok, path} ->
        path

      other ->
        # The config-dir type is registered at boot and the URI is constructed
        # from the agent's own ws, so this is unreachable in a correctly-booted
        # node — fail loud rather than silently mis-locate per-agent state.
        raise RuntimeError,
              "config-dir resolution failed for #{URI.to_string(res_uri)}: #{inspect(other)}"
    end
  end

  @doc """
  Allocate the per-agent config_dir: `mkdir_p` + `chmod 700`. The GENERIC
  allocation only — content materialization (credentials, skills, `.mcp.json`) is
  the plugin's job. Idempotent (DD-7): a repeated call re-mkdirs the same path.
  """
  @spec allocate(URI.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def allocate(%URI{} = agent_uri, namespace) do
    target = path(agent_uri, namespace)

    with :ok <- File.mkdir_p(target),
         :ok <- File.chmod(target, @config_dir_mode) do
      {:ok, target}
    else
      {:error, reason} -> {:error, {:config_dir_allocate_failed, reason}}
    end
  end

  @doc """
  Destroy-time guard (defense-in-depth): the path being removed MUST equal the
  canonical `path/2` for this agent + namespace. Replaces the plugin's former
  `== agent_config_dir(uri)` assertion so cleanup can never be handed a bogus or
  shared path.
  """
  @spec safe_to_destroy?(String.t(), URI.t(), String.t()) :: boolean()
  def safe_to_destroy?(candidate, %URI{} = agent_uri, namespace) when is_binary(candidate) do
    Path.expand(candidate) == Path.expand(path(agent_uri, namespace))
  end

  def safe_to_destroy?(_candidate, _agent_uri, _namespace), do: false

  # ── URI segments (relocated verbatim from EzagentPluginCc.CcAgent — PR-3 moves
  #    the path authority to core) ──────────────────────────────────────────────

  defp workspace_segment(%URI{} = agent_uri) do
    case Ezagent.URI.type(agent_uri) do
      {:ok, "agent"} -> Ezagent.URI.workspace_name!(agent_uri)
      _ -> raise_agent_uri!(agent_uri)
    end
  end

  defp workspace_segment(other), do: raise_agent_uri!(other)

  defp name_segment(%URI{} = agent_uri) do
    case Ezagent.URI.type(agent_uri) do
      {:ok, "agent"} -> Ezagent.URI.name!(agent_uri)
      _ -> "unknown"
    end
  rescue
    ArgumentError -> "unknown"
  end

  defp name_segment(_), do: "unknown"

  defp raise_agent_uri!(other) do
    raise ArgumentError,
          "agent URI is not an entity agent URI — got #{inspect(other)}. " <>
            "Per SPEC #324 rev 3 / PR #335, there is NO silent default workspace fallback; " <>
            "callers must pass a fully-formed URI."
  end

  @doc """
  Validate that a project_cwd is within an allowed root (security: prevents
  agents from running in arbitrary host paths like ~/.ssh or /etc).

  Allowed roots:
  1. The agent's own config_dir (the default — per-agent home).
  2. Operator-configured roots via EZAGENT_ALLOWED_CWD_ROOTS (colon-separated).
  """
  @spec validate_project_cwd(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, {:cwd_outside_allowed_roots, String.t()}}
  def validate_project_cwd(cwd, config_dir)
      when is_binary(cwd) and is_binary(config_dir) do
    expanded = Path.expand(cwd)

    operator_roots =
      (System.get_env("EZAGENT_ALLOWED_CWD_ROOTS") || "")
      |> String.split(":", trim: true)
      |> Enum.map(&Path.expand/1)

    if Enum.any?([config_dir | operator_roots], &within_root?(expanded, &1)) do
      {:ok, expanded}
    else
      {:error, {:cwd_outside_allowed_roots, expanded}}
    end
  end

  @doc """
  Validate a project_cwd or fall back to the agent config_dir.
  """
  @spec validate_project_cwd_or_default!(String.t() | nil, String.t()) :: String.t()
  def validate_project_cwd_or_default!(nil, config_dir), do: config_dir
  def validate_project_cwd_or_default!("", config_dir), do: config_dir

  def validate_project_cwd_or_default!(cwd, config_dir) when is_binary(cwd) do
    case validate_project_cwd(cwd, config_dir) do
      {:ok, expanded} ->
        expanded

      {:error, {:cwd_outside_allowed_roots, path}} ->
        raise ArgumentError,
              "project_cwd #{inspect(path)} is outside allowed roots. " <>
                "Set EZAGENT_ALLOWED_CWD_ROOTS (colon-separated) to allow additional paths."
    end
  end

  defp within_root?(path, root) do
    expanded_root = Path.expand(root)
    path == expanded_root or String.starts_with?(path, expanded_root <> "/")
  end
end
