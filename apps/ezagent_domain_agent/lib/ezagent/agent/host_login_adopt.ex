defmodule Ezagent.Agent.HostLoginAdopt do
  @moduledoc """
  #1201 finding A② — make the socialware INSTALLER's host login inheritable by
  the agents their install materializes, THROUGH the existing #17 credential
  cascade (never an ad-hoc file copy at a materialization callsite).

  ## The gap this closes

  `SessionCreator.materialize_template_team/4` → `DefinitionAgents` already
  threads the installer as the cascade `owner_uri` (and as the grant-mint
  `caller`), so a materialized file-flavor agent inherits credentials whenever
  the installer HAS a #17 user-default source pointer. What no framework path
  ever did is ESTABLISH that pointer from the installer's HOST login — so on a
  fresh node every socialware install produced isolated, EMPTY config homes
  ("Not logged in") unless an operator hand-ran `mix ezagent.credential.adopt`.

  ## What `ensure_installer_source/3` does

  A pre-spawn, idempotent AUTO-ADOPT of the host login, for exactly one
  installer identity — the HOST OPERATOR (the genesis admin; shell access =
  admin authority, in-VM trust §10.5, same doctrine as
  `Mix.Tasks.Ezagent.Credential.Adopt`):

    1. no-op (`:ok`) unless the flavor's Template Class is a credentialled
       `Ezagent.Agent.CredentialAdapter` with a USABLE
       `host_login_source_dir/1` (py/curl and login-less nodes fall through
       untouched — DoD 4);
    2. no-op unless the installer IS the genesis admin — the host login belongs
       to the node operator; it must NEVER flow to agents a co-tenant caused to
       exist (#161 / DoD 6). Non-admin installers keep today's resolution
       (their own pointer, else workspace-shared, else none);
    3. no-op when the installer already has a user-default pointer for
       `(installer, workspace, flavor)` that is NOT ours — an explicit operator
       choice is never overridden. When the pointer IS ours, the durable
       registration is refreshed (the host home may have moved via env);
    4. otherwise REGISTER the host login as a durable #17 source (a
       per-workspace `<flavor>-host-login` source registration: durable
       sandbox `config_dir_path` + `flavor` — the exact shape
       `UriQuery.resolve(:config_dir | :flavor, source)` and
       `Resolver.default_source_available?/1` read, so cold-restart
       re-resolution through `Ezagent.Credential.CascadeRuntime` keeps working
       — plus an `AgentLineage` owner edge) and SET the pointer through the
       SANCTIONED cap-checked chokepoint
       (`UserDefaultSource.set_via_dispatch/3`, single-writer invariant), under
       the installer's own live caps.

  After this, the UNCHANGED #17 cascade does everything else: resolution picks
  the pointer, the grant is minted (installer caps → `sandbox.read` on the
  source), the flavor materializer layer-merges config and copies ONLY the
  secret (§D6), and respawn re-resolves from durable inputs.
  """

  alias Ezagent.Agent.CredentialAdapter
  alias Ezagent.Credential.UserDefaultSource

  require Logger

  @doc """
  Ensure the installer's host login is adopted as their #17 user-default source
  for `flavor` in `workspace_uri` (see the moduledoc for the no-op ladder).

  Returns `:ok` for every no-op branch; `{:error, {:host_login_adopt_failed,
  reason}}` when the adopt is applicable but the sanctioned pointer write fails
  (fail-loud — a silent skip here would reproduce the exact "Not logged in"
  symptom this seam exists to fix).
  """
  @spec ensure_installer_source(URI.t(), URI.t(), String.t()) :: :ok | {:error, term()}
  def ensure_installer_source(%URI{} = installer_uri, %URI{} = workspace_uri, flavor)
      when is_binary(flavor) do
    with {:ok, template_class} <- Ezagent.AgentFlavorRegistry.template_class_for(flavor),
         {:ok, host_dir} <- CredentialAdapter.host_login_source_dir(template_class),
         :ok <- require_host_operator(installer_uri) do
      adopt(installer_uri, workspace_uri, flavor, host_dir)
    else
      # Every structural miss is a clean no-op: unknown flavor (the spawn will
      # fail loud on its own), credential-less flavor, no host-login concept,
      # no usable host login on this node, or a non-operator installer.
      :none -> :ok
      :not_host_operator -> :ok
      {:error, {:unknown_flavor, _}} -> :ok
      {:error, {:flavor_has_no_template_class, _}} -> :ok
    end
  end

  # --- adopt --------------------------------------------------------------

  defp adopt(installer_uri, workspace_uri, flavor, host_dir) do
    ws_name = Ezagent.URI.workspace_name!(workspace_uri)
    source_uri = host_login_source_uri(ws_name, flavor)
    owner = URI.to_string(installer_uri)

    case UserDefaultSource.resolve(owner, ws_name, flavor) do
      nil ->
        with :ok <- register_source(source_uri, installer_uri, flavor, host_dir) do
          set_pointer(installer_uri, ws_name, flavor, source_uri)
        end

      existing when is_binary(existing) ->
        if existing == URI.to_string(source_uri) do
          # Our own registration — refresh the durable dir (env may have moved
          # the host home between installs). Never touches the pointer.
          register_source(source_uri, installer_uri, flavor, host_dir)
        else
          # An explicit operator-chosen source — never overridden.
          :ok
        end
    end
  end

  @doc """
  The deterministic per-workspace host-login source URI for `flavor`
  (`entity://<ws>/agent/<flavor>-host-login`). Deterministic so repeated
  installs refresh ONE registration instead of accreting sources.
  """
  @spec host_login_source_uri(String.t(), String.t()) :: URI.t()
  def host_login_source_uri(ws_name, flavor) when is_binary(ws_name) and is_binary(flavor) do
    Ezagent.URI.agent(ws_name, "#{flavor}-host-login")
  end

  # Durable #17 source registration. The snapshot carries the exact fields the
  # existing read seams consume: `:sandbox`/`config_dir_path` for
  # `UriQuery.resolve(:config_dir, source)` (materialize + cold-restart
  # re-resolution) and `:flavor` for `UriQuery.resolve(:flavor, source)` (the
  # pointer chokepoint's source-flavor validation). The `AgentLineage` edge is
  # the durable owner signal the chokepoint's owner validation reads.
  defp register_source(source_uri, installer_uri, flavor, host_dir) do
    case Ezagent.SnapshotStore.write(
           URI.to_string(source_uri),
           %{sandbox: %{state: %{config_dir_path: host_dir, flavor: flavor}}},
           kind_type: :agent
         ) do
      {:ok, _} ->
        :ok = Ezagent.AgentLineage.record(source_uri, installer_uri)
        :ok

      {:error, reason} ->
        {:error, {:host_login_adopt_failed, {:source_registration, reason}}}
    end
  end

  # The pointer write goes through the SINGLE sanctioned chokepoint (cap-checked
  # + audited `:set_default_credential_source` dispatch on the installer's own
  # User Kind), under the installer's live caps — never a raw insert.
  defp set_pointer(installer_uri, ws_name, flavor, source_uri) do
    source = URI.to_string(source_uri)

    result =
      UserDefaultSource.set_via_dispatch(
        installer_uri,
        %{flavor: flavor, source_uri: source, workspace: ws_name},
        %{caller: installer_uri, caps: Ezagent.Identity.list_caps_for(installer_uri)}
      )

    case result do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        # Concurrent-install tolerance: if another materialization already
        # landed the SAME pointer, the state we wanted exists — proceed.
        if UserDefaultSource.resolve(URI.to_string(installer_uri), ws_name, flavor) == source do
          :ok
        else
          {:error, {:host_login_adopt_failed, reason}}
        end
    end
  end

  # --- gates ----------------------------------------------------------------

  # The host login belongs to the HOST OPERATOR — the genesis admin entity
  # (shell access = admin authority, §10.5; same identity the sanctioned
  # `mix ezagent.credential.adopt` operates under). Any other installer keeps
  # the standard #17 resolution for THEIR identity (DoD 6 / #161: host
  # credentials never flow to agents a co-tenant caused to exist).
  defp require_host_operator(%URI{} = installer_uri) do
    if URI.to_string(installer_uri) == URI.to_string(Ezagent.Entity.User.admin_uri()) do
      :ok
    else
      :not_host_operator
    end
  end
end
