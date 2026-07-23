defmodule Ezagent.World.MarketActions do
  @moduledoc """
  Socket-side dispatch handlers for the world socialware market surface
  (`/market`, PR-5 §15).

  This is a THIN product surface over the existing socialware backend — it adds
  NO new authz and NO second catalog/visibility implementation:

    * browse rows come from `WorkspacePluginData.socialware_rows/1`
      (`DefinitionRegistry.list/1` — the only `visible_to_workspace?`-scoped
      path), so a private foreign definition can never leak onto the page;
    * install reuses the sessions-page `ConversationActions.create_session/6`
      REVISION-PINNED path (`SocialwareInstall.prepare_create_template/6` →
      `DefinitionRegistry.resolve_installable_revision/3`), never a bare-name
      resolve;
    * publish (上架) routes through `DefinitionEditor.save_authored_definition/4`
      so the EXISTING #165 `authorize_public_scope_write` admin gate fires on
      the caller's REAL actor URI + REAL caps (`PresenterCaps.load/1`);
    * retract (下架) / restore (re-list) route through the GATED
      `Ezagent.ConfigGovernance.Socialware.retract/2` / `restore/2` — never the
      ungated `DefinitionRegistry.set_retracted/4` primitive.

  A denied publish/retract surfaces the gate's `{:error, ...}` LOUD in the UI
  (`market_error` + an error dispatch status), never a silent no-op.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Ezagent.Socialware.{Definition, DefinitionEditor, DefinitionRegistry}
  alias Ezagent.World.{ConversationActions, WorkspacePluginData}

  @doc "Route a market world action to its handler."
  @spec handle_dispatch(Phoenix.LiveView.Socket.t(), String.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_dispatch(
        socket,
        "market.install",
        %{"name" => name, "config_id" => config_id} = args
      )
      when is_binary(name) and is_binary(config_id) and config_id != "" do
    short_name =
      case Map.get(args, "short_name") do
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> name
            trimmed -> trimmed
          end

        _ ->
          name
      end

    revision = %{config_id: config_id, content_hash: Map.get(args, "content_hash")}

    # The same revision-pinned install the sessions page runs: scope + retract
    # re-checked inside `resolve_installable_revision/3`, exact `config_id` /
    # `content_hash` pinned into the local install template.
    ConversationActions.create_session(socket, short_name, "default", name, revision)
  end

  def handle_dispatch(socket, "market.install", _args) do
    # HARD RULE (spec §15.3): a market install pins the exact revision the card
    # displayed. A bare-name install could silently grab a same-named LOCAL def,
    # so it is rejected outright rather than falling back to the legacy path.
    {:noreply, assign(socket, :last_dispatch_status, "error:market_install_requires_revision")}
  end

  def handle_dispatch(socket, "market.publish", %{"name" => name}) when is_binary(name) do
    publish(socket, name)
  end

  def handle_dispatch(socket, "market.retract", %{"name" => name}) when is_binary(name) do
    set_retracted(socket, name, true)
  end

  def handle_dispatch(socket, "market.restore", %{"name" => name}) when is_binary(name) do
    set_retracted(socket, name, false)
  end

  def handle_dispatch(socket, _action, _args) do
    {:noreply, assign(socket, :last_dispatch_status, "error:unsupported_action")}
  end

  # 上架 — re-save the caller's OWN definition with `scope: :public` through the
  # authoring boundary so the #165 public-scope admin gate fires. SECURITY: the
  # gate keys on BOTH the actor URI and the caps, so this threads the caller's
  # REAL actor (`current_entity_uri`) and REAL caps (`PresenterCaps.load/1`) —
  # never a system/service actor (which would bypass the gate caps-independently)
  # and never hardcoded admin caps.
  defp publish(socket, name) do
    workspace_uri = socket.assigns.current_workspace_uri
    caller = socket.assigns.current_entity_uri
    caps = Ezagent.World.PresenterCaps.load(socket)

    with %URI{scheme: "workspace"} <- workspace_uri,
         {:ok, %Definition{} = definition} <- own_definition(workspace_uri, name),
         {:ok, _saved, _object} <-
           DefinitionEditor.save_authored_definition(
             %{
               definition
               | visibility_policy: Map.put(definition.visibility_policy, :scope, :public)
             },
             workspace_uri,
             caller,
             caps: caps
           ) do
      refresh_market(socket, "published:#{name}", nil, "ok")
    else
      {:error, reason} ->
        refresh_market(
          socket,
          nil,
          "publish_failed:#{reason(reason)}",
          "error:market_publish_failed"
        )

      _other ->
        refresh_market(
          socket,
          nil,
          "publish_failed:invalid_workspace",
          "error:market_publish_failed"
        )
    end
  end

  # A publish only ever targets the caller's OWN workspace definition — the
  # bare-name `lookup/2` falls back to system/public objects, so the resolved
  # object's owning workspace must be re-checked or a same-named foreign def
  # would be re-published under the caller's hand.
  defp own_definition(%URI{} = workspace_uri, name) do
    case DefinitionRegistry.lookup(workspace_uri, name) do
      {:ok, %Definition{} = definition, %{workspace_uri: object_workspace}} ->
        if object_workspace == URI.to_string(workspace_uri) do
          {:ok, definition}
        else
          {:error, :socialware_publish_not_owner}
        end

      :error ->
        {:error, {:unknown_socialware_definition, name}}
    end
  end

  # 下架 / re-list — the GATED governance path (manage + admin authz inside
  # `ConfigGovernance.Socialware`), threading the caller's REAL caps. NEVER the
  # ungated `DefinitionRegistry.set_retracted/4` primitive (spec §15.2/§15.3).
  defp set_retracted(socket, name, retracted?) do
    workspace_uri = socket.assigns.current_workspace_uri
    caller = socket.assigns.current_entity_uri
    caps = Ezagent.World.PresenterCaps.load(socket)
    # #195 authz: the world presenter's authenticated identity is the holder.
    ctx = %{
      caller: caller,
      authenticated_principal: caller,
      workspace_uri: workspace_uri,
      caps: caps
    }

    result =
      if retracted? do
        Ezagent.ConfigGovernance.Socialware.retract(name, ctx)
      else
        Ezagent.ConfigGovernance.Socialware.restore(name, ctx)
      end

    action = if retracted?, do: "retract", else: "restore"

    case result do
      {:ok, _} ->
        refresh_market(socket, "#{action}ed:#{name}", nil, "ok")

      {:error, reason} ->
        refresh_market(
          socket,
          nil,
          "#{action}_failed:#{reason(reason)}",
          "error:market_#{action}_failed"
        )
    end
  end

  defp refresh_market(socket, notice, error, status) do
    updates = %{
      "socialwares" => WorkspacePluginData.socialware_rows(socket.assigns.current_workspace_uri),
      "market_notice" => notice,
      "market_error" => error
    }

    state = Map.merge(socket.assigns.world_state || %{}, updates)

    {:noreply,
     socket
     |> assign(:world_state, state)
     |> assign(:world_state_json, Jason.encode!(state))
     |> assign(:last_dispatch_status, status)
     |> push_event("world:state", updates)}
  end

  defp reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason(reason), do: inspect(reason)
end
