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
      :create_agent
    ]
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
         "spawns Agent Kind, starts PTY for cc / echo-with-PTY)"}
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

  def invoke(:add_member, slice, %{member: %URI{} = uri}, _ctx) do
    {:ok, %{slice | members: MapSet.put(slice.members, uri)}}
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

    with {:ok, flavor, name, cwd, with_pty?} <- coerce_create_args(args),
         :ok <- validate_flavor(flavor),
         :ok <- validate_name(name),
         :ok <- validate_cwd_for_flavor(flavor, with_pty?, cwd),
         {:ok, workspace_uri} <- require_workspace_uri(raw_workspace_uri),
         workspace_name = workspace_uri.host,
         {:ok, agent_uri} <- compose_agent_uri(flavor, name, workspace_name),
         :ok <- refuse_if_exists(agent_uri) do
      do_create_agent(flavor, agent_uri, slice, %{
        cwd: cwd,
        with_pty?: with_pty?,
        workspace_name: workspace_name,
        workspace_uri: workspace_uri
      })
    end
  end

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
            "2026-05-25-agent-create-cli-gui-parity.",
        args: %{
          flavor: :string,
          name: :string,
          cwd: :string,
          with_pty: :boolean
        },
        returns: %{agent_uri: :uri, template_name: :string},
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

    cond do
      not is_binary(flavor) ->
        {:error, :flavor_required}

      not is_binary(name) ->
        {:error, :name_required}

      not is_binary(cwd) ->
        {:error, {:bad_cwd, cwd}}

      not is_boolean(with_pty) ->
        {:error, {:bad_with_pty, with_pty}}

      true ->
        {:ok, String.trim(flavor), String.trim(name), String.trim(cwd), with_pty}
    end
  end

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
    %{cwd: cwd, workspace_name: workspace_name, workspace_uri: workspace_uri} = params
    tmpl_name = "cc.agent." <> agent_name(agent_uri)

    tmpl = %{
      "class" => "cc.agent",
      "agent_uri" => URI.to_string(agent_uri),
      "cwd" => Path.expand(cwd)
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
  defp do_create_agent(_other_flavor, agent_uri, slice, _params) do
    case Ezagent.SpawnRegistry.spawn(agent_uri) do
      {:ok, _pid} ->
        {:ok, slice, %{agent_uri: agent_uri, template_name: nil}}

      {:error, {:already_started, _pid}} ->
        {:ok, slice, %{agent_uri: agent_uri, template_name: nil}}

      {:error, reason} ->
        {:error, {:spawn_failed, reason}}
    end
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
end
