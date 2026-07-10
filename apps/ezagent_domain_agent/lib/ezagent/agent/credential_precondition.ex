defmodule Ezagent.Agent.CredentialPrecondition do
  @moduledoc """
  Can this agent's flavor be brought up for this installer at all?

  ## Why this exists (chain C, 2026-07-10)

  `Ezagent.Agent.HostLoginAdopt`'s no-op ladder deliberately refuses to flow the
  node operator's Claude login to an agent a **non-admin** installer caused to
  exist (#161 / DoD 6): "the host login belongs to the node operator; it must
  NEVER flow to agents a co-tenant caused to exist". Non-admin installers "keep
  today's resolution (their own pointer, else workspace-shared, else NONE)".

  When the answer is NONE, the materializer still copies the flavor's reference
  config home and `stage_and_swap/7` writes `.ezagent-config-complete`
  UNCONDITIONALLY — so the per-agent home is "complete" and has no credentials.
  Everything downstream then succeeds SILENTLY: the socialware install returns
  `:ok`, the role agent joins the session, the PTY launches, and `claude` boots
  "Not logged in". `esr-bridge` never joins, `require_transport_join/1` never
  resolves, and the agent's ReadyGate sits at `:not_ready` forever — the
  "@orchestrator never replies" symptom, with no error anywhere.

  This is the same defect #1311 fixed for `cc-headless` (a missing
  `host_login_dir/0` delegate), reached by a different route.

  ## The rule

  **Automatic materialization** (socialware role slots, seeds, the stock
  orchestrator) has no human at the terminal, so an agent that cannot
  authenticate is worthless. Such an agent is NOT created: the role slot is
  skipped, loudly, and the rest of the batch continues.

  **Explicit agent creation** by a user is untouched: a user may deliberately
  create a credential-less cc agent and run `claude /login` inside its PTY
  (Allen, 2026-07-10). That is why this check lives in the automatic lane and
  NOT in `Ezagent.Credential.HomeRuntime`, which both lanes share.
  """

  alias Ezagent.Credential.{HomeRuntime, UserDefaultSource, WorkspaceSharedSource}

  @doc """
  True when `flavor`'s Template Class declares credential files it cannot run
  without (`credential_relpaths/0`). `py` / `curl` / `native` declare none.
  """
  @spec credential_bearing?(String.t()) :: boolean()
  def credential_bearing?(flavor) when is_binary(flavor) do
    case template_class(flavor) do
      {:ok, module} -> credential_relpaths(module) != []
      _ -> false
    end
  end

  @doc """
  `:ok` when a credential source resolves for `(installer, workspace, flavor)`,
  else `{:skip, {:no_credential_source, flavor}}`.

  Call this AFTER `HostLoginAdopt.ensure_installer_source/3` — for the host
  operator that call registers the pointer this reads, so the admin path
  resolves and is never skipped.
  """
  @spec check_source(URI.t(), URI.t(), String.t()) :: :ok | {:skip, term()}
  def check_source(%URI{} = installer, %URI{} = workspace_uri, flavor)
      when is_binary(flavor) do
    cond do
      not credential_bearing?(flavor) -> :ok
      source_available?(installer, workspace_uri, flavor) -> :ok
      true -> {:skip, {:no_credential_source, flavor}}
    end
  end

  @doc """
  `:ok` when the freshly materialized per-agent config home actually carries one
  of the flavor's `credential_relpaths/0`, else
  `{:skip, {:config_home_without_credentials, flavor}}`.

  The safety net for the class `check_source/3` cannot see: a source that
  resolves but whose copy silently produces nothing (#1311's missing
  `host_login_dir/0` delegate was exactly this).
  """
  @spec check_materialized(URI.t(), String.t()) :: :ok | {:skip, term()}
  def check_materialized(%URI{} = agent_uri, flavor) when is_binary(flavor) do
    with {:ok, module} <- template_class(flavor),
         [_ | _] = relpaths <- credential_relpaths(module) do
      dir = HomeRuntime.agent_config_dir(agent_uri, module)

      if Enum.any?(relpaths, fn rel ->
           path = Path.join(dir, rel)
           File.exists?(path) and not File.dir?(path) and File.stat!(path).size > 0
         end) do
        :ok
      else
        {:skip, {:config_home_without_credentials, flavor}}
      end
    else
      # Unknown flavor or credential-less flavor — nothing to require.
      _ -> :ok
    end
  end

  defp source_available?(installer, workspace_uri, flavor) do
    ws_name = Ezagent.URI.workspace_name!(workspace_uri)

    not is_nil(UserDefaultSource.resolve(URI.to_string(installer), ws_name, flavor)) or
      not is_nil(WorkspaceSharedSource.resolve(workspace_uri, flavor))
  end

  defp template_class(flavor), do: Ezagent.AgentFlavorRegistry.template_class_for(flavor)

  # `credential_relpaths/0` is an `@optional_callbacks` CredentialAdapter member,
  # so an omission compiles clean — see `credential_adapter_completeness_test`.
  defp credential_relpaths(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :credential_relpaths, 0) do
      module.credential_relpaths()
    else
      []
    end
  end
end
