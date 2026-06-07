defmodule EzagentPluginLiveview.Admin.RoutingRules do
  @moduledoc false

  import Phoenix.Component

  use Gettext, backend: EzagentPluginLiveview.Gettext

  alias EzagentPluginLiveview.Admin.SessionContext

  def toggle(socket, %{"id" => id_str, "enabled" => enabled_str, "table" => table_str}) do
    with {id, ""} <- Integer.parse(id_str),
         {:ok, table} <- SessionContext.safe_table_atom(table_str) do
      action = if enabled_str == "true", do: :disable_rule, else: :enable_rule

      case SessionContext.dispatch_session_routing(socket, action, %{id: id, table: table}) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(
             :session_routing_rules,
             SessionContext.list_session_scoped_rules(socket.assigns.current_session_uri)
           )
           |> assign(:flash_error, nil)}

        error ->
          routing_error(socket, gettext("Toggle"), error)
      end
    else
      _ ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext("Bad routing rule id or table: %{id}", id: id_str)
         )}
    end
  end

  def add_session(socket, %{"rule" => params}) do
    session_uri = socket.assigns.current_session_uri

    with {:ok, leaf_matcher} <- SessionContext.build_session_form_matcher(params),
         receivers when is_list(receivers) and receivers != [] <-
           SessionContext.parse_session_receivers(Map.get(params, "receivers", "")),
         :ok <- SessionContext.revalidate_session_matcher_arg(socket, params),
         :ok <- SessionContext.revalidate_session_receivers(socket, receivers),
         matcher = SessionContext.wrap_in_session(leaf_matcher, session_uri),
         {:ok, _} <-
           SessionContext.dispatch_session_routing(socket, :add_rule, %{
             table: EzagentDomainInstanceMessage.Routing.MentionRouting,
             matcher_json: Ezagent.Routing.Matcher.to_json(matcher),
             receivers: receivers
           }) do
      {:noreply,
       socket
       |> assign(:session_routing_rules, SessionContext.list_session_scoped_rules(session_uri))
       |> assign(:flash_error, nil)}
    else
      {:error, {:invalid_uri, bad}} ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext(
             "Rejected URI %{uri} — not a valid in-workspace entity/session.",
             uri: inspect(bad)
           )
         )}

      [] ->
        {:noreply,
         assign(socket, :flash_error, gettext("At least one receiver URI is required."))}

      error ->
        routing_error(socket, gettext("Add rule"), error)
    end
  end

  def handle_event("routing_rule_toggle", params, socket), do: toggle(socket, params)
  def handle_event("routing_rule_add_session", params, socket), do: add_session(socket, params)

  defp routing_error(socket, _action, {:error, :unauthorized}) do
    {:noreply,
     assign(
       socket,
       :flash_error,
       gettext("Unauthorized — need routing cap on this session.")
     )}
  end

  defp routing_error(socket, _action, {:error, :cross_workspace_denied}) do
    {:noreply,
     assign(
       socket,
       :flash_error,
       gettext("Cross-workspace denied — this session lives in a different workspace.")
     )}
  end

  defp routing_error(socket, action, {:error, reason}) do
    {:noreply,
     assign(
       socket,
       :flash_error,
       gettext("%{action} failed: %{reason}", action: action, reason: inspect(reason))
     )}
  end
end
