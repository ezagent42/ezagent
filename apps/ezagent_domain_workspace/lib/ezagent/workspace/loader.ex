defmodule Ezagent.Workspace.Loader do
  @moduledoc """
  Loads persisted Workspaces at app start (Phase 4c).

  ## Flow

  1. Query `Ezagent.Workspace.Store.list_all/0` for every persisted Workspace
  2. For each, spawn the Workspace Kind via
     `Ezagent.Workspace.spawn_workspace/2` so its slice carries the
     persisted members + templates + rules
  3. Dispatch `:instantiate` on the live Workspace and walk the returned
     children list, calling `Ezagent.SpawnRegistry.spawn/1` for each member
     URI

  ## Why this lives in ezagent_core (not a plugin)

  Per Phase 4 north star (plugin isolation), ezagent_core orchestrates the
  Workspace lifecycle but never reaches into plugin supervisors. The
  spawn fns are injected by plugins via `Ezagent.SpawnRegistry.register/2`,
  so the Loader stays plugin-agnostic.

  ## Timing

  Called from `EzagentCore.Application.start/2` after plugins have had a
  chance to register their spawn fns. Plugin Applications **must**
  register their schemes before any Workspace declaring those schemes
  loads. We currently rely on Application start order (ezagent_core ⊂
  ezagent_domain_session) — chat plugin registers `agent`/`session`/`user`
  schemes in its own start callback, and at that point chat plugin
  also calls `Ezagent.Workspace.Loader.load_all/0` (so the Loader runs
  AFTER schemes are registered).

  Phase 5 may move this to an explicit "all plugins ready" gate.
  """

  require Logger

  alias Ezagent.{Cmd, Router, SpawnRegistry, TemplateRegistry, Workspace}

  @doc """
  Invoke a single Template Class's `instantiate/3` by name, against
  the workspace's persisted `session_templates` JSON.

  Called by `Ezagent.Workspace.add_template/3` after the DB write +
  dispatch_mutation succeed, so a runtime-added template's Kind comes
  up immediately (without waiting for the next phx boot's
  `load_all/0`).

  Returns:
  - `{:ok, [URI.t()]}` — list of URIs the Template Class spawned. Also
    binds each URI to `workspace_uri` in `Ezagent.WorkspaceRegistry`,
    matching `load_all/0`'s post-instantiate plumbing (invariant 4).
  - `{:error, :workspace_not_found}` — workspace missing from store.
  - `{:error, {:template_not_found, tmpl_name}}` — workspace has no
    template under that name.
  - `{:error, :missing_class_field}` — template lacks `"class"`.
  - `{:error, {:no_template_class, class_name}}` — class name not
    registered in `Ezagent.TemplateRegistry`.
  - `{:error, reason}` — propagated from `Class.instantiate/3`.

  ## V1 acceptance fix (2026-05-21)

  `Workspace.add_template/3` previously only wrote DB + dispatched
  the `add_template` mutation to the live Workspace Kind — but never
  invoked the Template Class's `instantiate/3`. Operators creating
  agents via UI then saw "Not running" until a phx restart triggered
  `load_all/0`. This function is the missing single-template
  instantiate path.
  """
  @spec invoke_template(URI.t(), String.t()) ::
          {:ok, [URI.t()]} | {:error, term()}
  def invoke_template(%URI{} = workspace_uri, tmpl_name)
      when is_binary(tmpl_name) do
    name = workspace_name(workspace_uri)

    with %{session_templates: tmpls} <- Workspace.Store.get_by_name(name),
         {:ok, tmpl_data} <- fetch_template(tmpls, tmpl_name),
         class_name when is_binary(class_name) <-
           extract_class_name(tmpl_data) ||
             {:error, :missing_class_field},
         {:ok, class_module} <- TemplateRegistry.lookup(class_name) do
      do_invoke(class_module, tmpl_name, tmpl_data, workspace_uri)
    else
      nil ->
        {:error, :workspace_not_found}

      {:error, _} = err ->
        err

      :error ->
        {:error, {:no_template_class, extract_class_name_safe(workspace_uri, tmpl_name)}}
    end
  end

  defp workspace_name(%URI{scheme: "workspace"} = uri), do: Ezagent.URI.name!(uri)

  defp workspace_name(%URI{} = uri) do
    raise ArgumentError, "not a workspace URI: #{inspect(uri)}"
  end

  defp fetch_template(tmpls, tmpl_name) do
    case Map.fetch(tmpls, tmpl_name) do
      {:ok, tmpl_data} -> {:ok, tmpl_data}
      :error -> {:error, {:template_not_found, tmpl_name}}
    end
  end

  defp extract_class_name_safe(workspace_uri, tmpl_name) do
    case Workspace.Store.get_by_name(workspace_name(workspace_uri)) do
      %{session_templates: tmpls} -> tmpls |> Map.get(tmpl_name) |> extract_class_name()
      _ -> nil
    end
  end

  defp do_invoke(class_module, tmpl_name, tmpl_data, workspace_uri) do
    # codex round-6 HIGH-1 — a Template Class may return either the
    # 2-element `{:ok, uris}` form or the 3-element `{:ok, uris, meta}`
    # form (meta carries `fresh?`).
    #
    # codex round-9 HIGH-1 — the runtime `invoke_template/2` path (called
    # by `Workspace.add_template/3`) is also a Loader call site that must
    # adopt a `fresh?: false` worker only if it already owns it.
    # `gated_load_bind/3` enforces the same ownership gate as the boot
    # `load_all/0` path: bind unconditionally for `fresh?: true` / the
    # legacy 2-tuple, but for `fresh?: false` bind ONLY if the worker is
    # already bound to this workspace.
    # PR-3 (domain.agent D2) — route through the core contract-boundary wrapper so
    # boot/loader seams allocate the per-agent config_dir TARGET uniformly (this
    # was the rev-1 codex BLOCKER: the loader bypassed single-seam allocation).
    #
    # 2026-06-07 file-flavor-create-cascade — a FILE-FLAVOR (cc/codex) template
    # is the AgentTemplate CONTENT schema and routes through the #17 cascade
    # chokepoint so cold restart re-resolves the cascade (and so the content→data
    # conversion runs). See `cascade_or_provision/4`.
    case cascade_or_provision(class_module, tmpl_name, tmpl_data, workspace_uri) do
      {:ok, uris} when is_list(uris) ->
        gated_load_bind(uris, workspace_uri, true)

      {:ok, uris, meta} when is_list(uris) and is_map(meta) ->
        gated_load_bind(uris, workspace_uri, Map.get(meta, :fresh?, false) == true)

      {:error, {:already_started, _pid}} ->
        # Idempotent: the Kind is already alive (template instantiate
        # was already triggered, e.g. via a duplicate add_template
        # call). Return the workspace's view of the URIs from the
        # template data so callers see the same shape as a fresh
        # spawn. cc.agent's own idempotent guard returns `{:ok,
        # [agent_uri]}` for this case — most templates already do
        # this themselves; the clause here is defensive.
        {:ok, instantiate_idempotent_uris(tmpl_data_from_template_name(workspace_uri, tmpl_name))}

      {:error, _} = err ->
        err

      other ->
        {:error, {:bad_template_return, other}}
    end
  end

  # FILE-FLAVOR (credentialled) templates are persisted as the AgentTemplate
  # CONTENT schema (`flavor`/`project_cwd`/`config_dir`); they need a content→data
  # conversion before `provision_and_instantiate/4` (which reads the DATA `cwd`
  # key + allocates the per-agent config_dir from the `config_dir` reference).
  # Non-credentialled templates (echo) are already DATA shape — passed straight
  # through.
  #
  # The boot Loader does the conversion CASCADE-FREE (`content_to_template_data/2`,
  # NOT `spawn_from_template_content/5`). The credential cascade keys off the
  # agent OWNER; at cold boot the dispatch runs under the workspace's own boot
  # self-authority, NOT the human who created the agent — re-resolving a
  # user-default under that wrong
  # owner (and minting/persisting a grant for it) would be incorrect. Credential
  # re-resolution at cold restart is the Agent Kind's `Sandbox.activate →
  # ensure_subprocess_alive → CascadeRuntime` self-heal, which reads the ORIGINAL
  # owner from the persisted Sandbox-slice `cascade_resolution`. So the Loader
  # only re-spawns the Kind (isolated config_dir via single-reference
  # materialize); the self-heal corrects credentials with the right owner.
  #
  # The real `fresh?` from `provision_and_instantiate` is PRESERVED (codex r2
  # HIGH) — `gated_load_bind/3`'s adopt-only-if-owned ownership gate depends on
  # it; hardcoding `fresh?: true` would rebind a pre-existing foreign worker.
  defp cascade_or_provision(class_module, tmpl_name, tmpl_data, %URI{} = workspace_uri) do
    with {:ok, data} <- file_flavor_to_data(class_module, tmpl_data) do
      Ezagent.Kind.Template.provision_and_instantiate(
        class_module,
        tmpl_name,
        data,
        workspace_uri
      )
    end
  end

  # Convert a persisted file-flavor template to the DATA shape (cascade-free).
  # Non-file-flavor templates are already DATA shape — returned as-is.
  #
  # No-silent-fallback (codex r3 follow-up): a credentialled file-flavor template
  # — whether new CONTENT shape or an old DATA shape — MUST carry a non-empty
  # `config_dir` reference. Without it, `provision_and_instantiate/4` skips
  # allocation and the cc/codex consume path leaves `CLAUDE_CONFIG_DIR`/`CODEX_HOME`
  # unset → the process silently shares the operator's home. A file-flavor that
  # reaches the loader without a resolvable config home FAILS LOUD
  # (`:file_flavor_missing_config_dir`) rather than booting un-isolated. (The DB
  # is wiped+rebuilt on migration per feedback_let_it_crash_no_workarounds, so a
  # stale pre-change DATA template without config_dir should not persist across a
  # real deploy; if one does, this surfaces it instead of degrading.)
  defp file_flavor_to_data(class_module, tmpl_data) do
    cond do
      not file_flavor_class?(class_module) ->
        # echo / curl / np — no credential home; pass through unchanged.
        {:ok, tmpl_data}

      not has_config_dir?(tmpl_data) ->
        {:error, {:file_flavor_missing_config_dir, Map.get(tmpl_data, "agent_uri")}}

      content_shape?(tmpl_data) ->
        with {:ok, facade} <- resolve_agent_spawn_facade(),
             {:ok, agent_uri} <- fetch_agent_uri(tmpl_data) do
          facade.content_to_template_data(to_content(tmpl_data), agent_uri)
        end

      true ->
        # Already DATA shape WITH a config_dir — pass through.
        {:ok, tmpl_data}
    end
  end

  defp file_flavor_class?(class_module) when is_atom(class_module) do
    Ezagent.Agent.CredentialAdapter.credentialled?(class_module)
  end

  defp has_config_dir?(tmpl_data) when is_map(tmpl_data) do
    case Map.get(tmpl_data, "config_dir") || Map.get(tmpl_data, :config_dir) do
      dir when is_binary(dir) and dir != "" -> true
      _ -> false
    end
  end

  # A CONTENT-shape template carries `project_cwd` (the input key); a DATA-shape
  # template carries `cwd`.
  defp content_shape?(tmpl_data) when is_map(tmpl_data) do
    is_binary(Map.get(tmpl_data, "project_cwd") || Map.get(tmpl_data, :project_cwd))
  end

  defp fetch_agent_uri(tmpl_data) do
    case Map.get(tmpl_data, "agent_uri") || Map.get(tmpl_data, :agent_uri) do
      s when is_binary(s) and s != "" -> {:ok, Ezagent.URI.new!(s)}
      _ -> {:error, :missing_agent_uri}
    end
  end

  defp to_content(tmpl_data) do
    %{
      flavor: Map.get(tmpl_data, "flavor") || Map.get(tmpl_data, :flavor),
      project_cwd: Map.get(tmpl_data, "project_cwd") || Map.get(tmpl_data, :project_cwd),
      config_dir: Map.get(tmpl_data, "config_dir") || Map.get(tmpl_data, :config_dir)
    }
  end

  # Runtime DI for the agent facade (mirrors the Behavior.Workspace seam) —
  # `content_to_template_data/2` is the cascade-free content→data conversion.
  defp resolve_agent_spawn_facade do
    facade =
      Application.get_env(:ezagent_domain_workspace, :agent_spawn_facade, Ezagent.Entity.Agent)

    if Code.ensure_loaded?(facade) and function_exported?(facade, :content_to_template_data, 2) do
      {:ok, facade}
    else
      {:error, {:agent_spawn_facade_unavailable, facade}}
    end
  end

  # codex round-9 HIGH-1 — gated workspace bind for the Loader.
  #
  # ## The bug
  #
  # The Loader accepts the 3-tuple Template-Class return `{:ok, [uri],
  # %{fresh?: _}}` but the pre-round-9 code IGNORED `fresh?` — it
  # unconditionally rebound every returned URI in `WorkspaceRegistry`.
  # Round 8 made an already-started Agent Kind report `fresh?: false`
  # (no fresh sidecar, no fresh lineage/binding from the plugin) — but
  # the Loader rebound it anyway. A persisted workspace template whose
  # `agent_uri` points at an already-live worker could therefore REBIND
  # that worker to THIS workspace with no ownership check — a
  # corrupt-state / workspace-isolation path round 8 fixed in the
  # Generator (`verify_slot_candidate_ownership/5`) but NOT here.
  #
  # ## The fix — adopt-only-if-owned for `fresh?: false`
  #
  # - `fresh?: true` (or a legacy 2-tuple return, which carries no
  #   signal): the worker was freshly created by THIS instantiate call —
  #   bind it, after a structural URI/workspace-segment consistency
  #   check (the returned URI's workspace segment must equal
  #   `workspace_uri`).
  # - `fresh?: false`: the worker was NOT freshly created — adopt it
  #   ONLY IF it is already owned by this workspace: its existing
  #   `WorkspaceRegistry` binding must already equal `workspace_uri`
  #   AND its URI's workspace segment must match. A divergent or absent
  #   binding → `{:error, {:loader_adopt_not_owned, uri}}`, NO bind.
  #
  # This mirrors the Generator's `verify_slot_candidate_ownership/5`
  # intent (round 8): the Loader is a parallel call site that needs the
  # equivalent gate. Any rejected URI returns an error for the whole
  # template and binds NOTHING — a half-bound template is worse than an
  # un-loaded one.
  defp gated_load_bind(uris, workspace_uri, fresh?) do
    Enum.reduce_while(uris, {:ok, uris}, fn uri, acc ->
      case bind_one_gated(uri, workspace_uri, fresh?) do
        :ok -> {:cont, acc}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # Bind a single URI under the round-9 ownership gate.
  defp bind_one_gated(%URI{} = uri, %URI{} = workspace_uri, fresh?) do
    cond do
      not uri_workspace_segment_matches?(uri, workspace_uri) ->
        {:error, {:loader_uri_workspace_mismatch, URI.to_string(uri)}}

      fresh? ->
        # Freshly created by this call (or a legacy no-signal return):
        # binding it is the documented invariant-4 obligation.
        Ezagent.WorkspaceRegistry.bind(uri, workspace_uri)
        :ok

      worker_already_bound_to?(uri, workspace_uri) ->
        # `fresh?: false` AND already owned by this workspace — the
        # legitimate idempotent re-load. The bind is a no-op (the
        # registry is idempotent for an identical pair); call it so the
        # binding is asserted regardless.
        Ezagent.WorkspaceRegistry.bind(uri, workspace_uri)
        :ok

      true ->
        # `fresh?: false` and NOT owned by this workspace — a foreign /
        # unbound / divergently-bound live worker. Refuse to adopt it;
        # bind nothing.
        {:error, {:loader_adopt_not_owned, URI.to_string(uri)}}
    end
  end

  # The returned URI's workspace segment must equal `workspace_uri`.
  # `Ezagent.Capability.workspace_of/1` extracts the workspace from an
  # `entity://` / `session://` / `template://` / `resource://` URI; for
  # any other scheme (a test fixture) it returns `:any` — which we treat
  # as a match (the consistency check only constrains real, workspaced
  # schemes).
  defp uri_workspace_segment_matches?(%URI{} = uri, %URI{} = workspace_uri) do
    case Ezagent.Capability.workspace_of(uri) do
      %URI{scheme: "workspace"} = uri_workspace ->
        Ezagent.URI.workspace_name(uri_workspace) == Ezagent.URI.workspace_name(workspace_uri)

      :any ->
        true

      _ ->
        false
    end
  rescue
    # `workspace_of/1` raises for a structurally-malformed entity URI
    # (e.g. a non-3-segment path). A URI we cannot derive a workspace
    # for is treated as a mismatch — fail closed.
    _ -> false
  end

  # True iff `uri`'s existing `WorkspaceRegistry` binding already equals
  # `workspace_uri` (compared by canonical string form — the registry
  # stores + returns string-derived `%URI{}`).
  defp worker_already_bound_to?(%URI{} = uri, %URI{} = workspace_uri) do
    case Ezagent.WorkspaceRegistry.lookup(uri) do
      {:ok, %URI{} = bound} -> URI.to_string(bound) == URI.to_string(workspace_uri)
      :error -> false
    end
  end

  defp tmpl_data_from_template_name(workspace_uri, tmpl_name) do
    case Workspace.Store.get_by_name(workspace_name(workspace_uri)) do
      %{session_templates: tmpls} -> Map.get(tmpls, tmpl_name, %{})
      _ -> %{}
    end
  end

  defp instantiate_idempotent_uris(%{"agent_uri" => uri_str}) when is_binary(uri_str),
    do: [Ezagent.URI.new!(uri_str)]

  defp instantiate_idempotent_uris(_), do: []

  @doc """
  Load every persisted Workspace and (re-)spawn each of its members.

  Returns the list of `{workspace_name, child_results}` for
  observability — each `child_results` is `[{uri, {:ok, pid}} |
  {uri, {:error, reason}}]`. Errors are logged but do not abort
  loading — a Workspace declaring an unknown scheme should produce
  a clear log but not block the rest of the boot.
  """
  @spec load_all() :: [{String.t(), [{URI.t(), term()}]}]
  def load_all do
    # Phase 5 PR 6: defensive — when multiple plugin Applications all
    # call load_all/0 at boot (Decision #112 pattern), the Repo's
    # sandbox pool can saturate in test env. A boot-time DB unavailable
    # state shouldn't crash the whole umbrella — log and return [].
    # The plugin's later Loader.load_all runs catch up; tests checkout
    # connections explicitly per Sandbox docs.
    if agent_flavor_registry_unsealed?() do
      Logger.info(
        "Workspace.Loader.load_all: agent flavor registry is not sealed yet; " <>
          "skipping until the domain-agent flavor publish hook re-runs load_all/0"
      )

      []
    else
      try do
        Workspace.Store.list_all() |> Enum.map(&load_one/1)
      rescue
        e in [DBConnection.ConnectionError, DBConnection.OwnershipError] ->
          # #108 — in PRODUCTION a boot-time DB-unavailable shouldn't crash the
          # whole umbrella (a plugin's later `load_all/0` or per-test setup picks
          # the Workspaces up), so we log and return []. But in `:test` this
          # rescue is a LATENT TRAP: it converts a genuinely broken sandbox
          # connection (the recurring CI flake's root class) into a SILENT empty
          # result, which then surfaces downstream as the misleading
          # "workspace never appeared with children" assertion in
          # PluginIsolationWorkspaceTest. Multiple distinct silent-`[]` paths
          # (this rescue, the reverted-sandbox dispatch, the unsealed
          # flavor-registry gate) collapse into the same indistinguishable
          # symptom. Unmask in `:test` so a broken connection FAILS LOUD and
          # names its own cause instead of masquerading as a flake.
          # (Verified safe: this rescue does NOT fire in the full umbrella —
          # `grep -c "DB unavailable at boot"` over a complete run is 0 — so
          # unmasking changes nothing for green suites; it only converts a future
          # silent swallow into a diagnosable error.)
          if test_env?() do
            reraise(e, __STACKTRACE__)
          else
            Logger.warning(
              "Workspace.Loader.load_all: DB unavailable at boot (#{inspect(e.__struct__)}); " <>
                "skipping — plugin re-runs or per-test setup will pick up Workspaces"
            )

            []
          end
      end
    end
  end

  # #108 — match the established carve-out convention
  # (`EzagentDomainInstanceMessage.Application.test_env?/0`): only `:test`
  # unmasks the OwnershipError/ConnectionError rescue above.
  defp test_env? do
    Code.ensure_loaded?(Mix) and Mix.env() == :test
  rescue
    _ -> false
  end

  defp agent_flavor_registry_unsealed? do
    Code.ensure_loaded?(Ezagent.AgentFlavorRegistry) and
      function_exported?(Ezagent.AgentFlavorRegistry, :sealed?, 0) and
      not Ezagent.AgentFlavorRegistry.sealed?()
  end

  defp load_one(%{name: name} = decoded) do
    case Workspace.spawn_workspace(name, %{
           members: decoded.members,
           session_templates: decoded.session_templates,
           routing_rules: decoded.routing_rules
         }) do
      {:ok, _uri} ->
        children = instantiate_via_dispatch(decoded.uri)
        results = Enum.map(children, &spawn_child(&1, decoded.uri))
        {name, results}

      {:error, {:already_started, _uri}} ->
        # Already alive (e.g. test setup spawned it before Loader ran).
        # Dispatch :instantiate to re-spawn any missing members.
        children = instantiate_via_dispatch(decoded.uri)
        results = Enum.map(children, &spawn_child(&1, decoded.uri))
        {name, results}

      {:error, reason} ->
        Logger.warning("Workspace.Loader: failed to spawn #{name}: #{inspect(reason)}")
        {name, []}
    end
  end

  defp instantiate_via_dispatch(workspace_uri) do
    target = Ezagent.URI.new!("#{URI.to_string(workspace_uri)}?action=workspace.instantiate")

    with {:ok, ctx} <- workspace_instantiate_self_ctx(workspace_uri) do
      case Router.dispatch(%Cmd{
             target: target,
             action: :instantiate,
             args: %{},
             ctx: Map.merge(ctx, %{mode: :call, reply: {:caller_inbox, self()}}),
             origin: :trusted_internal
           }) do
        {:ok, %{children: children}} ->
          children

        other ->
          Logger.warning(
            "Workspace.Loader: instantiate dispatch returned unexpected: #{inspect(other)}"
          )

          []
      end
    else
      {:error, reason} ->
        Logger.warning(
          "Workspace.Loader: instantiate capability issuance failed: #{inspect(reason)}"
        )

        []
    end
  end

  # The boot loader still presents the workspace as itself, but the capability
  # is no longer an unsigned self-assertion. The canonical admin uses the
  # workspace Kind's sealed anchor to ask that Kind to sign the concrete
  # `:instantiate` cap for the workspace presenter. Shape mirrors
  # `Ezagent.ActionSet.Workspace.required_caps/0[:instantiate]` =
  # `cap(:workspace, Workspace, :instantiate)` but SCOPED to the concrete
  # workspace (`instance`/`workspace_uri` from `workspace_uri`) for tightest
  # least-privilege — the runtime substitutes the same concrete instance from
  # the dispatch target, so concrete==concrete matches.
  defp workspace_instantiate_self_ctx(%URI{} = workspace_uri) do
    admin_uri = Ezagent.URI.user(:system, :admin)

    requested =
      Ezagent.Capability.cap(
        :workspace,
        Ezagent.ActionSet.Workspace,
        :instantiate,
        Ezagent.URI.instance(workspace_uri),
        Ezagent.Capability.workspace_of(workspace_uri)
      )

    with {:ok, signed_cap} <-
           Ezagent.Cap.issue({:admin, admin_uri}, admin_uri, requested) do
      {:ok,
       %{
         caller: admin_uri,
         authenticated_principal: admin_uri,
         caps: MapSet.new([signed_cap])
       }}
    end
  end

  defp spawn_child({:member, %URI{} = uri}, _workspace_uri) do
    case SpawnRegistry.spawn(uri) do
      {:ok, pid} ->
        {uri, {:ok, pid}}

      {:error, reason} = err ->
        Logger.warning("Workspace.Loader: spawn #{URI.to_string(uri)} failed: #{inspect(reason)}")

        {uri, err}
    end
  end

  defp spawn_child({:template, tmpl_name, tmpl_data}, workspace_uri) do
    case extract_class_name(tmpl_data) do
      nil ->
        Logger.warning(
          "Workspace.Loader: template #{inspect(tmpl_name)} missing \"class\" field in " <>
            "workspace #{URI.to_string(workspace_uri)}, skipping"
        )

        {tmpl_name, {:error, :missing_class_field}}

      class_name ->
        case TemplateRegistry.lookup(class_name) do
          {:ok, class_module} ->
            invoke_template(class_module, tmpl_name, tmpl_data, workspace_uri)

          :error ->
            Logger.warning(
              "Workspace.Loader: no Template Class registered for " <>
                "#{inspect(class_name)} (template #{inspect(tmpl_name)}) in workspace " <>
                "#{URI.to_string(workspace_uri)}, skipping"
            )

            {tmpl_name, {:error, {:no_template_class, class_name}}}
        end
    end
  end

  defp invoke_template(class_module, tmpl_name, tmpl_data, workspace_uri) do
    # PR-3 (domain.agent D2) — route through the core contract-boundary wrapper so
    # boot/loader seams allocate the per-agent config_dir TARGET uniformly (this
    # was the rev-1 codex BLOCKER: the loader bypassed single-seam allocation).
    #
    # 2026-06-07 file-flavor-create-cascade — a FILE-FLAVOR (cc/codex) template
    # routes through the #17 cascade chokepoint (same seam as the runtime
    # `do_invoke/4`). See `cascade_or_provision/4`.
    case cascade_or_provision(class_module, tmpl_name, tmpl_data, workspace_uri) do
      # codex round-6 HIGH-1 — accept both the 2-element `{:ok, uris}`
      # and the 3-element `{:ok, uris, meta}` form (meta carries
      # `fresh?`).
      #
      # codex round-9 HIGH-1 — the Loader is a SECOND call site (the
      # boot path) that, like the Generator, must NOT rebind a
      # `fresh?: false` worker it does not own. `gated_load_bind/3`
      # binds unconditionally for `fresh?: true` / the legacy 2-tuple,
      # but for `fresh?: false` binds ONLY if the worker is already
      # bound to this workspace (adopt-only-if-owned). A divergent
      # binding → error, NO bind.
      {:ok, uris} when is_list(uris) ->
        {tmpl_name, gated_load_bind(uris, workspace_uri, true)}

      {:ok, uris, meta} when is_list(uris) and is_map(meta) ->
        {tmpl_name, gated_load_bind(uris, workspace_uri, Map.get(meta, :fresh?, false) == true)}

      {:error, reason} = err ->
        Logger.warning(
          "Workspace.Loader: template #{inspect(tmpl_name)} instantiate returned " <>
            "#{inspect(reason)} in workspace #{URI.to_string(workspace_uri)}"
        )

        {tmpl_name, err}

      other ->
        Logger.warning(
          "Workspace.Loader: template #{inspect(tmpl_name)} returned unexpected " <>
            "#{inspect(other)} (expected `{:ok, [URI]}` or `{:error, _}`)"
        )

        {tmpl_name, {:error, {:bad_template_return, other}}}
    end
  end

  defp extract_class_name(%{"class" => name}) when is_binary(name) and name != "", do: name
  defp extract_class_name(%{class: name}) when is_binary(name) and name != "", do: name
  defp extract_class_name(_), do: nil
end
