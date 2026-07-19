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

  #185 extends the same rule to SLICE-backed flavors (curl): a role whose
  recipe declares a REQUIRED credential but resolves no source is skipped at
  provisioning instead of spawning keyless and dying at first use. Recipes
  that intend keyless (`credential_optional`, e.g. hello.llm) opt out and are
  untouched.

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
  or when an environment-backed credential reports `:authenticated`.

  Returns `{:skip, {:no_credential_source, flavor}}` when a file-backed flavor
  has no source, `{:skip, {:no_credential_source, flavor}}` when a SLICE-backed
  flavor (curl — the key lives in the agent's `:api_keys` slice) declares a
  REQUIRED credential and has no source, or
  `{:skip, {:credential_unavailable, flavor}}` when an
  environment-backed flavor reports a non-authenticated status.

  Call this AFTER `HostLoginAdopt.ensure_installer_source/3` — for the host
  operator that call registers the pointer this reads, so the admin path
  resolves and is never skipped.

  `opts[:backend_profile]` (cc-custom) names the SELECTED backend profile
  whose API-key env var is probed — the caller threads it from the role slot's
  `provider`. Absent, an environment-backed flavor probes its DEFAULT
  credential (legacy flavors unchanged); a profile-driven flavor with no
  profile context fails CLOSED (`:unknown` → skip, never a silent pass).

  `opts[:credential_optional]` (#185) is the recipe's declared opt-OUT of the
  slice-backed precondition (recipe config → AgentTemplate content, the SAME
  flag the cascade's `credential_required?/2` reads — e.g. hello.llm keyless
  spawns by design). Absent/false, a slice-backed flavor's credential is
  REQUIRED (the slice default, mirroring the cascade), so a role resolving no
  source fails LOUD here at provisioning instead of silently at the visitor's
  first reply (`{:no_api_key, provider}`).
  """
  @spec check_source(URI.t(), URI.t(), String.t(), keyword()) :: :ok | {:skip, term()}
  def check_source(%URI{} = installer, %URI{} = workspace_uri, flavor, opts \\ [])
      when is_binary(flavor) and is_list(opts) do
    case template_class(flavor) do
      {:ok, module} -> check_source(module, installer, workspace_uri, flavor, opts)
      _ -> :ok
    end
  end

  @doc """
  `:ok` when the freshly materialized per-agent config home actually carries one
  of the flavor's `credential_relpaths/0`, else
  `{:skip, {:config_home_without_credentials, flavor}}`.

  The safety net for the class `check_source/4` cannot see: a source that
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

  defp check_source(module, installer, workspace_uri, flavor, opts) do
    cond do
      credential_relpaths(module) != [] ->
        if source_available?(installer, workspace_uri, flavor),
          do: :ok,
          else: {:skip, {:no_credential_source, flavor}}

      slice_credentialled?(module) ->
        # #185 — a SLICE-backed flavor (curl: the key lives in the agent's
        # `:api_keys` slice, not in config-home files, and there is no env
        # probe) used to fall through to `:ok` here, so a curl role that
        # DECLARES a required credential spawned keyless and only failed at
        # the visitor's first reply. Now the precondition fires at
        # provisioning — unless the recipe marks the credential optional
        # (hello.llm), which keeps its intentional keyless spawn.
        if credential_optional?(opts) or source_available?(installer, workspace_uri, flavor),
          do: :ok,
          else: {:skip, {:no_credential_source, flavor}}

      environment_credential?(module) ->
        case module.credential_status(nil, backend_profile: opts[:backend_profile]) do
          %{status: :authenticated} -> :ok
          _ -> {:skip, {:credential_unavailable, flavor}}
        end

      true ->
        :ok
    end
  end

  # `credential_optional` rides from the recipe's `config` through the role
  # slot (see `DefinitionAgents.check_credential_source/5`). Tolerate the same
  # `[true, "true"]` shapes the cascade's content-level override accepts.
  defp credential_optional?(opts), do: opts[:credential_optional] in [true, "true"]

  defp slice_credentialled?(module),
    do: Ezagent.Agent.CredentialSliceAdapter.credentialled?(module)

  defp template_class(flavor), do: Ezagent.AgentFlavorRegistry.template_class_for(flavor)

  defp environment_credential?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :credential_status, 2)
  end

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
