defmodule EzagentPluginAutoservice.AutoserviceAssembly do
  @moduledoc """
  Wiring coordinator — delegates to content/cr plugin, workspace, cc agent.

  The assembly layer sits above `CustomerSession` and adds:
  - preview provisioning (sandbox data, preview session)
  - preview teardown
  - direct soul-slot writes that fan out to CR lint

  ## Relationship to CustomerSession

  `CustomerSession.provision/2` is the seed-time full assembly for production.
  `AutoserviceAssembly.provision_agent/2` is the lighter coordinator that
  materializes the work dir, reads agent config, and delegates agent creation
  to Workspace (curl template for fast, cc for slow).
  """

  alias EzagentPluginContent.Soul.SoulStore
  alias EzagentPluginContent.Tenant.TenantRuntime
  alias EzagentPluginCr.CrEngine

  @skeleton_config_dir Path.join(:code.priv_dir(:ezagent_plugin_content), "skeleton/config")

  @doc """
  Provision a tenant agent team (fast + slow) and return work dir + config.

  Returns `{:ok, %{work_dir: binary(), fast_cfg: map(), slow_cfg: map()}}`.
  """
  @spec provision_agent(String.t(), String.t()) ::
          {:ok, %{work_dir: binary(), fast_cfg: map(), slow_cfg: map()}}
          | {:error, term()}
  def provision_agent(tid, role) do
    agents = read_agents_config()
    fast_cfg = agents["fast"]
    slow_cfg = agents["slow"]
    work_dir = TenantRuntime.materialize(tid, role, :release)
    {:ok, %{work_dir: work_dir, fast_cfg: fast_cfg, slow_cfg: slow_cfg}}
  end

  @doc """
  Preview provisioning: sandbox data + preview session URI.

  Returns `{:ok, %{session_uri: URI.t(), work_dir: binary()}}`.
  """
  @spec preview_provision(String.t(), String.t(), URI.t()) ::
          {:ok, %{session_uri: URI.t(), work_dir: binary()}}
          | {:error, term()}
  def preview_provision(tid, role, _admin_uri) do
    work_dir = TenantRuntime.materialize(tid, role, :sandbox)
    # Build a preview session URI scoped to the tenant.
    preview_name = "preview-#{tid}-#{role}"
    session_uri = Ezagent.URI.new!("session://cs/#{tid}/#{preview_name}")
    {:ok, %{session_uri: session_uri, work_dir: work_dir}}
  end

  @doc """
  Cleanup preview agents + session + work dir.
  """
  @spec preview_teardown(URI.t()) :: :ok
  def preview_teardown(_session_uri) do
    # TODO: Phase T1A.2 — destroy session Kind + templates + work dir
    :ok
  end

  @doc """
  Write a soul slot value and ensure an active CR exists for the tenant.

  Delegates to `SoulStore.write_slots/5` with `:sandbox` source so the
  operator can preview before publishing, then fans out to `CrEngine`
  to ensure a CR is open.
  """
  @spec write_slot(String.t(), String.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def write_slot(tid, role, _section_id, key, val) do
    with :ok <- SoulStore.write_slots(TenantRuntime.base_dir(), tid, role, %{key => val}, :sandbox),
         {:ok, _cr} <- CrEngine.ensure_active_cr(tid) do
      :ok
    end
  end

  # --- internals ---

  defp read_agents_config do
    path = Path.join(@skeleton_config_dir, "agents.yaml")

    if File.exists?(path) do
      case YamlElixir.read_from_file(path) do
        {:ok, cfg} -> cfg
        {:error, _} -> %{"fast" => %{}, "slow" => %{}}
      end
    else
      %{"fast" => %{}, "slow" => %{}}
    end
  end
end
