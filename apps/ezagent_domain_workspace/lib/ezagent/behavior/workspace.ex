defmodule Ezagent.Behavior.Workspace do
  @moduledoc """
  Workspace Behavior — declarative cluster-shape state for the
  Workspace Kind (Phase 4 D3/D5).

  ## State slice (`:workspace`)

      %{
        members: MapSet.t(URI.t()),
        # session templates: name → %{members: [URI], routing_rules: [map]}
        session_templates: %{String.t() => map()},
        routing_rules: [map()]
      }

  ## Actions

  - `:list_members` — `{:ok, slice, %{members: [URI]}}`
  - `:add_member` — args `%{member: URI}` → adds to MapSet
  - `:remove_member` — args `%{member: URI}` → removes from MapSet
  - `:list_templates` — `{:ok, slice, %{templates: map()}}`
  - `:add_template` — args `%{name: String, template: map}` → put in map
  - `:remove_template` — args `%{name: String}` → drop from map
  - `:list_routing_rules` — `{:ok, slice, %{rules: [map]}}`
  - `:set_routing_rules` — args `%{rules: [map]}` → replace list
  - `:instantiate` — returns the children list this Workspace declares:
    `{:ok, slice, %{children: [{kind_module, args_map, uri}]}}`.
    The caller (Phase 4c `Ezagent.Workspace.Loader`) walks the list and
    spawns each via plugin-registered spawn functions.

  ## Why `:instantiate` returns data, not side-effects

  Plugin isolation: `ezagent_core` does not know which plugin owns which
  Kind's supervisor. The Workspace Kind itself stays plugin-agnostic
  by returning the declared shape; the Loader injects the spawn
  policy (DI at the boundary, per the north star).

  Phase 4b: only members are translated to children (each member URI
  becomes a child to spawn). Session templates and routing rules are
  carried in state but not yet materialized — Phase 4c wires them.
  """

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions do
    [
      :list_members,
      :add_member,
      :remove_member,
      :list_templates,
      :add_template,
      :remove_template,
      :list_routing_rules,
      :set_routing_rules,
      :instantiate,
      # SPEC `docs/superpowers/specs/2026-05-25-agent-create-cli-gui-parity.md`:
      # unified agent-create entry. CLI + LV both dispatch this; the
      # action body owns the LV's prior `register_and_instantiate/3`
      # orchestration (template registration + Loader.invoke_template +
      # direct-spawn fallback for flavors with no Template Class).
      :create_agent,
      # SPEC `docs/superpowers/specs/2026-05-26-session-create-orchestrator-unified.md`
      # Gap C: unified session-create entry. CLI + LV both reach
      # `EzagentDomainChat.create_session/3` through this action so a
      # `mix ezagent workspace create_session ...` invocation produces
      # the same session URI shape (and same auto-spawned orchestrator)
      # as the LV "New session" form.
      :create_session
    ]
  end

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Workspace is registered on the Workspace Kind only — kind axis is
  # `:workspace`. workspace_scoped? defaults to true (intra-workspace
  # admin); the structural ws-cap-set on `workspace://system` members
  # bypasses isolation via step 5.6.
  @impl Ezagent.Behavior
  def required_caps do
    %{
      list_members: Ezagent.Capability.cap(:workspace, __MODULE__, :list_members),
      add_member: Ezagent.Capability.cap(:workspace, __MODULE__, :add_member),
      remove_member: Ezagent.Capability.cap(:workspace, __MODULE__, :remove_member),
      list_templates: Ezagent.Capability.cap(:workspace, __MODULE__, :list_templates),
      add_template: Ezagent.Capability.cap(:workspace, __MODULE__, :add_template),
      remove_template: Ezagent.Capability.cap(:workspace, __MODULE__, :remove_template),
      list_routing_rules:
        Ezagent.Capability.cap(:workspace, __MODULE__, :list_routing_rules),
      set_routing_rules: Ezagent.Capability.cap(:workspace, __MODULE__, :set_routing_rules),
      instantiate: Ezagent.Capability.cap(:workspace, __MODULE__, :instantiate),
      create_agent: Ezagent.Capability.cap(:workspace, __MODULE__, :create_agent),
      # SPEC `docs/superpowers/specs/2026-05-26-session-create-orchestrator-unified.md`
      # Gap C — workspace-scoped session creation. Invariant #2: cap
      # subject uses MODULE reference (`__MODULE__`), not atom shorthand.
      create_session:
        Ezagent.Capability.cap(:workspace, __MODULE__, :create_session)
    }
  end

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:list_members, "list members (user URIs) of this workspace"},
      {:add_member, "add a user URI to this workspace's member set"},
      {:remove_member, "remove a user URI from this workspace's member set"},
      {:list_templates,
       "list templates (SessionTemplate / AgentTemplate) bound to this workspace"},
      {:add_template, "bind a template version to this workspace"},
      {:remove_template, "unbind a template from this workspace"},
      {:list_routing_rules, "list workspace-scoped routing rules"},
      {:set_routing_rules, "replace the workspace's routing rule set"},
      {:instantiate, "instantiate a fresh workspace from a workspace template"},
      {:create_agent,
       "create a new agent in this workspace (registers Template Class, " <>
         "spawns Agent Kind, starts PTY for cc / echo-with-PTY)"},
      {:create_session,
       "create a new session in this workspace + auto-spawn the " <>
         "orchestrator agent owned by the caller (SPEC " <>
         "2026-05-26-session-create-orchestrator-unified Gap C)"}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :workspace

  @impl Ezagent.Behavior
  def init_slice(args) do
    %{
      members: read_members(args),
      session_templates: Map.get(args, :session_templates, %{}),
      routing_rules: Map.get(args, :routing_rules, [])
    }
  end

  defp read_members(args) do
    case Map.get(args, :members) do
      nil -> MapSet.new()
      %MapSet{} = set -> set
      list when is_list(list) -> MapSet.new(list)
    end
  end

  # --- members ---------------------------------------------------------

  @impl Ezagent.Behavior
  def invoke(:list_members, slice, _args, _ctx) do
    {:ok, slice, %{members: MapSet.to_list(slice.members)}}
  end

  def invoke(:add_member, slice, %{member: %URI{} = uri}, ctx) do
    # Task #55 (Allen 2026-05-27) — workspace prefix invariant. The
    # workspace's member set MAY ONLY contain entities whose URI prefix
    # matches the workspace. `entity://user/<workspace>/...` OR
    # `entity://agent/<workspace>/...`. A member URI like
    # `entity://user/system/linyilun` is REJECTED inside `h2oslabs`
    # because the URI's workspace segment (`system`) doesn't match the
    # workspace name (`h2oslabs`).
    #
    # Empirically observed violation (Allen 2026-05-27 02:47 via RPC):
    # the h2oslabs workspace row carried `entity://user/system/linyilun`
    # as a member — a cross-prefix leak. The structural fix lives here
    # so EVERY dispatch path is covered, not just the facade.
    #
    # Validation happens BEFORE the codex PR #408 round-2 MED-2 cap
    # grant so a rejected member never receives the `:create_session`
    # cap. Order: validate → grant → mutate slice.
    workspace_uri = Map.get(ctx, :self_uri)

    with :ok <- validate_member_prefix(uri, workspace_uri) do
      # codex PR #408 review round-2 MED-2 — fire the `:create_session`
      # cap grant from the Behavior action so EVERY dispatch-level
      # caller (not only the `Ezagent.Workspace.add_member/2` facade)
      # covers workspace members. Best-effort: the helper logs +
      # telemetry's failures but does NOT bubble — membership has its
      # own value (messaging, presence) even if cap-grant raced or the
      # user is already in caps.
      grant_member_create_session_cap(workspace_uri, uri)

      {:ok, %{slice | members: MapSet.put(slice.members, uri)}}
    end
  end

  # Task #55 — workspace prefix validator. Extracts the workspace
  # segment from the member URI's path (per SPEC v3 §3 entity URI shape
  # `entity://<type>/<workspace>/<name>`) and confirms it matches the
  # workspace URI's host. Non-entity members are rejected outright —
  # `system://`/`workspace://`/`session://` URIs have no business in a
  # workspace's member set (membership models "who lives in this
  # workspace", and only entities live).
  #
  # When `workspace_uri` is missing (`ctx.self_uri == nil`), we let it
  # through to preserve the existing test surface for unit tests that
  # drive `invoke/4` directly with an empty ctx. The structural call
  # site (`Ezagent.Kind.Server`) always populates `self_uri`, so
  # production paths get the check; tests that intentionally want to
  # bypass it can keep ctx empty.
  defp validate_member_prefix(_member_uri, nil), do: :ok

  defp validate_member_prefix(
         %URI{scheme: "entity", path: "/" <> rest} = member_uri,
         %URI{scheme: "workspace", host: workspace_name} = workspace_uri
       )
       when is_binary(workspace_name) and workspace_name != "" do
    case String.split(rest, "/", parts: 2) do
      [^workspace_name, entity_name] when entity_name != "" ->
        :ok

      [_other_workspace, _entity_name] ->
        {:error, {:cross_workspace_member_not_permitted, member_uri, workspace_uri}}

      _ ->
        # Non-3-segment entity URI — structurally malformed under
        # SPEC v3. Reject (the URI parser would normally catch this
        # earlier, but defense in depth).
        {:error, {:bad_member_uri, member_uri}}
    end
  end

  defp validate_member_prefix(%URI{} = member_uri, %URI{} = workspace_uri) do
    # Non-entity member (system://, workspace://, …) — refuse. Only
    # `entity://user/...` / `entity://agent/...` are valid workspace
    # members per the prefix invariant.
    {:error, {:non_entity_member, member_uri, workspace_uri}}
  end

  def invoke(:remove_member, slice, %{member: %URI{} = uri}, _ctx) do
    {:ok, %{slice | members: MapSet.delete(slice.members, uri)}}
  end

  # --- session templates ----------------------------------------------

  def invoke(:list_templates, slice, _args, _ctx) do
    {:ok, slice, %{templates: slice.session_templates}}
  end

  def invoke(:add_template, slice, %{name: name, template: tmpl}, _ctx)
      when is_binary(name) and is_map(tmpl) do
    {:ok, %{slice | session_templates: Map.put(slice.session_templates, name, tmpl)}}
  end

  def invoke(:remove_template, slice, %{name: name}, _ctx) when is_binary(name) do
    {:ok, %{slice | session_templates: Map.delete(slice.session_templates, name)}}
  end

  # --- routing rules ---------------------------------------------------

  def invoke(:list_routing_rules, slice, _args, _ctx) do
    {:ok, slice, %{rules: slice.routing_rules}}
  end

  def invoke(:set_routing_rules, slice, %{rules: rules}, _ctx) when is_list(rules) do
    {:ok, %{slice | routing_rules: rules}}
  end

  # --- create_agent (unified CLI/LV agent provisioning) ---------------
  #
  # SPEC `docs/superpowers/specs/2026-05-25-agent-create-cli-gui-parity.md`.
  # Runs inside the Workspace Kind GenServer. Body wraps what the LV
  # `register_and_instantiate/3` clauses did before this PR. The dispatch
  # entry is the `Ezagent.Workspace.create_agent/3` facade.
  #
  # cc / echo:  register a Workspace-scoped template → mutate slice →
  #             persist via Store.update_templates → call
  #             Ezagent.Workspace.Loader.invoke_template (Template Class
  #             instantiates Agent Kind + PtyServer).
  # curl / other: direct SpawnRegistry.spawn (the only allowlisted call
  #             site for `entity://agent/` URIs per the invariant test
  #             `agent_create_single_path_test.exs`).
  def invoke(:create_agent, slice, args, ctx) when is_map(args) do
    raw_workspace_uri = Map.get(ctx, :self_uri)

    with {:ok, flavor, name, cwd, with_pty?, from_uri} <- coerce_create_args(args),
         :ok <- validate_flavor(flavor),
         :ok <- validate_name(name),
         :ok <- validate_cwd_for_flavor(flavor, with_pty?, cwd),
         :ok <- validate_from_for_flavor(flavor, from_uri),
         {:ok, workspace_uri} <- require_workspace_uri(raw_workspace_uri),
         workspace_name = workspace_uri.host,
         {:ok, agent_uri} <- compose_agent_uri(flavor, name, workspace_name),
         :ok <- refuse_if_exists(agent_uri),
         {:ok, source_config_dir} <- resolve_source_config_dir(from_uri, ctx) do
      do_create_agent(flavor, agent_uri, slice, %{
        cwd: cwd,
        with_pty?: with_pty?,
        workspace_name: workspace_name,
        workspace_uri: workspace_uri,
        source_config_dir: source_config_dir,
        # Allen 2026-05-26 (codex HIGH-1 closure) — thread the caller
        # URI through so the SpawnRegistry direct-spawn catch-all can
        # record lineage (`Ezagent.AgentLineage.record/2`) for the
        # newly-created agent. Without lineage, `Behavior.ApiKeys`'s
        # `data_owner/1` collapses to `:no_owner` for curl/np agents
        # created via this LV path, which forces the API-keys LV
        # permission gate to admin-only for non-admin creators —
        # the documented footgun in the codex review.
        caller: Map.get(ctx, :caller)
      })
    end
  end

  # --- create_session (unified CLI/LV session provisioning) -----------
  #
  # SPEC `docs/superpowers/specs/2026-05-26-session-create-orchestrator-unified.md`
  # Gap C. Wraps `EzagentDomainChat.create_session/3` so the CLI and LV
  # share one entry. Translates the facade's 3-tuple meta map into a
  # Workspace.invoke return shape with the orchestrator URI/status
  # surfaced for the caller (CLI human-readable formatter; LV flash).
  #
  # Workspace authority: the action runs in the Workspace Kind, so
  # `ctx.self_uri` is the workspace URI — passed as `:workspace_uri` to
  # the facade. The caller URI is the session creator (becomes the
  # session owner_uri + receives the OrchestratorAdmin :restart cap).
  def invoke(:create_session, slice, args, ctx) when is_map(args) do
    workspace_uri = Map.get(ctx, :self_uri)
    caller = Map.get(ctx, :caller)

    with {:ok, short_name, template_name} <- coerce_create_session_args(args),
         {:ok, %URI{} = workspace_uri} <- require_session_workspace_uri(workspace_uri),
         {:ok, %URI{} = caller} <- require_caller(caller),
         {:ok, facade} <- resolve_session_facade() do
      case facade.create_session(short_name, caller,
             workspace_uri: workspace_uri,
             template_name: template_name
           ) do
        {:ok, %URI{} = session_uri, meta} when is_map(meta) ->
          {:ok, slice,
           %{
             session_uri: session_uri,
             orchestrator_uri: Map.get(meta, :orchestrator_uri),
             orchestrator_status: Map.get(meta, :orchestrator_status),
             orchestrator_error: format_orchestrator_error(Map.get(meta, :orchestrator_error))
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # SPEC `2026-05-26-session-create-orchestrator-unified` Gap C — DI
  # provider lookup for the session-creation facade. `ezagent_domain_chat`
  # depends on `ezagent_domain_workspace` (workspace boots first), so a
  # compile-time alias would invert the dep graph and create a cycle.
  # Instead the facade module is looked up at runtime via the
  # application env key (default: `EzagentDomainChat`). Tests can
  # override via `Application.put_env(:ezagent_domain_workspace,
  # :session_facade, FakeFacade)` to drive `:create_session` without
  # the full chat domain.
  defp resolve_session_facade do
    facade =
      Application.get_env(:ezagent_domain_workspace, :session_facade, EzagentDomainChat)

    if Code.ensure_loaded?(facade) and function_exported?(facade, :create_session, 3) do
      {:ok, facade}
    else
      {:error, {:session_facade_unavailable, facade}}
    end
  end

  defp coerce_create_session_args(args) do
    short_name = Map.get(args, :short_name) || Map.get(args, :name)
    template_name = Map.get(args, :template_name) || Map.get(args, :template)

    cond do
      not is_binary(short_name) or short_name == "" ->
        {:error, :short_name_required}

      not is_binary(template_name) or template_name == "" ->
        {:error, :template_name_required}

      true ->
        {:ok, String.trim(short_name), String.trim(template_name)}
    end
  end

  defp require_session_workspace_uri(%URI{scheme: "workspace", host: host} = uri)
       when is_binary(host) and host != "",
       do: {:ok, uri}

  defp require_session_workspace_uri(other),
    do: {:error, {:bad_workspace_uri, other}}

  defp require_caller(%URI{} = caller), do: {:ok, caller}
  defp require_caller(other), do: {:error, {:bad_caller, other}}

  # Format the orchestrator_error term for the CLI/LV consumers.
  # `nil` (happy path) stays `nil`; non-nil gets stringified so the
  # auto-derived CLI formatter doesn't trip on opaque tuples.
  defp format_orchestrator_error(nil), do: nil
  defp format_orchestrator_error(err), do: inspect(err)

  # --- instantiate (the north-star action) -----------------------------

  def invoke(:instantiate, slice, _args, _ctx) do
    # Phase 4-completion: emit both member spawns and template
    # instantiations. Loader walks each child tuple and dispatches to
    # SpawnRegistry (members) or TemplateRegistry (templates).
    # Members ordered first so any Session-Template member dependencies
    # are already alive when chat/join fires (cast + PendingDelivery
    # makes this not strictly necessary but reduces inbox noise).
    member_children =
      slice.members
      |> Enum.map(fn %URI{} = uri -> {:member, uri} end)

    template_children =
      slice.session_templates
      |> Enum.map(fn {tmpl_name, tmpl_data} ->
        {:template, tmpl_name, tmpl_data}
      end)

    {:ok, slice, %{children: member_children ++ template_children}}
  end

  # --- interface (adapter generation + arg validation) ----------------

  @impl Ezagent.Behavior
  def interface do
    %{
      list_members: %{
        description: "List the workspace's member URIs",
        args: %{},
        returns: %{members: {:list, :uri}},
        modes: [:call]
      },
      add_member: %{
        description: "Add an entity URI to the workspace's member set",
        args: %{member: :uri},
        returns: %{},
        modes: [:cast, :call]
      },
      remove_member: %{
        description: "Remove an entity URI from the workspace's member set",
        args: %{member: :uri},
        returns: %{},
        modes: [:cast, :call]
      },
      list_templates: %{
        description: "List the workspace's session templates",
        args: %{},
        returns: %{templates: :map},
        modes: [:call]
      },
      add_template: %{
        description: "Add or replace a named session template",
        args: %{name: :string, template: :map},
        returns: %{},
        modes: [:cast, :call]
      },
      remove_template: %{
        description: "Remove a named session template",
        args: %{name: :string},
        returns: %{},
        modes: [:cast, :call]
      },
      list_routing_rules: %{
        description: "List the workspace's routing rules",
        args: %{},
        returns: %{rules: {:list, :map}},
        modes: [:call]
      },
      set_routing_rules: %{
        description: "Replace the workspace's routing rule list",
        args: %{rules: {:list, :map}},
        returns: %{},
        modes: [:cast, :call]
      },
      instantiate: %{
        description: "Return the child entities + templates this workspace declares",
        args: %{},
        returns: %{children: {:list, :tuple}},
        modes: [:call]
      },
      create_agent: %{
        description:
          "Provision a new agent (Template Class + spawn) in this workspace. " <>
            "Unified entry — CLI + LV both dispatch this. See SPEC " <>
            "2026-05-25-agent-create-cli-gui-parity. Optional `from` " <>
            "(source agent URI) clones the source's per-agent config_dir " <>
            "via the cc Template Class's existing claude_config_dir " <>
            "reference-copy path; requires `sandbox.read` on source.",
        args: %{
          flavor: :string,
          name: :string,
          cwd: :string,
          with_pty: :boolean,
          # Optional source agent URI for `--from` cloning. Absent or
          # nil ⇒ no clone. Validated structurally by
          # `coerce_create_args/1`; cap-check + slice resolution by
          # `resolve_source_config_dir/2`.
          from: {:option, :uri}
        },
        returns: %{agent_uri: :uri, template_name: :string},
        modes: [:call]
      },
      # SPEC 2026-05-26-session-create-orchestrator-unified Gap C.
      create_session: %{
        description:
          "Create a new session in this workspace + auto-spawn the " <>
            "orchestrator agent owned by the caller. Unified entry — CLI " <>
            "`mix ezagent workspace create_session --workspace ... " <>
            "--short-name <name> --template-name <class>` and the LV " <>
            "form both reach `EzagentDomainChat.create_session/3` through " <>
            "this action. SPEC " <>
            "2026-05-26-session-create-orchestrator-unified Gap C.",
        args: %{
          short_name: :string,
          template_name: :string
        },
        returns: %{
          session_uri: :uri,
          orchestrator_uri: {:option, :uri},
          orchestrator_status: :atom,
          orchestrator_error: {:option, :string}
        },
        modes: [:call]
      }
    }
  end

  # PR-OWN-4 (caps-data-ownership SPEC #306 §6): workspace-scoped
  # Behavior — workspace admin grants. `:any` return signals
  # "class-wide cap, grantable by workspace admin via §5.2 admin branch".
  @impl Ezagent.Behavior
  def data_owner(_), do: :any

  # =================================================================
  # `:create_agent` helpers (SPEC 2026-05-25-agent-create-cli-gui-parity)
  # =================================================================
  # These mirror what was previously in
  # `EzagentPluginLiveview.AgentNewLive` so the CLI and LV share one
  # code path. Validators stay simple + crash-fast — the LV keeps its
  # own UX-facing validators for early feedback, the action body
  # re-runs as a safety net (defence in depth).

  # CLI builds atom-keyed maps. The current dispatch path (local-
  # in-process for the mix task + LV) preserves atom keys end-to-end;
  # `Ezagent.InterfaceValidator` also only checks atom-keyed schemas
  # (codex PR #330 r1 MEDIUM noted string-key support was dead code).
  # We keep atom-only here — a future remote-RPC adapter that
  # serialises to JSON would coerce string keys back to atoms BEFORE
  # dispatch as part of its parse step, not inside the action body.
  #
  # Codex PR #330 r1 MEDIUM-7 also flagged a `false || true` bug:
  # `args[:with_pty] || args["with_pty"] || false` would treat an
  # explicit `with_pty: false` as falsy and fall through. Switched
  # to `Map.get/3` with a default so an explicit `false` is preserved.
  defp coerce_create_args(args) do
    flavor = Map.get(args, :flavor)
    name = Map.get(args, :name)
    cwd = Map.get(args, :cwd, "")
    with_pty = Map.get(args, :with_pty, false)
    # `--from <source-uri>` — optional. nil ⇒ no clone (legacy path).
    # When set, must be a `%URI{scheme: "entity", host: "agent"}`.
    # Coerce-stage rejects bad shapes early; cap-check + source slice
    # resolution happen later via `resolve_source_config_dir/2`.
    from = Map.get(args, :from)

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

      true ->
        {:ok, String.trim(flavor), String.trim(name), String.trim(cwd), with_pty, from}
    end
  end

  defp valid_from?(nil), do: true

  defp valid_from?(%URI{scheme: "entity", host: "agent", path: "/" <> _}), do: true

  defp valid_from?(_), do: false

  defp require_workspace_uri(%URI{scheme: "workspace", host: host} = uri)
       when is_binary(host) and host != "",
       do: {:ok, uri}

  defp require_workspace_uri(other), do: {:error, {:bad_workspace_uri, other}}

  # Flavor validation: must be registered in AgentFlavorRegistry. Empty
  # registry (test bootstrap) falls back to the well-known 4 names so a
  # unit test that doesn't boot plugins can still drive the action body.
  defp validate_flavor(""), do: {:error, :flavor_required}

  defp validate_flavor(flavor) when is_binary(flavor) do
    case Ezagent.AgentFlavorRegistry.list_all() do
      [] ->
        if flavor in ~w(cc echo curl np),
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

  defp validate_cwd_for_flavor("echo", true, ""), do: {:error, :cwd_required_for_echo_with_pty}
  defp validate_cwd_for_flavor("echo", true, cwd), do: validate_cwd_dir(cwd)
  defp validate_cwd_for_flavor("echo", false, _cwd), do: :ok

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
  # CLAUDE_CONFIG_DIR concept. Rejecting up front keeps the error
  # close to the operator's mistake (vs surfacing later as a Template
  # Class refusal).
  defp validate_from_for_flavor(_flavor, nil), do: :ok
  defp validate_from_for_flavor("cc", %URI{}), do: :ok

  defp validate_from_for_flavor(other_flavor, %URI{}),
    do: {:error, {:from_unsupported_for_flavor, other_flavor}}

  # Resolve the source agent's per-agent config_dir by dispatching
  # `sandbox.read` on the source URI WITH THE CALLER'S CAPS. This:
  #
  #  - Enforces `sandbox.read` on source via standard CapBAC (no new
  #    cap subject, no parallel auth path). Caller without it →
  #    dispatch returns `{:error, :unauthorized}` → we map to
  #    `:source_not_readable` so the operator sees the actual
  #    permission shape.
  #  - Returns `{:error, :source_not_found}` when the source Agent
  #    Kind isn't alive (ReadyGate :no_such_actor) — distinguishes a
  #    typo from a permission denial.
  #  - On success returns the source's `config_dir_path` (or nil if
  #    the source has no per-agent dir — e.g. an echo agent. We treat
  #    nil as `:source_has_no_config_dir`; cloning would be a no-op
  #    and silently degrade to a fresh agent, which masks operator
  #    error).
  #
  # ORDER MATTERS — this step is in the main `with` chain BEFORE
  # `do_create_agent`. A `{:error, _}` here short-circuits BEFORE any
  # template registration, Store write, or filesystem op. The "no fs
  # operations on cap-deny" guarantee from the spec's test #3.
  defp resolve_source_config_dir(nil, _ctx), do: {:ok, nil}

  defp resolve_source_config_dir(%URI{} = source_uri, ctx) do
    target = URI.new!("#{URI.to_string(source_uri)}?action=sandbox.read")

    caller = Map.fetch!(ctx, :caller)
    caps = Map.fetch!(ctx, :caps)

    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: %{caller: caller, caps: caps, reply: {:caller_inbox, self()}}
         }) do
      {:ok, %{config_dir_path: path}} when is_binary(path) and path != "" ->
        {:ok, path}

      {:ok, %{config_dir_path: nil}} ->
        # Source has no per-agent config_dir — nothing to clone.
        # Surfacing as an error (vs silently spawning a fresh agent)
        # tells the operator their `--from` was meaningless: probably
        # they pointed at the wrong agent.
        {:error, :source_has_no_config_dir}

      {:ok, other} ->
        # Sandbox.read returned an unexpected shape — fail loudly.
        {:error, {:source_read_unexpected_shape, other}}

      {:error, :unauthorized} ->
        {:error, :source_not_readable}

      {:error, :no_such_actor} ->
        {:error, :source_not_found}

      {:error, reason} ->
        {:error, {:source_read_failed, reason}}
    end
  end

  # Per SPEC v3 §3 / Phase 9 PR-2 — entity URI is
  # `entity://agent/<workspace>/<flavor>_<name>`.
  defp compose_agent_uri(flavor, name, workspace_name)
       when is_binary(flavor) and is_binary(name) and is_binary(workspace_name) do
    full = "entity://agent/#{workspace_name}/#{flavor}_#{name}"

    case URI.new(full) do
      {:ok, %URI{scheme: "entity", host: "agent", path: "/" <> _} = u} -> {:ok, u}
      _ -> {:error, {:bad_uri, full}}
    end
  end

  defp refuse_if_exists(%URI{} = uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      :error -> :ok
      {:ok, _pid} -> {:error, {:already_exists, URI.to_string(uri)}}
    end
  end

  # cc / echo → register a Workspace-scoped template + persist + invoke.
  defp do_create_agent("cc", agent_uri, slice, params) do
    %{
      cwd: cwd,
      workspace_name: workspace_name,
      workspace_uri: workspace_uri,
      source_config_dir: source_config_dir
    } = params

    tmpl_name = "cc.agent." <> agent_name(agent_uri)

    tmpl =
      %{
        "class" => "cc.agent",
        "agent_uri" => URI.to_string(agent_uri),
        "cwd" => Path.expand(cwd)
      }
      |> maybe_put_clone_source(source_config_dir)

    register_and_invoke_template(
      slice,
      workspace_name,
      workspace_uri,
      tmpl_name,
      tmpl,
      agent_uri
    )
  end

  defp do_create_agent("echo", agent_uri, slice, params) do
    %{
      cwd: cwd,
      with_pty?: with_pty?,
      workspace_name: workspace_name,
      workspace_uri: workspace_uri
    } = params

    tmpl_name = "echo.agent." <> agent_name(agent_uri)

    tmpl = %{
      "class" => "echo.agent",
      "agent_uri" => URI.to_string(agent_uri),
      "with_pty" => with_pty?,
      # Always include the cwd field; the template validator only
      # requires it when `with_pty: true`. Path.expand("") is "" so
      # this round-trips safely for the no-PTY case.
      "cwd" => if(with_pty?, do: Path.expand(cwd), else: cwd)
    }

    register_and_invoke_template(
      slice,
      workspace_name,
      workspace_uri,
      tmpl_name,
      tmpl,
      agent_uri
    )
  end

  # Any other flavor (curl / np / future) — direct SpawnRegistry.spawn.
  # This is the ONLY allowlisted `SpawnRegistry.spawn(entity://agent/...)`
  # call site per `agent_create_single_path_test.exs`. `{:already_started, _}`
  # is treated as success — `refuse_if_exists/1` upstream already rejected
  # duplicates against a stale registry view; this guards against a tight race.
  #
  # Codex PR #330 r1 HIGH-4: curl + np have registered Template
  # Classes (CurlAgentTemplate / NpAgentTemplate) that this catch-all
  # silently bypasses. PRESERVED PRE-PR BEHAVIOUR — the LV's old
  # `register_and_instantiate(_, agent_uri, _)` direct-spawned them
  # for the same reason: their Template Classes require flavor-
  # specific fields (`provider`, `api_url`, `model` for curl;
  # `cwd`, `timeout` for np) that this action's args don't carry.
  # FOLLOW-UP: extend args to accept `template_args :: map()` so the
  # action can build a full template for any flavor with a registered
  # Template Class. Tracked in `docs/futures/todo.md`.
  defp do_create_agent(_other_flavor, agent_uri, slice, params) do
    case Ezagent.SpawnRegistry.spawn(agent_uri) do
      {:ok, _pid} ->
        record_creator_lineage(agent_uri, params)
        {:ok, slice, %{agent_uri: agent_uri, template_name: nil}}

      {:error, {:already_started, _pid}} ->
        # Idempotent re-create — do NOT re-record lineage (we didn't
        # create this agent; preserving existing lineage is correct).
        {:ok, slice, %{agent_uri: agent_uri, template_name: nil}}

      {:error, reason} ->
        {:error, {:spawn_failed, reason}}
    end
  end

  # Allen 2026-05-26 (codex HIGH-1 closure) — record `agent_uri → caller`
  # in `Ezagent.AgentLineage` so `Behavior.ApiKeys.data_owner/1` (and
  # any future `{:spawned_by, _}` cap-shape resolver) can resolve the
  # agent's creator. Best-effort: a missing caller (system-internal
  # spawn) leaves no lineage row, which falls back to admin-only edit
  # via the LV gate — same conservative posture as before.
  defp record_creator_lineage(agent_uri, params) do
    case Map.get(params, :caller) do
      %URI{} = caller ->
        Ezagent.AgentLineage.record(agent_uri, caller)

      _ ->
        :ok
    end
  end

  # `--from` cloning works by overriding the cc Template Class's
  # `claude_config_dir` field with the SOURCE agent's per-agent dir.
  # The Template Class already supports `claude_config_dir` as the
  # "reference dir copied into the per-agent location at spawn"
  # (Allen 2026-05-24 PR3 — `create_agent_config_dir/2` does the
  # `File.cp_r/2`). Passing the source's per-agent dir as that
  # reference makes the new agent's per-agent dir a deep copy of
  # the source's — exactly the clone semantics requested.
  #
  # IMPORTANT: this is per-agent → per-agent copy. The two dirs are
  # then independent (post-copy mutations on either don't affect the
  # other) — verified by the deep-copy-independence test in
  # `cc_agent_clone_from_test.exs`.
  defp maybe_put_clone_source(tmpl, nil), do: tmpl

  defp maybe_put_clone_source(tmpl, source_config_dir)
       when is_binary(source_config_dir) do
    Map.put(tmpl, "claude_config_dir", source_config_dir)
  end

  # Register the template in the Workspace's session_templates slice +
  # persist via Store, then call Loader.invoke_template to bring the
  # Agent Kind (+ sidecars) live.
  #
  # Codex PR #330 r1 HIGH-1 fix: if invoke_template_now fails, roll
  # back the Store write so the DB doesn't carry a template the caller
  # was told failed. Without rollback, the next boot's
  # Loader.load_all/0 would silently instantiate the failed template
  # (no CapBAC re-check, no operator visibility). The slice itself is
  # NOT committed (the action returns {:error, _} so Kind.Server skips
  # the snapshot write); the Store is the surface that diverges.
  # Same risk existed pre-PR in `Ezagent.Workspace.add_template/3`;
  # this is the first fix and a follow-up may lift it into the facade.
  defp register_and_invoke_template(
         slice,
         workspace_name,
         workspace_uri,
         tmpl_name,
         tmpl,
         agent_uri
       ) do
    with :ok <- validate_template_class(tmpl),
         new_slice = put_template_in_slice(slice, tmpl_name, tmpl),
         {:ok, _decoded} <-
           Ezagent.Workspace.Store.update_templates(
             workspace_name,
             new_slice.session_templates
           ),
         :ok <- invoke_or_rollback(workspace_uri, workspace_name, tmpl_name, slice) do
      {:ok, new_slice, %{agent_uri: agent_uri, template_name: tmpl_name}}
    else
      {:error, _} = err -> err
    end
  end

  # Codex PR #330 r1 HIGH-1 — call invoke_template_now; on failure,
  # roll back the Store.update_templates write to the original slice's
  # session_templates so the DB matches the (uncommitted) starting
  # state. A rollback failure is logged but the original error is the
  # return — operator needs to see the FIRST failure, not the rollback's.
  defp invoke_or_rollback(workspace_uri, workspace_name, tmpl_name, original_slice) do
    case invoke_template_now(workspace_uri, tmpl_name) do
      :ok ->
        :ok

      {:error, _} = err ->
        rollback_store_templates(workspace_name, original_slice, tmpl_name, err)
        err
    end
  end

  defp rollback_store_templates(workspace_name, original_slice, tmpl_name, original_err) do
    case Ezagent.Workspace.Store.update_templates(
           workspace_name,
           original_slice.session_templates
         ) do
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
  defp validate_template_class(tmpl) do
    case extract_class_name(tmpl) do
      nil ->
        {:error, :missing_class_field}

      class_name ->
        case Ezagent.TemplateRegistry.lookup(class_name) do
          :error ->
            {:error, {:no_template_class, class_name}}

          {:ok, class_module} ->
            if function_exported?(class_module, :validate, 1) do
              class_module.validate(tmpl)
            else
              :ok
            end
        end
    end
  end

  defp extract_class_name(%{"class" => name}) when is_binary(name) and name != "", do: name
  defp extract_class_name(%{class: name}) when is_binary(name) and name != "", do: name
  defp extract_class_name(_), do: nil

  defp put_template_in_slice(slice, tmpl_name, tmpl) do
    %{slice | session_templates: Map.put(slice.session_templates, tmpl_name, tmpl)}
  end

  defp invoke_template_now(%URI{} = workspace_uri, tmpl_name) do
    case Ezagent.Workspace.Loader.invoke_template(workspace_uri, tmpl_name) do
      {:ok, _uris} -> :ok
      # Idempotent — already running.
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} = err -> err
    end
  end

  # Per SPEC v3 §3, entity URI path is `/<workspace>/<entity_name>`.
  defp agent_name(%URI{path: "/" <> rest}) do
    case String.split(rest, "/", parts: 2) do
      [_workspace, entity_name] -> entity_name
      [name] -> name
    end
  end

  # codex PR #408 review round-2 MED-2 — grant the workspace
  # `:create_session` cap to a newly-added user member. Lives on the
  # Behavior (not just the facade) so dispatch-level `add_member`
  # callers receive the cap too. Uses dispatch + SystemPrincipal
  # mediation so step 5.5 CapBAC, audit telemetry, and the
  # cap-equality dedup all fire. Skipped for agent members (agents
  # don't drive create_session). Best-effort: failure logs +
  # telemetry, never bubbled up — membership has its own value.
  #
  # KNOWN OVER-GRANT (codex PR #408 round-3 HIGH; see
  # `docs/futures/todo.md` §"Capability struct lacks an action axis"
  # for the full discussion + planned fix). Because the Capability
  # struct has no `action` field, the cap granted here also satisfies
  # the cap-check for every OTHER `Behavior.Workspace` action on the
  # same workspace (`add_member`, `remove_member`, `set_routing_rules`,
  # `create_agent`, …). This is a pre-existing limitation in the cap
  # model affecting every multi-action Behavior; the proper fix is
  # either (a) add `action` to the Capability struct and matches?/2,
  # or (b) carve `:create_session` into its own Behavior per the PR
  # #356 carve-out pattern. Tracked in futures/todo.md.
  defp grant_member_create_session_cap(
         %URI{scheme: "workspace"} = workspace_uri,
         %URI{scheme: "entity", host: "user"} = member_uri
       ) do
    cap = %Ezagent.Capability{
      # Invariant #2 — cap subject uses MODULE reference, not atom
      # shorthand. Matches `required_caps/0`'s `:create_session` entry.
      # SPEC 2026-05-27 capability-action-axis — explicit action axis
      # closes the over-grant gap noted in the comment above this fn.
      kind: :workspace,
      behavior: __MODULE__,
      action: :create_session,
      instance: workspace_uri,
      workspace_uri: workspace_uri,
      granted_by: Ezagent.SystemPrincipal.uri("template-materialize"),
      granted_at: DateTime.utc_now()
    }

    target = URI.new!("#{URI.to_string(member_uri)}?action=identity.grant_cap")

    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{cap: cap},
           ctx: %{
             caller: Ezagent.SystemPrincipal.uri("template-materialize"),
             caps: Ezagent.SystemPrincipal.caps("system://template-materialize"),
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, _} ->
        :ok

      :ok ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning(
          "Behavior.Workspace.add_member: granting :create_session cap to " <>
            "#{URI.to_string(member_uri)} on #{URI.to_string(workspace_uri)} failed: " <>
            "#{inspect(reason)} — member is added but they cannot dispatch " <>
            "`workspace.create_session` (admin grant required as workaround). " <>
            "SPEC 2026-05-26-session-create-orchestrator-unified MED-2 round-2."
        )

        :telemetry.execute(
          [:ezagent, :workspace, :member_create_session_grant_failed],
          %{count: 1},
          %{member_uri: member_uri, workspace_uri: workspace_uri, reason: reason}
        )

        :ok
    end
  rescue
    error ->
      require Logger

      Logger.warning(
        "Behavior.Workspace.add_member: grant_member_create_session_cap raised " <>
          "#{inspect(error)} for member=#{URI.to_string(member_uri)} " <>
          "workspace=#{inspect(workspace_uri)}"
      )

      :ok
  end

  # Non-user member (agent) or missing workspace URI — no grant.
  defp grant_member_create_session_cap(_workspace_uri, _member_uri), do: :ok

end
