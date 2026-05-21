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

  alias Ezagent.{Invocation, SpawnRegistry, TemplateRegistry, Workspace}

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
         class_name when is_binary(class_name) <- extract_class_name(tmpl_data) ||
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
    case class_module.instantiate(tmpl_name, tmpl_data, workspace_uri) do
      {:ok, uris} when is_list(uris) ->
        Enum.each(uris, fn uri ->
          Ezagent.WorkspaceRegistry.bind(uri, workspace_uri)
        end)

        {:ok, uris}

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

  defp tmpl_data_from_template_name(workspace_uri, tmpl_name) do
    case Workspace.Store.get_by_name(workspace_name(workspace_uri)) do
      %{session_templates: tmpls} -> Map.get(tmpls, tmpl_name, %{})
      _ -> %{}
    end
  end

  defp instantiate_idempotent_uris(%{"agent_uri" => uri_str}) when is_binary(uri_str),
    do: [URI.parse(uri_str)]

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
    target = URI.parse("#{URI.to_string(workspace_uri)}?action=workspace.instantiate")

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: %{
             caller: Ezagent.Entity.User.admin_uri(),
             caps: Ezagent.Entity.User.admin_caps(),
             reply: {:caller_inbox, self()}
           }
         }) do
      {:ok, %{children: children}} -> children
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
        Logger.warning(
          "Workspace.Loader: spawn #{URI.to_string(uri)} failed: #{inspect(reason)}"
        )

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
      {:ok, uris} when is_list(uris) ->
        # Phase 7 PR 31 (IMPL-7-1): bind every session URI the
        # Template Class spawned to this workspace, so production
        # dispatch via Ezagent.Behavior.Chat.invoke(:send) can resolve
        # workspace_uri for the Resolver call (chat.ex:116).
        # Non-session URIs are bound too — harmless, and avoids
        # special-casing scheme detection in this fan-out path.
        Enum.each(uris, fn uri ->
          Ezagent.WorkspaceRegistry.bind(uri, workspace_uri)
        end)

        {tmpl_name, {:ok, uris}}

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
