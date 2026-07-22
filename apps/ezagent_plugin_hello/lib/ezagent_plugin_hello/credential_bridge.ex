defmodule EzagentPluginHello.CredentialBridge do
  @moduledoc """
  #185 — the `DEEPSEEK_API_KEY` env → curl credential bridge for the INTERNAL
  hello workspace.

  ## The gap this closes

  hello's `hello.llm` role is a curl-flavor member whose DeepSeek key is
  expected from the platform credential cascade (user default source, else
  workspace-shared source — `Ezagent.Credential.Resolver`). The
  `DEEPSEEK_API_KEY` env var only ever fed cc-flavor agents; NOTHING bridged it
  into a curl-usable credential source, so a freshly seeded hello app spawned
  its `llm` member with an EMPTY `:api_keys` slice and the visitor's first cold
  reply died with `{:no_api_key, "deepseek"}`.

  ## What this does (and deliberately does NOT do)

  The production entry point is `ensure_deepseek_source/0` — it takes NO
  arguments. When `DEEPSEEK_API_KEY` is present it idempotently:

    1. spawns (or reuses) a small curl-flavor **credential-source agent** in the
       LITERAL `"system"` workspace —
       `entity://system/agent/hello-deepseek-credential-source` — and stores the
       key in ITS `:api_keys` slice under `"deepseek"`;
    2. registers that agent as the `"system"` workspace's SHARED credential
       source for the `"curl"` flavor, via the EXISTING cap-checked + audited
       chokepoint `Ezagent.ActionSet.WorkspaceSharedCredentialSource`
       (`:set_workspace_shared_credential_source` — the single-writer lane, never
       a raw Repo write).

  Thereafter every hello `llm` member cold-spawned IN THE `"system"` WORKSPACE
  resolves the source through the unchanged cascade and is born with `"deepseek"`
  in its own `:api_keys` slice.

  ## Hard isolation constraint (the whole point)

  The destination is a compile-time LITERAL (`"system"`) — there is deliberately
  NO parameter and NO config override by which a caller could redirect the
  env-key seeding at an arbitrary workspace. Because this path both reads the
  real `DEEPSEEK_API_KEY` AND mints admin authority, a redirectable destination
  would be an isolation hole (the env key could be copied into any workspace);
  the zero-arity entry + literal destination closes it. #185 codex review.

  The source + the workspace-shared pointer therefore live in the `"system"`
  workspace ONLY. The shared hello TEMPLATE stays credential-OPTIONAL and carries
  NO `cascade_resolution.credential_source_uri`, so a hello agent spawned in ANY
  OTHER workspace still resolves NO source and stays keyless until that
  workspace's owner provides their own. Our key never leaks across workspaces.

  Tests that must seed OTHER workspaces do NOT call this module: they use a
  test-only fixture that takes an EXPLICIT key + workspace (never reads the
  production `DEEPSEEK_API_KEY` env) and sets the durable state up directly
  (never mints the production admin authority) — see
  `EzagentPluginHello.Integration.HelloCredentialSourceTest`.

  ## Activation

  Reads `System.get_env("DEEPSEEK_API_KEY")` at call time — the deploy env must
  carry the key for the bridge to activate (absent/empty → `{:ok, :no_env_key}`,
  hello agents keep today's keyless-spawn behavior). The boot caller
  (`EzagentPluginHello.Application`) additionally gates on the
  `:ezagent_plugin_hello, :credential_bridge_boot` config (dev/prod on, test
  off) so test boots stay deterministic even though `config/test.exs` installs
  a dummy key.
  """

  require Logger

  alias Ezagent.Entity.User
  alias Ezagent.Invocation

  @env_var "DEEPSEEK_API_KEY"
  @provider "deepseek"
  @flavor "curl"
  @source_agent_name "hello-deepseek-credential-source"

  # The env-key bridge destination is a compile-time LITERAL. It is NOT a
  # parameter and NOT config-overridable — the env key + admin authority may
  # only ever flow to the internal `"system"` workspace (isolation, #185 review).
  @system_workspace "system"

  @doc "The env var this bridge reads (`#{@env_var}`)."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc "The provider key the source slice holds (`#{@provider}`)."
  @spec provider() :: String.t()
  def provider, do: @provider

  @doc "The deterministic credential-source agent name in the `\"system\"` workspace."
  @spec source_agent_name() :: String.t()
  def source_agent_name, do: @source_agent_name

  @doc """
  Should the boot-time bridge Task start? Config-gated (dev/prod on via
  `config.exs`; test off via `config/test.exs`) AND env-key-gated — with no
  key there is nothing to bridge, so the Task is never started.
  """
  @spec boot_enabled?() :: boolean()
  def boot_enabled? do
    Application.get_env(:ezagent_plugin_hello, :credential_bridge_boot, false) and
      env_key_present?()
  end

  @doc """
  Idempotently bridge `DEEPSEEK_API_KEY` into the `"system"` workspace's shared
  curl credential source.

  Zero-arity BY DESIGN: the destination is the compile-time literal `"system"`,
  never a caller-supplied workspace (see the isolation note in the moduledoc) —
  this env-reading + admin-minting path must not be pointable at an arbitrary
  workspace.

  Returns `{:ok, source_uri}` when `"system"` now has the shared source
  registered (seeded by this call or already in place), `{:ok, :no_env_key}`
  when the env var is absent/empty (a deliberate no-op — keyless spawn stays
  the deployment's truth), or `{:error, reason}` on a real failure.
  """
  @spec ensure_deepseek_source() ::
          {:ok, URI.t()} | {:ok, :no_env_key} | {:error, term()}
  def ensure_deepseek_source do
    case env_key() do
      {:ok, :no_env_key} ->
        {:ok, :no_env_key}

      {:ok, key} ->
        with :ok <- ensure_workspace(@system_workspace),
             {:ok, source_uri} <- ensure_source_agent(@system_workspace),
             :ok <- put_api_key(source_uri, key),
             :ok <- await_snapshot(source_uri),
             :ok <- ensure_workspace_shared_source(@system_workspace, source_uri) do
          {:ok, source_uri}
        end
    end
  end

  # --- env -------------------------------------------------------------------

  defp env_key do
    case System.get_env(@env_var) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:ok, :no_env_key}
    end
  end

  defp env_key_present?, do: match?(k when is_binary(k) and k != "", System.get_env(@env_var))

  defp ensure_workspace(workspace) do
    case Ezagent.Workspace.Store.get_by_name(workspace) do
      nil ->
        case Ezagent.Workspace.create(workspace, %{created_by: User.admin_uri()}) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, {:workspace, reason}}
        end

      _workspace ->
        :ok
    end
  end

  # --- the credential-source agent ---------------------------------------------

  # A curl credential source is an `Entity.Agent` with the curl per-instance
  # behavior set (so its `:api_keys` slice exists + persists), the stored
  # `curl` flavor attribute (the workspace-shared chokepoint validates it), and
  # the key in its slice. The same shape the `curl.agent` Template spawns.
  defp ensure_source_agent(workspace) do
    source_uri = Ezagent.URI.entity(workspace, :agent, @source_agent_name)
    :ok = Ezagent.AgentFlavorAttributes.put(source_uri, @flavor)

    # derivation-edge: recorded-by AgentLineage.record/2 on the fresh branch
    case Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
           uri: source_uri,
           behaviors: Ezagent.Entity.Agent.curl_behaviors()
         }) do
      {:ok, _pid} ->
        :ok = Ezagent.AgentLineage.record(source_uri, User.admin_uri())
        {:ok, source_uri}

      {:error, {:already_started, _pid}} ->
        {:ok, source_uri}

      {:error, {:already_registered, _uri}} ->
        {:ok, source_uri}

      {:error, reason} ->
        {:error, {:source_agent_spawn, reason}}
    end
  end

  # The SAME authorized lane the `curl.agent` Template uses to write a resolved
  # key into an agent's slice: an admin-issued action cap + a `:call` dispatch
  # to the agent's own `ApiKeys` behavior. No raw slice writes — and no raw
  # slice READS either (`:api_keys` is a sensitive slice; the
  # SensitiveSliceRead invariant gate forbids un-allowlisted `get_slice` on it).
  # Re-putting is idempotent, so a re-run / reboot converges — and a rotated
  # env key overwrites the stale one.
  defp put_api_key(source_uri, key) do
    admin = User.admin_uri()
    target = Ezagent.URI.with_action(source_uri, :api_keys, :put_api_key)

    with {:ok, cap} <- Ezagent.Cap.issue_for_action({:admin, admin}, admin, target),
         {:ok, _result} <-
           Invocation.dispatch(%Invocation{
             target: target,
             mode: :call,
             args: %{provider: @provider, key: key},
             ctx: %{
               caller: admin,
               authenticated_principal: admin,
               caps: MapSet.new([cap]),
               reply: {:caller_inbox, self()}
             },
             origin: :trusted_internal
           }) do
      :ok
    end
  end

  # The workspace-shared chokepoint validates source EXISTENCE via
  # `Ezagent.SnapshotStore.latest/1`; the slice persist above is on-change and
  # normally already durable — poll briefly so a slow commit cannot race the
  # validation.
  defp await_snapshot(source_uri, attempts \\ 200)
  defp await_snapshot(_source_uri, 0), do: {:error, :source_snapshot_not_durable}

  defp await_snapshot(source_uri, attempts) do
    case Ezagent.SnapshotStore.latest(source_uri) do
      {:ok, _} -> :ok
      _ -> Process.sleep(10) && await_snapshot(source_uri, attempts - 1)
    end
  end

  # --- the workspace-shared pointer (cap-checked single-writer lane) -----------

  defp ensure_workspace_shared_source(workspace, source_uri) do
    workspace_uri = Ezagent.URI.workspace(workspace)
    source_str = URI.to_string(source_uri)

    case Ezagent.Credential.WorkspaceSharedSource.resolve(URI.to_string(workspace_uri), @flavor) do
      ^source_str ->
        :ok

      _other ->
        dispatch_set_workspace_shared(workspace_uri, source_str)
    end
  end

  defp dispatch_set_workspace_shared(workspace_uri, source_str) do
    admin = User.admin_uri()

    target =
      Ezagent.URI.with_action(
        workspace_uri,
        :workspace_shared_credential_source,
        :set_workspace_shared_credential_source
      )

    with {:ok, cap} <- Ezagent.Cap.issue_for_action({:admin, admin}, admin, target),
         {:ok, _result} <-
           Invocation.dispatch(%Invocation{
             target: target,
             mode: :call,
             args: %{flavor: @flavor, source_uri: source_str},
             ctx: %{
               caller: admin,
               authenticated_principal: admin,
               caps: MapSet.new([cap]),
               reply: {:caller_inbox, self()}
             },
             origin: :trusted_internal
           }) do
      Logger.info(
        "hello credential bridge: #{@provider} key bridged into " <>
          "#{URI.to_string(workspace_uri)} shared curl credential source #{source_str}"
      )

      :ok
    end
  end
end
