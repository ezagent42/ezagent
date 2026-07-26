defmodule EzagentDomainInstanceMessage.AgentModuleResolver do
  @moduledoc """
  Resolve an `entity://agent/...` URI to its Kind module
  (`Ezagent.Entity.Agent` / `CurlAgent` / `PyAgent`, or a plugin-declared
  flavor's kind).

  Extracted verbatim from `EzagentDomainInstanceMessage.Application`
  (#25 Phase-3, PR-3P) — the boot module's `spawn_agent/1` spawn-fn
  callback delegates here. Three ordered resolver steps, each tolerant
  of boot-time DB unavailability (rescue → fall through):

    1. `KindSnapshot.kind_type` (fast path)
    2. workspace session-template `class`
    3. stored flavor → `Ezagent.AgentFlavorRegistry`

  `spawn_agent/1` keeps the resolution and Kind spawn operation in this
  cohesive boundary so the OTP Application only registers the callback.
  """

  @doc """
  Resolve `uri` to `{:ok, kind_module}`, `{:error, reason}` (a real
  resolution failure), or `:error` (nothing matched any step).
  """
  @spec lookup_kind_module_for_agent(URI.t()) ::
          {:ok, module()} | {:error, term()} | :error
  def lookup_kind_module_for_agent(%URI{} = uri) do
    uri_str = URI.to_string(uri)

    with :error <- lookup_via_snapshot(uri_str),
         :error <- lookup_via_workspace_template(uri_str),
         :error <- lookup_via_stored_flavor(uri) do
      :error
    else
      {:ok, _mod} = ok -> ok
      {:error, _reason} = err -> err
    end
  end

  @doc "Resolve the Kind for `uri` and spawn it through the Kind lifecycle."
  @spec spawn_agent(URI.t()) :: {:ok, URI.t()} | {:error, term()}
  def spawn_agent(%URI{} = uri) do
    case lookup_kind_module_for_agent(uri) do
      {:ok, kind_module} ->
        # derivation-edge: rehydration-only resolver for an existing agent URI
        # V5 A1c — the public contract carries the agent URI; the Kind pid
        # stays behind the actor-app seam (Kind.spawn / KindRegistry).
        case Ezagent.Kind.spawn(kind_module, %{uri: uri}) do
          {:ok, _pid} -> {:ok, uri}
          {:error, _} = err -> err
        end

      {:error, reason} ->
        {:error, reason}

      :error ->
        {:error, {:no_kind_module_for_agent, URI.to_string(uri)}}
    end
  end

  defp lookup_via_snapshot(uri_str) do
    case Ezagent.Ecto.KindSnapshot.get(uri_str) do
      %Ezagent.Ecto.KindSnapshot{kind_type: kt} when is_binary(kt) and kt != "" ->
        case kind_module_from_kind_type(kt) do
          nil -> :error
          mod -> {:ok, mod}
        end

      _ ->
        :error
    end
  rescue
    # DB unavailable at boot — fall through to next resolver step. The
    # snapshot is an optimization; missing it just means we hit step 2/3.
    _ -> :error
  end

  defp lookup_via_workspace_template(uri_str) do
    if Code.ensure_loaded?(Ezagent.Workspace.Store) do
      Ezagent.Workspace.Store.list_all()
      |> Enum.find_value(fn ws ->
        ws.session_templates
        |> Map.values()
        |> Enum.find_value(fn tmpl ->
          case tmpl do
            %{"agent_uri" => ^uri_str, "class" => class} when is_binary(class) ->
              kind_module_from_class(class)

            %{"agent_uri" => ^uri_str, class: class} when is_binary(class) ->
              kind_module_from_class(class)

            _ ->
              nil
          end
        end)
      end)
      |> case do
        nil -> :error
        mod -> {:ok, mod}
      end
    else
      :error
    end
  rescue
    # Same boot-time DB unavailability tolerance as step 1.
    _ -> :error
  end

  defp lookup_via_stored_flavor(%URI{} = uri) do
    case Ezagent.UriQuery.resolve(:flavor, uri) do
      {:ok, flavor} when is_binary(flavor) and flavor != "" ->
        case kind_module_from_flavor(flavor) do
          nil -> :error
          mod -> {:ok, mod}
        end

      :none ->
        :error

      {:ok, other} ->
        {:error, {:invalid_agent_flavor, other}}

      {:error, reason} ->
        {:error, {:flavor_resolver_failed, reason}}
    end
  end

  # KindSnapshot.kind_type is `to_string(kind_module.type_name())` per
  # the Snapshot writer (kind/snapshot.ex). Map back to the Kind module.
  #
  # PR-6+7 (curl-as-flavor) — the `"curl_agent"` → standalone-curl-Kind branch
  # is DELETED with that Kind (forward-only, no rollback alias — Allen).
  # Every pre-fold `curl_agent` snapshot row is rewritten to `kind_type "agent"`
  # by `mix ezagent.curl.migrate` BEFORE a new-code node serves it, so it
  # resolves here as `Entity.Agent` (the unified Kind) with a `curl` flavor
  # slice. With no back-compat the cutover is total — an un-migrated
  # `curl_agent` row does not exist by the time new code serves rows (Allen
  # 2026-06-13), so `"curl_agent"` is simply a dead kind_type that falls through
  # to the unknown-kind `nil` like any other.
  defp kind_module_from_kind_type("agent"), do: Ezagent.Entity.Agent

  # Fall back to the AgentFlavorRegistry: a bespoke agent Kind (e.g. a hello
  # builder, kind_type "hello_builder") registers a matching flavor via its
  # plugin's `agent_flavors/0`, so its persisted snapshot kind_type resolves to
  # the Kind module on REVIVAL — without hardcoding the plugin module here, and
  # for already-existing agents that carry no stored `?flavor=` query. An unknown
  # kind_type (no matching flavor) still resolves to nil, unchanged.
  defp kind_module_from_kind_type(kt) when is_binary(kt), do: kind_module_from_flavor(kt)

  # Template Class names (e.g. "cc.agent" registered by the cc plugin;
  # "curl.agent" by ezagent_plugin_curl_agent; "py.agent" by
  # ezagent_plugin_py) map to Kind modules.
  #
  # Plugin authoring contract SPEC §6.3 + codex MEDIUM-5: the
  # flavor→{kind, template_class} mapping is no longer hardcoded here —
  # each agent-flavor plugin declares `agent_flavors/0` and
  # `Ezagent.Plugin.boot/1` registers it in
  # `Ezagent.AgentFlavorRegistry`. This resolver consults that registry
  # instead. Adding a 6th agent-flavor plugin now touches only that
  # plugin's own dir. The decl carries the `template_class` module, so
  # a Template Class NAME (e.g. "cc.agent") is matched against
  # `template_class.template_name/0`.
  defp kind_module_from_class(class) when is_binary(class) do
    Enum.find_value(Ezagent.AgentFlavorRegistry.list_all(), fn
      {_flavor, %{kind: kind, template_class: tc}} ->
        if class_name(tc) == class, do: kind, else: nil
    end)
  end

  defp kind_module_from_class(_), do: nil

  defp class_name(template_class) do
    template_class.template_name()
  rescue
    # A declared template_class module that does not (yet) export
    # `template_name/0` — tolerate it (the snapshot / stored-flavor
    # resolver steps still cover the spawn).
    _ -> nil
  end

  # Plugin authoring contract SPEC §6.3 + codex MEDIUM-5: real agent
  # flavors (cc / curl / py) resolve via `Ezagent.AgentFlavorRegistry`
  # — populated by each plugin's `agent_flavors/0` declaration through
  # `Ezagent.Plugin.boot/1`. The registry is published before this
  # resolver runs at dispatch time (the plugin apps boot, and
  # `boot/1`'s Phase 2 registers the flavor, well before any
  # `entity://agent/...` dispatch); a not-yet-registered flavor returns
  # `:error` from `lookup/1` and this fn returns `nil` — the caller
  # then yields `{:error, {:no_kind_module_for_agent, _}}` rather than
  # crashing (graceful boot-ordering tolerance).
  defp kind_module_from_flavor(flavor) when is_binary(flavor) do
    case Ezagent.AgentFlavorRegistry.lookup(flavor) do
      {:ok, %{kind: kind}} -> kind
      :error -> nil
    end
  end

  defp kind_module_from_flavor(_), do: nil
end
