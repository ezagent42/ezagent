defmodule Ezagent.ActionSet.Workspace.AgentCreate do
  @moduledoc """
  `:create_agent` provisioning machinery for `Ezagent.ActionSet.Workspace`
  (SPEC `docs/superpowers/specs/2026-05-25-agent-create-cli-gui-parity.md`).

  Extracted VERBATIM from `Ezagent.ActionSet.Workspace` (PR-3V, gt_1000
  burn-down) to keep the #685 member-CapBAC handlers + revoke sweep and the
  create-agent provisioning concern in separate modules. The Behavior's
  `handle_create_agent/2` engine callback delegates here; the bodies below are
  byte-identical to their pre-extraction form (including the #17/#641
  credential-cascade path `spawn_file_flavor_via_cascade/4` /
  `to_cascade_content/1` / `register_and_invoke_template/9` /
  `grant_agent_creator_manage_cap/3` / `resolve_source_config_dir/2`).
  """

  alias Ezagent.ActionSet.Workspace.AgentCreate.FlavorValidation
  alias Ezagent.ActionSet.Workspace.AgentCreate.PyTemplate
  alias Ezagent.ActionSet.Workspace.AgentCreate.RoleStep

  # Entry point delegated from the Behavior's `handle_create_agent/2` callback.
  def handle_create_agent(args, ctx) when is_map(args) do
    raw_workspace_uri = Map.get(ctx, :self_uri)
    session_templates = ctx[:read].(:session_templates, %{})

    with {:ok, flavor, name, cwd, with_pty?, from_uri, role} <- coerce_create_args(args),
         :ok <- validate_flavor(flavor),
         {:ok, flavor_config} <-
           Ezagent.ActionSet.Workspace.AgentCreate.FlavorConfig.coerce(flavor, args),
         :ok <- validate_name(name),
         :ok <- validate_cwd_for_flavor(flavor, with_pty?, cwd),
         :ok <- validate_from_for_flavor(flavor, from_uri),
         :ok <- validate_role_for_flavor(flavor, role),
         {:ok, workspace_uri} <- require_workspace_uri(raw_workspace_uri),
         workspace_name = workspace_uri.host,
         {:ok, agent_uri} <- compose_agent_uri(flavor, name, workspace_name),
         :ok <- refuse_if_exists(agent_uri),
         {:ok, source_config_dir} <- resolve_source_config_dir(from_uri, ctx) do
      do_create_agent(flavor, agent_uri, session_templates, %{
        cwd: cwd,
        with_pty?: with_pty?,
        # RF-5a: an optional role composes its recipe with the flavor into the
        # spawn behaviors/caps/passive marker; nil preserves the existing path.
        role: role,
        workspace_name: workspace_name,
        workspace_uri: workspace_uri,
        source_config_dir: source_config_dir,
        # Thread the caller so direct spawn can record durable agent lineage.
        caller: Map.get(ctx, :caller),
        authenticated_principal: Map.get(ctx, :authenticated_principal),
        # Thread caps and `--from` through the cascade chokepoint for grant
        # authorization and single-reference clone semantics.
        caps: Map.get(ctx, :caps),
        from_uri: from_uri,
        flavor_config: flavor_config
      })
    end
  end

  # `:create_agent` helpers (SPEC 2026-05-25-agent-create-cli-gui-parity)
  # These mirror the operator UI path so the CLI and UI share one code path.

  # CLI builds atom-keyed maps. The current dispatch path (local-
  # in-process for the mix task + UI) preserves atom keys end-to-end.
  defp coerce_create_args(args) do
    flavor = Map.get(args, :flavor)
    name = Map.get(args, :name)
    cwd = Map.get(args, :cwd, "")
    with_pty = Map.get(args, :with_pty, false)
    from = Map.get(args, :from)
    role = Map.get(args, :role)

    cond do
      not is_binary(flavor) ->
        {:error, :flavor_required}

      not is_binary(name) ->
        {:error, :name_required}

      not is_binary(cwd) ->
        {:error, {:bad_cwd, cwd}}

      not is_boolean(with_pty) ->
        {:error, {:bad_with_pty, with_pty}}

      not valid_from?(from) ->
        {:error, {:bad_from, from}}

      not valid_role?(role) ->
        {:error, {:bad_role, role}}

      true ->
        {:ok, String.trim(flavor), String.trim(name), String.trim(cwd), with_pty, from,
         coerce_role(role)}
    end
  end

  # `role` arg coercion/validation (RF-5a) lives in `RoleStep`.
  defp valid_role?(role), do: RoleStep.valid_role_arg?(role)
  defp coerce_role(role), do: RoleStep.coerce_role_arg(role)

  defp valid_from?(nil), do: true

  defp valid_from?(%URI{scheme: "entity"} = uri) do
    Ezagent.URI.type?(uri, :agent) and match?({:ok, _name}, Ezagent.URI.name(uri))
  end

  defp valid_from?(_), do: false

  defp require_workspace_uri(%URI{scheme: "workspace"} = uri) do
    case Ezagent.URI.name(uri) do
      {:ok, _name} -> {:ok, uri}
      :error -> {:error, {:bad_workspace_uri, uri}}
    end
  end

  defp require_workspace_uri(other), do: {:error, {:bad_workspace_uri, other}}

  # Flavor validation: must be registered in AgentFlavorRegistry. Empty
  # registry (test bootstrap) falls back to the well-known names so a
  # unit test that doesn't boot plugins can still drive the handler.
  defp validate_flavor(""), do: {:error, :flavor_required}

  defp validate_flavor(flavor) when is_binary(flavor) do
    case Ezagent.AgentFlavorRegistry.list_all() do
      [] ->
        # py-agent P4: `np` is no longer a flavor (retired to a py-role), so it
        # is NOT in this empty-registry test-bootstrap fallback.
        if flavor in ~w(cc curl codex py),
          do: :ok,
          else: {:error, {:bad_flavor, flavor}}

      entries ->
        names = Enum.map(entries, fn {f, _} -> f end)

        if flavor in names,
          do: :ok,
          else: {:error, {:bad_flavor, flavor}}
    end
  end

  defp validate_name(""), do: {:error, :name_required}

  defp validate_name(name) when is_binary(name) do
    # Same regex as the LV's `validate_name/1`: alnum start, then
    # alnum + dash + underscore (URI-path-safe).
    if name =~ ~r/\A[A-Za-z0-9][A-Za-z0-9_\-]*\z/ do
      :ok
    else
      {:error, {:bad_name, name}}
    end
  end

  # Per-flavor cwd + `--from` validators live in `FlavorValidation` (gt_1000
  # extraction) — thin delegates here.
  defp validate_cwd_for_flavor(flavor, with_pty?, cwd),
    do: FlavorValidation.validate_cwd_for_flavor(flavor, with_pty?, cwd)

  defp validate_from_for_flavor(flavor, from),
    do: FlavorValidation.validate_from_for_flavor(flavor, from)

  # RF-5a is the DIRECT-SPAWN role path only; a role on a file-flavor (cc/codex/
  # cc/…) FAILS LOUD (RF-5b deferred). Delegated to `RoleStep`.
  defp validate_role_for_flavor(flavor, role), do: RoleStep.validate_for_flavor(flavor, role)

  # Resolve the source agent's per-agent config_dir by dispatching
  # `sandbox.read` on the source URI WITH THE CALLER'S CAPS. This:
  #
  #  - Enforces `sandbox.read` on source via standard CapBAC (no new
  #    cap subject, no parallel auth path).
  #  - Returns `{:error, :source_not_found}` when the source Agent
  #    Kind isn't alive (ReadyGate :no_such_actor).
  #  - On success returns the source's `config_dir_path` (or nil if
  #    the source has no per-agent dir — e.g. a curl agent).
  #
  # ORDER MATTERS — this step is in the main `with` chain BEFORE
  # `do_create_agent`. A `{:error, _}` here short-circuits BEFORE any
  # template registration, Store write, or filesystem op.
  #
  # NOTE: this is a SYNCHRONOUS sub-dispatch — the handler's `with`
  # chain needs the return value to map per-flavor error atoms
  # (`:source_not_found`, `:source_not_readable`, etc.) BEFORE
  # `do_create_agent/4` runs. The `:dispatch_returning` effect
  # (SPEC `2026-05-29-dispatch-returning-effect.md`) binds a value
  # for DOWNSTREAM EFFECT references — it does NOT push the value
  # back into the handler's `with` chain (effects run AFTER the
  # handler returns).
  #
  # So we use `Ezagent.Router.dispatch/1` (the modern sanctioned
  # entry-point) instead of the legacy Invocation entry-point.
  # The §11 Gate 3 grep gate fires on the legacy Invocation dispatch
  # in plugin Behaviors specifically; `Router.dispatch` is the
  # public author-facing surface and is fine for this sub-dispatch
  # pattern.
  defp resolve_source_config_dir(nil, _ctx), do: {:ok, nil}

  defp resolve_source_config_dir(%URI{} = source_uri, ctx) do
    caller = Map.fetch!(ctx, :caller)
    caps = Map.fetch!(ctx, :caps)

    cmd =
      Ezagent.Cmd.new(
        source_uri,
        :read,
        %{},
        %{
          caller: caller,
          authenticated_principal: Map.fetch!(ctx, :authenticated_principal),
          caps: caps,
          reply: {:caller_inbox, self()}
        }
      )

    case Ezagent.Router.dispatch(cmd) do
      {:ok, %{config_dir_path: path}} when is_binary(path) and path != "" ->
        {:ok, path}

      {:ok, %{config_dir_path: nil}} ->
        {:error, :source_has_no_config_dir}

      {:ok, other} ->
        {:error, {:source_read_unexpected_shape, other}}

      {:error, :unauthorized} ->
        {:error, :source_not_readable}

      {:error, :no_such_actor} ->
        {:error, :source_not_found}

      {:error, reason} ->
        {:error, {:source_read_failed, reason}}
    end
  end

  # Agent flavor is stored template metadata, not part of the stable URI.
  defp compose_agent_uri(_flavor, name, workspace_name)
       when is_binary(name) and is_binary(workspace_name) do
    try do
      {:ok, Ezagent.URI.agent(workspace_name, name)}
    rescue
      ArgumentError -> {:error, {:bad_uri, {workspace_name, name}}}
    end
  end

  defp refuse_if_exists(%URI{} = uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      :error -> :ok
      {:ok, _pid} -> {:error, {:already_exists, URI.to_string(uri)}}
    end
  end

  # cc / codex / py → register a Workspace-scoped template + persist + invoke.
  #
  # cc / codex are FILE-FLAVORS (their Template Class implements
  # `Ezagent.Agent.CredentialAdapter`). 2026-06-07 file-flavor-create-cascade
  # fix (design note `docs/superpowers/notes/2026-06-07-file-flavor-create-cascade-fix.md`):
  # the persisted template is the AgentTemplate CONTENT schema
  # (`flavor` + `project_cwd` + an ALWAYS-present `config_dir` reference),
  # not the bare Template-Class DATA schema. `register_and_invoke_template/7`
  # detects a credentialled flavor and routes the instantiate through the
  # #17 credential-cascade chokepoint (`Agent.spawn_from_template_content/5`),
  # so a unified-create cc/codex agent gets (1) an isolated per-agent
  # config_dir (never the operator's shared `~/.claude`) and (2) the #17
  # user-default credential cascade — exactly like the orchestrator/fork
  # path. `--from` is threaded as `explicit_source` so a configured
  # user-default does NOT silently override the requested clone source.
  defp do_create_agent("cc", agent_uri, session_templates, params) do
    register_file_flavor_agent(
      session_templates,
      agent_uri,
      params,
      "cc",
      "cc.agent",
      Map.get(params, :from_uri)
    )
  end

  defp do_create_agent("cc-headless", agent_uri, session_templates, params) do
    register_file_flavor_agent(
      session_templates,
      agent_uri,
      params,
      "cc-headless",
      "cc_headless.agent",
      nil
    )
  end

  # F3/#1460 — the custom-backend flavors ride the SAME file-flavor cascade lane
  # as their plain twins (previously: direct-spawn fallback → zombie Kind, no
  # sidecar; empty flavor_config even skipped validation). from_uri: N/A (API-key).
  @custom_backend_classes %{
    "cc-custom" => "cc_custom.agent",
    "cc-headless-custom" => "cc_headless_custom.agent"
  }
  defp do_create_agent(flavor, agent_uri, session_templates, params)
       when is_map_key(@custom_backend_classes, flavor) do
    register_file_flavor_agent(
      session_templates,
      agent_uri,
      params,
      flavor,
      Map.fetch!(@custom_backend_classes, flavor),
      nil
    )
  end

  defp do_create_agent("codex", agent_uri, session_templates, params) do
    register_file_flavor_agent(
      session_templates,
      agent_uri,
      params,
      "codex",
      "codex.agent",
      Map.get(params, :from_uri)
    )
  end

  defp do_create_agent("codex-remote", agent_uri, session_templates, params) do
    register_file_flavor_agent(
      session_templates,
      agent_uri,
      params,
      "codex-remote",
      "codex_remote.agent",
      nil
    )
  end

  # py-agent (Task 1.4) — operator-script python flavor on the NON-cascade
  # template route (NOT the direct-spawn route, which skips instantiate/drops
  # cwd — the np gap). See `PyTemplate` for the config_dir-reference shape.
  # py — the script-driven Python flavor. A py-agent is created either with an
  # operator-supplied `flavor_config["script"]` (the direct create form) OR with
  # a ROLE that CARRIES the script (py-agent P4 RF-5b — `np` = `py` flavor +
  # the np role's `np.py` script). The role-script channel (`Recipe.script` →
  # `Recipe.Compose.sandbox_content.script`) is folded into the template config
  # HERE, so P1's existing config_dir install + `:script_immutable` injection
  # gate carries it — py rides the TEMPLATE route (NOT the direct-spawn RoleStep
  # route, which has no config_dir allocation; that generic install is the
  # deferred native+role/RF-5b work). A role's caps + role-name marker are
  # minted/granted AFTER instantiate, mirroring the direct-spawn role path.
  defp do_create_agent("py", agent_uri, session_templates, params) do
    %{workspace_name: workspace_name, workspace_uri: workspace_uri} = params

    with {:ok, materialized} <- RoleStep.resolve(Map.get(params, :role), "py"),
         {:ok, flavor_config} <- merge_role_script(Map.get(params, :flavor_config), materialized) do
      result =
        register_and_invoke_template(
          session_templates,
          workspace_name,
          workspace_uri,
          "py.agent." <> agent_name(agent_uri),
          PyTemplate.build(agent_uri, flavor_config),
          agent_uri,
          Map.get(params, :caller),
          nil,
          nil
        )

      case result do
        {:ok, _, _effects} = ok ->
          with :ok <- RoleStep.grant_recipe_marker(agent_uri, materialized),
               :ok <- RoleStep.mint_and_grant_caps(agent_uri, "py", materialized, params) do
            ok
          end

        other ->
          other
      end
    end
  end

  # Any other flavor (native / curl / future) — direct Kind spawn via the
  # stored flavor declaration. URI names are opaque; do not recover the
  # flavor from the agent URI.
  #
  # RF-5a — the GENERIC role step (`RoleStep`) runs on this direct-spawn route.
  # A requested `role` materializes (recipe × flavor) into the spawn `:behaviors`
  # override + the durable `:passive` marker, then mints + grants the recipe's
  # caps fail-closed. ONE generic step; absent role → `materialized = nil` →
  # byte-identical to the pre-RF-5a curl/np path.
  defp do_create_agent(other_flavor, agent_uri, _session_templates, params) do
    with {:ok, materialized} <- RoleStep.resolve(Map.get(params, :role), other_flavor) do
      case direct_spawn_flavor_agent(
             other_flavor,
             agent_uri,
             Map.get(params, :flavor_config, %{}),
             materialized
           ) do
        {:ok, _pid} ->
          record_creator_lineage(agent_uri, params)

          # Creator authority must exist before recipe caps are issued: every
          # proposal below invokes this concrete agent's cap-gated `K.grant`.
          with :ok <- ensure_agent_creator_authority(agent_uri, params),
               :ok <- RoleStep.grant_passive_marker(agent_uri, materialized),
               :ok <- RoleStep.grant_recipe_marker(agent_uri, materialized),
               :ok <-
                 RoleStep.mint_and_grant_caps(agent_uri, other_flavor, materialized, params),
               :ok <-
                 grant_agent_creator_manage_cap(
                   agent_uri,
                   Map.get(params, :workspace_uri),
                   params
                 ) do
            # No slice mutation (no template registered for native/curl/np).
            {:ok, %{agent_uri: agent_uri, template_name: nil}, []}
          end

        {:error, {:already_started, _pid}} ->
          # Idempotent re-create — do NOT re-record lineage.
          {:ok, %{agent_uri: agent_uri, template_name: nil}, []}

        {:error, reason} ->
          {:error, {:spawn_failed, reason}}
      end
    end
  end

  # tmpl_prefix is always `class_name <> "."`, so the helper derives it.
  defp register_file_flavor_agent(
         session_templates,
         agent_uri,
         params,
         flavor,
         class_name,
         from_uri
       ) do
    %{
      cwd: cwd,
      workspace_name: workspace_name,
      workspace_uri: workspace_uri
    } = params

    with {:ok, tmpl} <-
           file_flavor_template(
             flavor,
             class_name,
             agent_uri,
             cwd,
             Map.get(params, :flavor_config)
           ) do
      register_and_invoke_template(
        session_templates,
        workspace_name,
        workspace_uri,
        class_name <> "." <> agent_name(agent_uri),
        tmpl,
        agent_uri,
        Map.get(params, :caller),
        Map.get(params, :caps),
        from_uri
      )
    end
  end

  # Fold a role-carried script (RF-5b `sandbox_content.script`, py-agent P4) into
  # the py template's `flavor_config["script"]`. No role (or a scriptless role) →
  # the operator-supplied `flavor_config` flows through unchanged. A role that
  # carries a script AND an operator `script` arg is a CONFLICT (two authorities
  # for the same immutable file) — fail loud rather than silently pick one.
  defp merge_role_script(flavor_config, nil), do: {:ok, flavor_config}

  defp merge_role_script(flavor_config, %{sandbox_content: %{script: nil}}),
    do: {:ok, flavor_config}

  defp merge_role_script(flavor_config, %{sandbox_content: %{script: script}})
       when is_binary(script) do
    fc = flavor_config || %{}

    case Map.get(fc, "script") || Map.get(fc, :script) do
      nil -> {:ok, Map.put(fc, "script", script)}
      _ -> {:error, :role_script_conflicts_with_operator_script}
    end
  end

  defp merge_role_script(flavor_config, _materialized), do: {:ok, flavor_config}

  # PR-6+7 (curl-as-flavor, codex round-3 P1-1 fix) — the direct-create path for
  # a flavor with NO workspace Template (native / curl / np / future). Threads
  # the flavor's OPTIONAL per-instance behavior SET as `:behaviors` (LOAD-BEARING
  # for curl: its shared `Entity.Agent` Kind excludes `Behavior.CurlAgent` from
  # the nil-`:kind_base` default; without `curl_behaviors/0` the agent is broken).
  # RF-5a `materialized` (a requested role) OVERRIDES that thunk — see
  # `spawn_args_for_flavor/5`.
  defp direct_spawn_flavor_agent(flavor, agent_uri, flavor_config, materialized)
       when is_binary(flavor) and is_map(flavor_config) do
    with {:ok, decl} <- Ezagent.AgentFlavorRegistry.lookup(flavor),
         :ok <- validate_direct_spawn_flavor_config(flavor, decl, agent_uri, flavor_config),
         :ok <- Ezagent.AgentFlavorAttributes.put(agent_uri, flavor) do
      # derivation-edge: recorded-by record_creator_lineage/2 on fresh success
      Ezagent.Kind.spawn(
        decl.kind,
        spawn_args_for_flavor(flavor, decl, agent_uri, flavor_config, materialized)
      )
    end
  end

  # Build the direct-spawn args. `:behaviors` precedence (RF-5a HIGH-1): a
  # MATERIALIZED ROLE's composed `role ++ flavor` set OVERRIDES the thunk-sourced
  # value (`RoleStep.resolve/2` folded the flavor base in, so role behaviors AND
  # base both reach `:kind_base`); else a flavor thunk (curl); else omit (the
  # Kind's nil-capture default). A materialized role also threads the DURABLE
  # `:passive` (RF-6) + `:role` (RF-7) into the `:sandbox` slice — the
  # cold-restart source of truth for the `:passive`/`:role` resolvers.
  defp spawn_args_for_flavor(flavor, decl, %URI{} = agent_uri, flavor_config, materialized) do
    base =
      %{uri: agent_uri}
      |> Map.merge(direct_spawn_config_args(flavor, flavor_config))

    base
    |> put_role_behaviors(decl, materialized)
    # RF-6/RF-7 DURABLE markers (`:passive` + `:role` NAME) — owned by RoleStep.
    |> Map.merge(RoleStep.spawn_marker_args(materialized))
  end

  defp put_role_behaviors(base, _decl, %{behaviors: behaviors}) when is_list(behaviors),
    do: Map.put(base, :behaviors, behaviors)

  defp put_role_behaviors(base, decl, _materialized) do
    case Map.get(decl, :instance_behaviors) do
      thunk when is_function(thunk, 0) -> Map.put(base, :behaviors, thunk.())
      _ -> base
    end
  end

  defp validate_direct_spawn_flavor_config(_flavor, _decl, _agent_uri, config)
       when config == %{},
       do: :ok

  defp validate_direct_spawn_flavor_config(flavor, decl, %URI{} = agent_uri, config) do
    template_class = Map.get(decl, :template_class)

    cond do
      not is_atom(template_class) ->
        :ok

      not Code.ensure_loaded?(template_class) or
          not function_exported?(template_class, :validate, 1) ->
        :ok

      true ->
        data = direct_spawn_template_data(flavor, template_class, agent_uri, config)

        case template_class.validate(data) do
          :ok -> :ok
          {:error, reason} -> {:error, {:invalid_flavor_config, flavor, reason}}
        end
    end
  end

  defp direct_spawn_template_data("curl", template_class, agent_uri, config) do
    %{
      "class" => template_class.template_name(),
      "agent_uri" => agent_uri_string(agent_uri),
      "provider" => "deepseek",
      "api_url" => "https://api.deepseek.com/chat/completions",
      "model" => "deepseek-chat"
    }
    |> Map.merge(config)
  end

  defp direct_spawn_template_data(_flavor, template_class, agent_uri, config) do
    %{
      "class" => template_class.template_name(),
      "agent_uri" => agent_uri_string(agent_uri)
    }
    |> Map.merge(config)
  end

  defp direct_spawn_config_args("curl", config) do
    config
    |> Enum.flat_map(fn
      {"provider", value} -> [provider: value]
      {"api_url", value} -> [api_url: value]
      {"model", value} -> [model: value]
      {"system_prompt", value} -> [system_prompt: value]
      {"max_history", value} -> [max_history: parse_positive_int(value, value)]
      {_key, _value} -> []
    end)
    |> Map.new()
  end

  defp direct_spawn_config_args(_flavor, _config), do: %{}

  defp parse_positive_int(value, _fallback) when is_integer(value) and value > 0, do: value

  defp parse_positive_int(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> fallback
    end
  end

  defp parse_positive_int(_value, fallback), do: fallback

  # Allen 2026-05-26 (codex HIGH-1 closure) — record `agent_uri → caller`
  # in `Ezagent.AgentLineage`. Best-effort: a missing caller (system-internal
  # spawn) leaves no lineage row.
  defp record_creator_lineage(agent_uri, params) do
    case Map.get(params, :caller) do
      %URI{} = caller ->
        Ezagent.AgentLineage.record(agent_uri, caller)

      _ ->
        :ok
    end
  end

  # 2026-06-07 file-flavor-create-cascade — build the persisted template for a
  # FILE-FLAVOR (cc/codex) in the AgentTemplate CONTENT schema
  # (`flavor` + `project_cwd` + an ALWAYS-present per-agent `config_dir`
  # reference), PLUS the `"class"` key the boot Loader's `extract_class_name`
  # + `TemplateRegistry.lookup` + `validate_template_class` require. The
  # instantiate routes this content through `Agent.spawn_from_template_content/5`
  # (the #17 cascade chokepoint), which runs it through
  # `Ezagent.Entity.AgentTemplate.to_template_data/2` to emit the Template-Class
  # DATA shape (`cwd`/`agent_uri`/…) the plugin `instantiate/3` consumes.
  #
  # `config_dir` is ALWAYS present (was `--from`-only): the per-agent TARGET
  # derived from the agent URI + the class namespace — the same dir
  # `Ezagent.Sandbox.ConfigDir.allocate/2` / `CcAgent.resolve_config_home/2`
  # clause 3 would derive. Unconditional presence (a) makes config_dir
  # allocation unconditional for file-flavors (never the operator's shared
  # `~/.claude`) and (b) satisfies `default_cascade_configured?(:file, content, _)`
  # via the content branch so the cascade fires with no `source_template_uri`.
  @doc false
  # Test-only accessor — the persisted file-flavor template ALWAYS carries a
  # config_dir reference (the no-silent-fallback structural guarantee).
  def __file_flavor_template_for_test__(flavor, class_name, agent_uri, cwd),
    do: file_flavor_template!(flavor, class_name, agent_uri, cwd, %{})

  @doc false
  def __file_flavor_template_for_test__(flavor, class_name, agent_uri, cwd, flavor_config),
    do: file_flavor_template!(flavor, class_name, agent_uri, cwd, flavor_config)

  @doc false
  # Test-only accessor — the cascade-content builder's no-silent-fallback
  # guard (a file-flavor content missing config_dir is rejected, never spawned).
  def __cascade_content_for_test__(tmpl), do: to_cascade_content(tmpl)

  defp file_flavor_template(flavor, class_name, agent_uri, cwd, flavor_config)
       when is_binary(flavor) and is_binary(class_name) do
    config_dir = per_agent_config_dir(class_name, agent_uri)

    with {:ok, validated_cwd} <-
           Ezagent.Sandbox.ConfigDir.validate_project_cwd_or_default(cwd, config_dir) do
      {:ok,
       %{
         "class" => class_name,
         "flavor" => flavor,
         "agent_uri" => agent_uri_string(agent_uri),
         "project_cwd" => validated_cwd,
         "config_dir" => config_dir
       }
       |> Map.merge(flavor_config || %{})}
    end
  end

  defp file_flavor_template!(flavor, class_name, agent_uri, cwd, flavor_config) do
    case file_flavor_template(flavor, class_name, agent_uri, cwd, flavor_config) do
      {:ok, tmpl} -> tmpl
      {:error, reason} -> raise ArgumentError, "invalid project_cwd: #{inspect(reason)}"
    end
  end

  # The per-agent config_dir TARGET — core authority (`Ezagent.Sandbox.ConfigDir`),
  # keyed by the agent URI + the class's namespace. NOT a plugin path builder.
  defp per_agent_config_dir(class_name, %URI{} = agent_uri) do
    {:ok, class_module} = Ezagent.TemplateRegistry.lookup(class_name)
    Ezagent.Sandbox.ConfigDir.path(agent_uri, Ezagent.Kind.Template.namespace_of(class_module))
  end

  # Register the template in the Workspace's session_templates slice +
  # persist via Store, then instantiate to bring the Agent Kind (+ sidecars)
  # live.
  #
  # FILE-FLAVOR routing (2026-06-07): a credentialled flavor (its Template
  # Class implements `Ezagent.Agent.CredentialAdapter`) instantiates via
  # `Agent.spawn_from_template_content/5` (the #17 cascade chokepoint) so the
  # agent gets an isolated config_dir AND the #17 user-default cascade. A
  # non-credentialled flavor (curl) keeps the existing
  # `Loader.invoke_template` path. The Store write + rollback wrapper is
  # IDENTICAL for both — only the instantiate call differs (convergence, not
  # a forked spawn path).
  #
  # Codex PR #330 r1 HIGH-1 fix: if the instantiate fails, roll back the
  # Store write so the DB doesn't carry a template the caller was told failed.
  # Without rollback, the next boot's Loader.load_all/0 would silently
  # instantiate the failed template (no CapBAC re-check, no operator visibility).
  defp register_and_invoke_template(
         session_templates,
         workspace_name,
         workspace_uri,
         tmpl_name,
         tmpl,
         agent_uri,
         creator_uri,
         caller_caps,
         from_uri
       ) do
    new_templates = Map.put(session_templates, tmpl_name, tmpl)

    with :ok <- validate_template_class(tmpl),
         {:ok, _decoded} <-
           Ezagent.Workspace.Store.update_templates(workspace_name, new_templates),
         :ok <-
           invoke_or_rollback(
             workspace_uri,
             workspace_name,
             tmpl_name,
             tmpl,
             agent_uri,
             session_templates,
             %{
               caller: creator_uri,
               authenticated_principal: creator_uri,
               caps: caller_caps,
               from_uri: from_uri
             }
           ) do
      with :ok <-
             grant_agent_creator_manage_cap(agent_uri, workspace_uri, %{caller: creator_uri}) do
        # On success: emit slice mutation as a `:set` effect and return
        # the template + agent URIs to the caller.
        {:ok, %{agent_uri: agent_uri, template_name: tmpl_name},
         [{:set, :session_templates, new_templates}]}
      end
    end
  end

  defp grant_agent_creator_manage_cap(%URI{} = agent_uri, %URI{} = workspace_uri, %{
         caller: %URI{} = creator_uri
       }) do
    Ezagent.Workspace.grant_creator_manage_cap(:agent, agent_uri, workspace_uri, creator_uri)
  end

  defp grant_agent_creator_manage_cap(_agent_uri, _workspace_uri, _params), do: :ok

  defp ensure_agent_creator_authority(%URI{} = agent_uri, %{caller: %URI{} = creator_uri}) do
    Ezagent.Identity.TargetAuthority.ensure(creator_uri, agent_uri)
  end

  defp ensure_agent_creator_authority(_agent_uri, _params), do: :ok

  # Codex PR #330 r1 HIGH-1 — call the instantiate; on failure, roll back
  # the Store.update_templates write so the DB matches the (uncommitted)
  # starting state.
  defp invoke_or_rollback(
         workspace_uri,
         workspace_name,
         tmpl_name,
         tmpl,
         agent_uri,
         original_templates,
         spawn_opts
       ) do
    case instantiate_template_now(workspace_uri, tmpl_name, tmpl, agent_uri, spawn_opts) do
      :ok ->
        :ok

      {:error, _} = err ->
        rollback_store_templates(workspace_name, original_templates, tmpl_name, err)
        err
    end
  end

  defp rollback_store_templates(workspace_name, original_templates, tmpl_name, original_err) do
    case Ezagent.Workspace.Store.update_templates(workspace_name, original_templates) do
      {:ok, _} ->
        :ok

      {:error, rollback_reason} ->
        require Logger

        Logger.error(
          "Behavior.Workspace.:create_agent: Store rollback failed for " <>
            "workspace=#{workspace_name} tmpl=#{tmpl_name}: " <>
            "#{inspect(rollback_reason)} (original error: #{inspect(original_err)})"
        )
    end
  end

  # Same validator pattern as `Ezagent.Workspace.add_template/3` uses
  # — defer to the Template Class's `validate/1` if defined.
  #
  # 2026-06-07 file-flavor-create-cascade — a file-flavor template is the
  # AgentTemplate CONTENT schema (`project_cwd`, not the `cwd` DATA key the
  # plugin `validate/1` checks). The cascade path validates the DATA shape
  # via `AgentTemplate.to_template_data/2`'s `validate_for_flavor`, so we
  # skip the plugin's DATA-shape `validate/1` here for credentialled flavors
  # (calling it would spuriously fail `:missing_cwd`). We still verify the
  # class is registered.
  defp validate_template_class(tmpl) do
    case extract_class_name(tmpl) do
      nil ->
        {:error, :missing_class_field}

      class_name ->
        case Ezagent.TemplateRegistry.lookup(class_name) do
          :error ->
            {:error, {:no_template_class, class_name}}

          {:ok, class_module} ->
            cond do
              file_flavor_class?(class_module) ->
                # Content-schema template — validated downstream in the
                # cascade path (`to_template_data` → `validate_for_flavor`).
                :ok

              function_exported?(class_module, :validate, 1) ->
                class_module.validate(tmpl)

              true ->
                :ok
            end
        end
    end
  end

  # A flavor whose Template Class implements `Ezagent.Agent.CredentialAdapter`
  # (cc/codex) — it has a per-agent credential home, so unified-create routes
  # it through the #17 cascade chokepoint.
  defp file_flavor_class?(class_module) when is_atom(class_module) do
    Ezagent.Agent.CredentialAdapter.credentialled?(class_module)
  end

  defp extract_class_name(%{"class" => name}) when is_binary(name) and name != "", do: name
  defp extract_class_name(%{class: name}) when is_binary(name) and name != "", do: name
  defp extract_class_name(_), do: nil

  # Instantiate the just-registered template. A FILE-FLAVOR (credentialled)
  # template routes through `Agent.spawn_from_template_content/5` (the #17
  # cascade chokepoint) so the agent gets an isolated config_dir + the #17
  # user-default credential cascade; a non-credentialled flavor (curl) keeps
  # the existing `Loader.invoke_template` path.
  defp instantiate_template_now(%URI{} = workspace_uri, tmpl_name, tmpl, agent_uri, spawn_opts) do
    case Ezagent.TemplateRegistry.lookup(extract_class_name(tmpl)) do
      {:ok, class_module} ->
        if file_flavor_class?(class_module) do
          spawn_file_flavor_via_cascade(workspace_uri, tmpl, agent_uri, spawn_opts)
        else
          invoke_template_now(workspace_uri, tmpl_name)
        end

      :error ->
        {:error, {:no_template_class, extract_class_name(tmpl)}}
    end
  end

  defp invoke_template_now(%URI{} = workspace_uri, tmpl_name) do
    case Ezagent.Workspace.Loader.invoke_template(workspace_uri, tmpl_name) do
      {:ok, _uris} -> :ok
      # Idempotent — already running.
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} = err -> err
    end
  end

  # Route a file-flavor (cc/codex) create through the #17 credential-cascade
  # chokepoint `Agent.spawn_from_template_content/5` — the SOLE site that runs
  # `resolve_cascade_content` (isolated config_dir allocation + #17 user-default
  # resolution + grant mint + Sandbox-slice `cascade_resolution` persistence
  # for cold-restart re-resolution). Reached via runtime DI because
  # `ezagent_domain_workspace` cannot compile-time depend on
  # `ezagent_domain_session` (which depends on workspace; boots later).
  #
  # `source_template_uri` is the per-agent template URI (its content carries a
  # `config_dir` reference, so the cascade's source_template_uri branch also
  # resolves); the content branch is the primary trigger.
  # `explicit_source` carries `--from` so a configured user-default does NOT
  # silently override the requested clone source.
  defp spawn_file_flavor_via_cascade(%URI{} = workspace_uri, tmpl, %URI{} = agent_uri, spawn_opts) do
    with {:ok, caller} <- require_spawn_caller(spawn_opts),
         {:ok, spawner} <- resolve_agent_spawn_facade(),
         {:ok, content} <- to_cascade_content(tmpl),
         caps <- Map.get(spawn_opts, :caps),
         opts <- build_spawn_opts(caller, caps, spawn_opts) do
      case spawner.spawn_from_template_content(content, agent_uri, caller, workspace_uri, opts) do
        {:ok, %{fresh?: true}} ->
          :ok

        # codex r5 HIGH-1 — `fresh?: false` means the spawn ADOPTED a pre-existing
        # live worker (a concurrent create won the race past `refuse_if_exists/1`).
        # This call did NOT create the agent, so it must NOT proceed to persist the
        # template or grant creator-manage caps for a worker owned by the other
        # creator. Surface `:already_exists` → `invoke_or_rollback` rolls back this
        # call's Store write.
        #
        # codex r7 HIGH — the cascade may have MINTED a grant for `agent_uri` before
        # adopting. Because UNIFIED CREATE rejects the adoption (unlike the
        # orchestrator, which accepts `fresh?: false`), the grant this call minted
        # for an agent it refuses to own must be cleaned up here (caller-specific —
        # the shared `spawn_from_template_content` cannot know the create rejects
        # adoption). HARD-delete frees the unique key for the real owner / a retry.
        {:ok, %{fresh?: false}} ->
          _ = Ezagent.Credential.GrantRow.delete(URI.to_string(agent_uri))
          {:error, {:already_exists, URI.to_string(agent_uri)}}

        {:error, {:already_started, _}} ->
          {:error, {:already_exists, URI.to_string(agent_uri)}}

        {:error, reason} ->
          {:error, {:cascade_spawn_failed, reason}}
      end
    end
  end

  # Build the CONTENT map the cascade consumes. `flavor`/`project_cwd`/`config_dir`
  # come straight from the persisted template. The #17 cascade fires via the
  # DEFAULT branch (`maybe_resolve_default_cascade_content`), triggered by the
  # content's `config_dir` satisfying `default_cascade_configured?(:file, content,
  # _)` — NO `source_template_uri` is needed (the unified-create path has no
  # shared workspace base template). The default branch correctly SKIPS
  # materializing a `cascade` when no credential source resolves
  # (`put_default_cascade_if_source_present` — single-reference path), and
  # resolves + mints a grant when a user-default / workspace-shared source IS
  # present.
  #
  # No-silent-fallback: a file-flavor whose template lacks a `config_dir`
  # reference FAILS LOUD here rather than spawning with `CLAUDE_CONFIG_DIR`
  # unset (which would silently share the operator's `~/.claude`).
  defp to_cascade_content(tmpl) when is_map(tmpl) do
    flavor = Map.get(tmpl, "flavor") || Map.get(tmpl, :flavor)
    project_cwd = Map.get(tmpl, "project_cwd") || Map.get(tmpl, :project_cwd)
    config_dir = Map.get(tmpl, "config_dir") || Map.get(tmpl, :config_dir)

    cond do
      not (is_binary(flavor) and flavor != "") ->
        {:error, :missing_flavor}

      not (is_binary(project_cwd) and project_cwd != "") ->
        {:error, :missing_project_cwd}

      not (is_binary(config_dir) and config_dir != "") ->
        {:error, :missing_config_dir}

      true ->
        {:ok,
         %{flavor: flavor, project_cwd: project_cwd, config_dir: config_dir}
         |> Map.merge(cascade_flavor_config(flavor, tmpl))}
    end
  end

  defp cascade_flavor_config(flavor, tmpl) do
    Ezagent.ActionSet.Workspace.AgentCreate.FlavorConfig.from_template(flavor, tmpl)
  end

  defp require_spawn_caller(spawn_opts) do
    case Map.get(spawn_opts, :caller) do
      %URI{} = caller -> {:ok, caller}
      _ -> {:error, :missing_caller_for_cascade_spawn}
    end
  end

  # `--from` → `explicit_source` so a configured user-default does NOT silently
  # override the requested clone source (codex Finding 3).
  defp build_spawn_opts(caller, caps, spawn_opts) do
    base = [caller: caller, caps: caps]

    case Map.get(spawn_opts, :from_uri) do
      %URI{} = from -> Keyword.put(base, :explicit_source, from)
      _ -> base
    end
  end

  # Runtime DI for the agent-spawn facade (mirrors `resolve_session_facade/0`).
  # `ezagent_domain_session` owns `Ezagent.Entity.Agent.spawn_from_template_content/5`
  # and boots AFTER workspace, so a compile-time alias would invert the dep
  # graph. Tests can override via
  # `Application.put_env(:ezagent_domain_workspace, :agent_spawn_facade, Fake)`.
  defp resolve_agent_spawn_facade do
    facade =
      Application.get_env(
        :ezagent_domain_workspace,
        :agent_spawn_facade,
        Ezagent.Entity.Agent
      )

    if Code.ensure_loaded?(facade) and
         function_exported?(facade, :spawn_from_template_content, 5) do
      {:ok, facade}
    else
      {:error, {:agent_spawn_facade_unavailable, facade}}
    end
  end

  defp agent_uri_string(%URI{} = uri), do: URI.to_string(uri)

  # Entity URI names are opaque; this accessor is the only local reader.
  defp agent_name(%URI{} = uri) do
    case Ezagent.URI.name(uri) do
      {:ok, name} -> name
      :error -> URI.to_string(uri)
    end
  end
end
