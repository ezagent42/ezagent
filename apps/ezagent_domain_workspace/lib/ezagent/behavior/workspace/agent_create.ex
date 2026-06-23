defmodule Ezagent.Behavior.Workspace.AgentCreate do
  @moduledoc """
  `:create_agent` provisioning machinery for `Ezagent.Behavior.Workspace`
  (SPEC `docs/superpowers/specs/2026-05-25-agent-create-cli-gui-parity.md`).

  Extracted VERBATIM from `Ezagent.Behavior.Workspace` (PR-3V, gt_1000
  burn-down) to keep the #685 member-CapBAC handlers + revoke sweep and the
  create-agent provisioning concern in separate modules. The Behavior's
  `handle_create_agent/2` engine callback delegates here; the bodies below are
  byte-identical to their pre-extraction form (including the #17/#641
  credential-cascade path `spawn_file_flavor_via_cascade/4` /
  `to_cascade_content/1` / `register_and_invoke_template/9` /
  `grant_agent_creator_manage_cap/3` / `resolve_source_config_dir/2`).
  """

  # ===================================================================
  # Entry point — the `:create_agent` handler body (delegated to from the
  # Behavior's `handle_create_agent/2` engine callback). Body byte-identical
  # to the pre-extraction handler.
  # ===================================================================
  def handle_create_agent(args, ctx) when is_map(args) do
    raw_workspace_uri = Map.get(ctx, :self_uri)
    session_templates = ctx[:read].(:session_templates, %{})

    with {:ok, flavor, name, cwd, with_pty?, from_uri, soul} <- coerce_create_args(args),
         :ok <- validate_flavor(flavor),
         :ok <- validate_name(name),
         :ok <- validate_cwd_for_flavor(flavor, with_pty?, cwd),
         :ok <- validate_from_for_flavor(flavor, from_uri),
         {:ok, workspace_uri} <- require_workspace_uri(raw_workspace_uri),
         workspace_name = workspace_uri.host,
         {:ok, agent_uri} <- compose_agent_uri(flavor, name, workspace_name),
         :ok <- refuse_if_exists(agent_uri),
         {:ok, source_config_dir} <- resolve_source_config_dir(from_uri, ctx) do
      do_create_agent(flavor, agent_uri, session_templates, %{
        cwd: cwd,
        with_pty?: with_pty?,
        workspace_name: workspace_name,
        workspace_uri: workspace_uri,
        source_config_dir: source_config_dir,
        # Allen 2026-05-26 (codex HIGH-1 closure) — thread the caller
        # URI through so the SpawnRegistry direct-spawn catch-all can
        # record lineage (`Ezagent.AgentLineage.record/2`) for the
        # newly-created agent.
        caller: Map.get(ctx, :caller),
        # 2026-06-07 file-flavor-create-cascade — the caller's caps + the
        # `--from` source URI are threaded to the #17 cascade chokepoint
        # (`Agent.spawn_from_template_content/5`) for grant-mint authorization
        # (`caps`) and to preserve single-reference clone semantics under the
        # cascade (`from_uri` → `explicit_source`).
        caps: Map.get(ctx, :caps),
        from_uri: from_uri,
        # B1 (2026-06-23): soul is an optional per-agent system-prompt
        # override (string | nil). B2 wires it into cc/codex CLAUDE.md
        # rendering; threaded here so do_create_agent receives it without
        # further parsing.
        soul: soul
      })
    end
  end

  # =================================================================
  # `:create_agent` helpers (SPEC 2026-05-25-agent-create-cli-gui-parity)
  # =================================================================
  # These mirror the operator UI path so the CLI and UI share one code path.

  # CLI builds atom-keyed maps. The current dispatch path (local-
  # in-process for the mix task + UI) preserves atom keys end-to-end.
  # The LV passes string-keyed maps — accept both; atom key wins when both
  # are present (same pattern as `:from` / `:flavor` / `:name` etc.).
  defp coerce_create_args(args) do
    flavor = Map.get(args, :flavor) || Map.get(args, "flavor")
    name = Map.get(args, :name) || Map.get(args, "name")
    cwd = Map.get(args, :cwd, Map.get(args, "cwd", ""))
    with_pty = Map.get(args, :with_pty, Map.get(args, "with_pty", false))
    from = Map.get(args, :from) || Map.get(args, "from")
    # B1 (2026-06-23): optional soul — string or nil. CLI passes atom key;
    # LV passes string key. Atom key wins (||) when both present.
    soul = Map.get(args, :soul) || Map.get(args, "soul")

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

      not (is_nil(soul) or is_binary(soul)) ->
        {:error, {:bad_soul, soul}}

      true ->
        {:ok, String.trim(flavor), String.trim(name), String.trim(cwd), with_pty, from, soul}
    end
  end

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
        if flavor in ~w(cc echo curl np codex),
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

  # cwd is required for cc, and for echo when `with_pty: true`.
  # curl + echo-without-PTY tolerate an empty cwd.
  defp validate_cwd_for_flavor("cc", _with_pty?, ""), do: {:error, :cwd_required_for_cc}
  defp validate_cwd_for_flavor("cc", _with_pty?, cwd), do: validate_cwd_dir(cwd)

  defp validate_cwd_for_flavor("cc-headless", _with_pty?, ""),
    do: {:error, :cwd_required_for_cc_headless}

  defp validate_cwd_for_flavor("cc-headless", _with_pty?, cwd), do: validate_cwd_dir(cwd)

  defp validate_cwd_for_flavor("echo", true, ""), do: {:error, :cwd_required_for_echo_with_pty}
  defp validate_cwd_for_flavor("echo", true, cwd), do: validate_cwd_dir(cwd)
  defp validate_cwd_for_flavor("echo", false, _cwd), do: :ok

  defp validate_cwd_for_flavor("codex", _with_pty?, ""),
    do: {:error, :cwd_required_for_codex}

  defp validate_cwd_for_flavor("codex", _with_pty?, cwd), do: validate_cwd_dir(cwd)

  defp validate_cwd_for_flavor("codex-remote", _with_pty?, ""),
    do: {:error, :cwd_required_for_codex_remote}

  defp validate_cwd_for_flavor("codex-remote", _with_pty?, cwd), do: validate_cwd_dir(cwd)

  defp validate_cwd_for_flavor("curl", _with_pty?, _cwd), do: :ok
  defp validate_cwd_for_flavor(_, _, _), do: :ok

  defp validate_cwd_dir(cwd) when is_binary(cwd) do
    expanded = Path.expand(cwd)

    if File.dir?(expanded) do
      :ok
    else
      {:error, {:cwd_not_a_dir, cwd}}
    end
  end

  # `--from` only meaningful for flavors that have a per-agent
  # config_dir to clone. Today that's `cc` only — echo/curl/np have no
  # CLAUDE_CONFIG_DIR concept.
  defp validate_from_for_flavor(_flavor, nil), do: :ok
  defp validate_from_for_flavor("cc", %URI{}), do: :ok

  defp validate_from_for_flavor(other_flavor, %URI{}),
    do: {:error, {:from_unsupported_for_flavor, other_flavor}}

  # Resolve the source agent's per-agent config_dir by dispatching
  # `sandbox.read` on the source URI WITH THE CALLER'S CAPS. This:
  #
  #  - Enforces `sandbox.read` on source via standard CapBAC (no new
  #    cap subject, no parallel auth path).
  #  - Returns `{:error, :source_not_found}` when the source Agent
  #    Kind isn't alive (ReadyGate :no_such_actor).
  #  - On success returns the source's `config_dir_path` (or nil if
  #    the source has no per-agent dir — e.g. an echo agent).
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
        %{caller: caller, caps: caps, reply: {:caller_inbox, self()}}
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

  # cc / echo / codex → register a Workspace-scoped template + persist + invoke.
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
    %{
      cwd: cwd,
      workspace_name: workspace_name,
      workspace_uri: workspace_uri
    } = params

    tmpl_name = "cc.agent." <> agent_name(agent_uri)

    # B2 (2026-06-23): when a soul is present, build the template via an inline
    # AgentManifest so the soul is rendered into `agent_manifest_resolved.instructions`
    # and subsequently written into CLAUDE.md by the cc compile path
    # (`Ezagent.Kind.Template.compile_cc_agent_data`).  When soul is nil the
    # existing bare `file_flavor_template/4` path is unchanged (no behavior
    # change for the soul-absent case).
    #
    # Soul-present: manifest_cc_tmpl/3 may return {:error, {:soul_render_failed, _}}
    # when to_template_content fails.  Guard here so we propagate the failure to
    # the caller rather than silently creating a personaless agent (invariant #9).
    with {:ok, tmpl} <- resolve_cc_tmpl(agent_uri, cwd, Map.get(params, :soul)) do
      register_and_invoke_template(
        session_templates,
        workspace_name,
        workspace_uri,
        tmpl_name,
        tmpl,
        agent_uri,
        Map.get(params, :caller),
        Map.get(params, :caps),
        Map.get(params, :from_uri)
      )
    end
  end

  defp do_create_agent("cc-headless", agent_uri, session_templates, params) do
    %{
      cwd: cwd,
      workspace_name: workspace_name,
      workspace_uri: workspace_uri
    } = params

    tmpl_name = "cc_headless.agent." <> agent_name(agent_uri)

    tmpl = file_flavor_template("cc-headless", "cc_headless.agent", agent_uri, cwd)

    register_and_invoke_template(
      session_templates,
      workspace_name,
      workspace_uri,
      tmpl_name,
      tmpl,
      agent_uri,
      Map.get(params, :caller),
      Map.get(params, :caps),
      nil
    )
  end

  defp do_create_agent("echo", agent_uri, session_templates, params) do
    %{
      cwd: cwd,
      with_pty?: with_pty?,
      workspace_name: workspace_name,
      workspace_uri: workspace_uri
    } = params

    tmpl_name = "echo.agent." <> agent_name(agent_uri)

    tmpl = %{
      "class" => "echo.agent",
      "agent_uri" => agent_uri_string(agent_uri),
      "with_pty" => with_pty?,
      "cwd" => if(with_pty?, do: Path.expand(cwd), else: cwd)
    }

    # echo is NOT a file-flavor (no CredentialAdapter, no config home) —
    # nil caps/from keep it on the existing non-cascade Loader path.
    register_and_invoke_template(
      session_templates,
      workspace_name,
      workspace_uri,
      tmpl_name,
      tmpl,
      agent_uri,
      Map.get(params, :caller),
      nil,
      nil
    )
  end

  defp do_create_agent("codex", agent_uri, session_templates, params) do
    %{
      cwd: cwd,
      workspace_name: workspace_name,
      workspace_uri: workspace_uri
    } = params

    tmpl_name = "codex.agent." <> agent_name(agent_uri)

    tmpl = file_flavor_template("codex", "codex.agent", agent_uri, cwd)

    register_and_invoke_template(
      session_templates,
      workspace_name,
      workspace_uri,
      tmpl_name,
      tmpl,
      agent_uri,
      Map.get(params, :caller),
      Map.get(params, :caps),
      Map.get(params, :from_uri)
    )
  end

  defp do_create_agent("codex-remote", agent_uri, session_templates, params) do
    %{
      cwd: cwd,
      workspace_name: workspace_name,
      workspace_uri: workspace_uri
    } = params

    tmpl_name = "codex_remote.agent." <> agent_name(agent_uri)

    tmpl = file_flavor_template("codex-remote", "codex_remote.agent", agent_uri, cwd)

    register_and_invoke_template(
      session_templates,
      workspace_name,
      workspace_uri,
      tmpl_name,
      tmpl,
      agent_uri,
      Map.get(params, :caller),
      Map.get(params, :caps),
      nil
    )
  end

  # Any other flavor (curl / np / future) — direct Kind spawn via the
  # stored flavor declaration. URI names are opaque; do not recover the
  # flavor from the agent URI.
  defp do_create_agent(other_flavor, agent_uri, _session_templates, params) do
    case direct_spawn_flavor_agent(other_flavor, agent_uri) do
      {:ok, _pid} ->
        record_creator_lineage(agent_uri, params)

        with :ok <-
               grant_agent_creator_manage_cap(agent_uri, Map.get(params, :workspace_uri), params) do
          # No slice mutation (no template registered for curl/np).
          {:ok, %{agent_uri: agent_uri, template_name: nil}, []}
        end

      {:error, {:already_started, _pid}} ->
        # Idempotent re-create — do NOT re-record lineage.
        {:ok, %{agent_uri: agent_uri, template_name: nil}, []}

      {:error, reason} ->
        {:error, {:spawn_failed, reason}}
    end
  end

  # PR-6+7 (curl-as-flavor, codex round-3 P1-1 fix) — the direct-create path
  # for a flavor with NO workspace Template (curl / np / future). It now threads
  # the flavor's OPTIONAL per-instance behavior SET (`:instance_behaviors`) as
  # `:behaviors` in the spawn args. This is LOAD-BEARING for curl: curl's `kind`
  # is the SHARED `Entity.Agent`, whose nil-`:kind_base` default set EXCLUDES
  # `Behavior.CurlAgent`. Without threading `curl_behaviors/0` here, a
  # `Workspace.create_agent/3` curl agent captured the BASE (non-curl) set — no
  # `:curl_agent` slice, no `reset_conversation`/`configure`/`sync_result`, no
  # `flavor: "curl"` slice field (that field is written by `Behavior.CurlAgent.create/1`,
  # which only runs when the behavior is in the effective set) — i.e. a broken
  # curl agent. A flavor with its own dedicated Kind (np) declares no thunk →
  # `:behaviors` is omitted → the Kind's full declared set applies (unchanged).
  defp direct_spawn_flavor_agent(flavor, agent_uri) when is_binary(flavor) do
    with {:ok, decl} <- Ezagent.AgentFlavorRegistry.lookup(flavor),
         :ok <- Ezagent.AgentFlavorAttributes.put(agent_uri, flavor) do
      Ezagent.Kind.spawn(decl.kind, spawn_args_for_flavor(decl, agent_uri))
    end
  end

  # Thread `:behaviors` ONLY when the flavor declares a per-instance set
  # (curl). Omitting the key for other flavors preserves the legacy-sentinel
  # rule (`init_set/2`: absent `:behaviors` → the Kind's full declared set).
  defp spawn_args_for_flavor(decl, %URI{} = agent_uri) do
    base = %{uri: agent_uri}

    case Map.get(decl, :instance_behaviors) do
      thunk when is_function(thunk, 0) -> Map.put(base, :behaviors, thunk.())
      _ -> base
    end
  end

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
    do: file_flavor_template(flavor, class_name, agent_uri, cwd)

  @doc false
  # Test-only accessor — the cascade-content builder's no-silent-fallback
  # guard (a file-flavor content missing config_dir is rejected, never spawned).
  def __cascade_content_for_test__(tmpl), do: to_cascade_content(tmpl)

  @doc false
  # Test-only accessor — the soul-enriched cc tmpl (B2: soul → agent_manifest_resolved).
  def __manifest_tmpl_for_test__(agent_uri, cwd, soul),
    do: manifest_cc_tmpl(agent_uri, cwd, soul)

  defp file_flavor_template(flavor, class_name, agent_uri, cwd)
       when is_binary(flavor) and is_binary(class_name) do
    %{
      "class" => class_name,
      "flavor" => flavor,
      "agent_uri" => agent_uri_string(agent_uri),
      "project_cwd" => Path.expand(cwd),
      "config_dir" => per_agent_config_dir(class_name, agent_uri)
    }
  end

  # The per-agent config_dir TARGET — core authority (`Ezagent.Sandbox.ConfigDir`),
  # keyed by the agent URI + the class's namespace. NOT a plugin path builder.
  defp per_agent_config_dir(class_name, %URI{} = agent_uri) do
    {:ok, class_module} = Ezagent.TemplateRegistry.lookup(class_name)
    Ezagent.Sandbox.ConfigDir.path(agent_uri, Ezagent.Kind.Template.namespace_of(class_module))
  end

  # B2 (2026-06-23) — resolve the cc tmpl, returning {:ok, tmpl} or {:error, reason}.
  # Soul-present: delegates to manifest_cc_tmpl/3 which may return
  # {:error, {:soul_render_failed, _}}; propagated to the caller (invariant #9 —
  # no silent personaless agent).  Soul-absent: wraps the bare file_flavor_template
  # in {:ok, _} so do_create_agent/4 can use a uniform `with {:ok, tmpl} <-` guard.
  defp resolve_cc_tmpl(agent_uri, cwd, soul) when is_binary(soul) and soul != "" do
    case manifest_cc_tmpl(agent_uri, cwd, soul) do
      {:error, _} = err -> err
      tmpl_map -> {:ok, tmpl_map}
    end
  end

  defp resolve_cc_tmpl(agent_uri, cwd, _soul) do
    {:ok, file_flavor_template("cc", "cc.agent", agent_uri, cwd)}
  end

  # B2 (2026-06-23) — build a soul-enriched cc tmpl by constructing an inline
  # `%AgentManifest{}` and rendering it into AgentTemplate content via
  # `AgentManifest.to_template_content/4`.  The result is merged onto the bare
  # `file_flavor_template/4` base so the cc create path gets ALL required keys:
  #
  #   "class", "flavor", "agent_uri", "project_cwd", "config_dir"   ← cascade + validate
  #   :agent_manifest_resolved                                        ← cc compile → CLAUDE.md
  #
  # `agent_manifest_resolved.instructions` is the rendered soul string (no slots
  # are needed for a plain-text soul; `slots: %{}`).  The config_dir is derived
  # from the same `per_agent_config_dir/2` call as the bare path so the
  # allocation semantics are identical.
  #
  # NOTE: the soul is stored verbatim in `agent_manifest_resolved` (a TRANSIENT
  # derived field — not persisted as the manifest body).  The persisted tmpl
  # carries `"class"`/`"flavor"`/`"project_cwd"`/`"config_dir"` only (same
  # shape as the bare path) so cold-boot replay is unchanged.
  defp manifest_cc_tmpl(%URI{} = agent_uri, cwd, soul) when is_binary(soul) and soul != "" do
    config_dir = per_agent_config_dir("cc.agent", agent_uri)

    manifest = %Ezagent.AgentManifest{
      name: agent_name(agent_uri),
      soul: soul,
      skills: [],
      tools: [],
      caps: [],
      lifecycle: :persistent,
      executor: %{
        flavor: ["cc"],
        params: %{project_cwd: Path.expand(cwd), config_dir: config_dir},
        fallback: nil,
        on_exhausted: :notify_orchestrator
      }
    }

    case Ezagent.AgentManifest.to_template_content(manifest, "cc", %{}) do
      {:ok, content} ->
        # Merge manifest-resolved overlay onto the base file-flavor tmpl.
        # The base tmpl carries the string-keyed keys that validate_template_class,
        # Store persistence, and to_cascade_content need.  We add the atom-keyed
        # :agent_manifest_resolved so the cascade content (also atom-keyed) can
        # pass it through to spawn_from_template_content → AgentTemplate.to_template_data.
        base = file_flavor_template("cc", "cc.agent", agent_uri, cwd)
        Map.put(base, :agent_manifest_resolved, content[:agent_manifest_resolved])

      {:error, reason} ->
        # Invariant #9 (no silent drop at user-facing surfaces): an operator who
        # requested a soul MUST NOT silently get a personaless agent.  Surface the
        # render failure to the caller instead of falling back to the bare template.
        {:error, {:soul_render_failed, reason}}
    end
  end

  # Register the template in the Workspace's session_templates slice +
  # persist via Store, then instantiate to bring the Agent Kind (+ sidecars)
  # live.
  #
  # FILE-FLAVOR routing (2026-06-07): a credentialled flavor (its Template
  # Class implements `Ezagent.Agent.CredentialAdapter`) instantiates via
  # `Agent.spawn_from_template_content/5` (the #17 cascade chokepoint) so the
  # agent gets an isolated config_dir AND the #17 user-default cascade. A
  # non-credentialled flavor (echo) keeps the existing
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
             %{caller: creator_uri, caps: caller_caps, from_uri: from_uri}
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
  # user-default credential cascade; a non-credentialled flavor (echo) keeps
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
        base = %{flavor: flavor, project_cwd: project_cwd, config_dir: config_dir}

        # B2 (2026-06-23): pass :agent_manifest_resolved AND :agent_manifest_params
        # through when present so `AgentTemplate.to_template_data` →
        # `manifest_compile_payload` can see the soul and route through the cc
        # compile path (`compile_cc_agent_data`).  Both fields are read by
        # `manifest_compile_payload`; without :agent_manifest_params a future
        # `claude_md_preamble` would be silently lost.
        content =
          base
          |> then(fn c ->
            case Map.get(tmpl, :agent_manifest_resolved) do
              resolved when is_map(resolved) -> Map.put(c, :agent_manifest_resolved, resolved)
              _ -> c
            end
          end)
          |> then(fn c ->
            case Map.get(tmpl, :agent_manifest_params) do
              params when is_map(params) -> Map.put(c, :agent_manifest_params, params)
              _ -> c
            end
          end)

        {:ok, content}
    end
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
