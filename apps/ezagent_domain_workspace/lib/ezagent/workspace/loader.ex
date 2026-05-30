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
  ezagent_domain_chat) — chat plugin registers `agent`/`session`/`user`
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

  defp workspace_name(%URI{scheme: "workspace", host: name}) when is_binary(name), do: name

  defp workspace_name(%URI{} = uri) do
    # Fall back to last path segment for any tolerated future shape.
    case URI.to_string(uri) do
      "workspace://" <> rest -> rest |> String.split("/") |> List.first()
      _ -> raise ArgumentError, "not a workspace:// URI: #{inspect(uri)}"
    end
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
    case class_module.instantiate(tmpl_name, tmpl_data, workspace_uri) do
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
      %URI{host: ws} when is_binary(ws) -> ws == workspace_uri.host
      :any -> true
      _ -> false
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
    try do
      Workspace.Store.list_all() |> Enum.map(&load_one/1)
    rescue
      e in [DBConnection.ConnectionError, DBConnection.OwnershipError] ->
        Logger.warning(
          "Workspace.Loader.load_all: DB unavailable at boot (#{inspect(e.__struct__)}); " <>
            "skipping — plugin re-runs or per-test setup will pick up Workspaces"
        )

        []
    end
  end

  defp load_one(%{name: name} = decoded) do
    case Workspace.spawn_workspace(name, %{
           members: decoded.members,
           session_templates: decoded.session_templates,
           routing_rules: decoded.routing_rules
         }) do
      {:ok, _pid} ->
        children = instantiate_via_dispatch(decoded.uri)
        results = Enum.map(children, &spawn_child(&1, decoded.uri))
        {name, results}

      {:error, {:already_started, _pid}} ->
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

    case Router.dispatch(%Cmd{
           target: target,
           action: :instantiate,
           args: %{},
           # SPEC caps-cleanup-v1 §4.4 — Workspace Loader re-spawn at
           # boot runs under `system://workspace-loader` (closed Catalog).
           ctx: %{
             mode: :call,
             caller: Ezagent.SystemPrincipal.uri("workspace-loader"),
             caps: Ezagent.SystemPrincipal.caps("system://workspace-loader"),
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, %{children: children}} ->
        children

      other ->
        Logger.warning(
          "Workspace.Loader: instantiate dispatch returned unexpected: #{inspect(other)}"
        )

        []
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
    case class_module.instantiate(tmpl_name, tmpl_data, workspace_uri) do
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
