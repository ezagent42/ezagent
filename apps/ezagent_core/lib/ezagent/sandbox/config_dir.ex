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
  """

  @config_dir_mode 0o700

  @doc """
  The per-agent config_dir TARGET path. Pure.

  Raises `ArgumentError` on a non-canonical agent URI (no silent default
  workspace — SPEC #324 rev 3 / PR #335).
  """
  @spec path(URI.t(), String.t()) :: String.t()
  def path(%URI{} = agent_uri, namespace) when is_binary(namespace) and namespace != "" do
    Path.join([
      Ezagent.Home.path("#{namespace}-agents"),
      workspace_segment(agent_uri),
      name_segment(agent_uri)
    ])
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
end
