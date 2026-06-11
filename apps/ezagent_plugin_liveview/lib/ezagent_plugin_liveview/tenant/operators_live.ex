defmodule EzagentPluginLiveview.Tenant.OperatorsLive do
  @moduledoc """
  T2A.2 — Operators LiveView at `/autoservice/tenant/:tid/operators`.

  Lists workspace operators, with add/disable functionality.
  Uses `Ezagent.Users.list_in_workspace/1` to list users and
  `Ezagent.Users.create/3` to add new operators.

  Disable is a stub (the Users module does not yet expose a disable
  function) — the button is rendered but shows a "not yet available"
  flash until the API lands.
  """
  use Phoenix.LiveView
  use Gettext, backend: EzagentPluginLiveview.Gettext
  use EzagentDomainUi.Components
  import Phoenix.Component

  @impl true
  def mount(%{"tid" => tid}, _session, socket) do
    workspace_uri = build_workspace_uri(tid)

    {:ok,
     socket
     |> assign(:page_title, gettext("Operators: %{tid}", tid: tid))
     |> assign(:workspace_uri, workspace_uri)
     |> assign(:tid, tid)
     |> assign(:operators, list_operators(workspace_uri))
     |> assign(:new_form, to_form(%{"uri" => "", "password" => ""}, as: "new_operator"))
     |> assign(:error, nil)
     |> assign(:flash_info, nil)}
  end

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Operators"))
     |> assign(:workspace_uri, Map.get(socket.assigns, :current_workspace_uri))
     |> assign(:tid, nil)
     |> assign(:operators, [])
     |> assign(:new_form, to_form(%{"uri" => "", "password" => ""}, as: "new_operator"))
     |> assign(:error, nil)
     |> assign(:flash_info, gettext("No tenant ID provided."))}
  end

  defp build_workspace_uri(tid) do
    try do
      Ezagent.URI.new!("workspace://#{tid}")
    rescue
      _ -> nil
    end
  end

  defp list_operators(workspace_uri) do
    if workspace_uri && Code.ensure_loaded?(Ezagent.Users) do
      Ezagent.Users.list_in_workspace(workspace_uri)
      |> Enum.map(fn user ->
        %{
          uri: user.uri,
          uri_str: URI.to_string(user.uri),
          handle: user_handle(user.uri),
          caps: length(user.caps || [])
        }
      end)
    else
      []
    end
  rescue
    _ -> []
  end

  defp user_handle(uri) do
    case Ezagent.URI.name(uri) do
      {:ok, name} -> name
      :error -> "?"
    end
  rescue
    _ -> "?"
  end

  @impl true
  def handle_event("add_operator", %{"new_operator" => %{"uri" => uri_str, "password" => pw}}, socket) do
    uri_str = String.trim(uri_str)

    if uri_str == "" do
      {:noreply, assign(socket, :error, gettext("Operator URI is required."))}
    else
      case create_operator(uri_str, pw, socket.assigns.workspace_uri) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> assign(:operators, list_operators(socket.assigns.workspace_uri))
           |> assign(:new_form, to_form(%{"uri" => "", "password" => ""}, as: "new_operator"))
           |> assign(:error, nil)
           |> assign(:flash_info, gettext("Operator added."))}

        {:error, reason} ->
          {:noreply, assign(socket, :error, inspect(reason))}
      end
    end
  end

  def handle_event("disable_operator", %{"uri" => _uri_str}, socket) do
    {:noreply,
     assign(socket, :flash_info, gettext("Disable not yet implemented in this version."))}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:operators, list_operators(socket.assigns.workspace_uri))
     |> assign(:error, nil)}
  end

  defp create_operator(uri_str, password, workspace_uri) do
    mod = Ezagent.Users

    if Code.ensure_loaded?(mod) and function_exported?(mod, :create, 3) do
      with {:ok, user_uri} <- parse_user_uri(uri_str, workspace_uri),
           pw <- if(password != "", do: password, else: nil),
           caps <- [] do
        apply(mod, :create, [user_uri, pw, caps])
      end
    else
      {:error, "Ezagent.Users not available"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp parse_user_uri(uri_str, _workspace_uri) when is_binary(uri_str) do
    try do
      uri = Ezagent.URI.new!(uri_str)

      if Ezagent.URI.scheme?(uri, :entity) and Ezagent.URI.type?(uri, :user) do
        {:ok, uri}
      else
        {:error, "expected entity://user URI, got: #{uri_str}"}
      end
    rescue
      e in ArgumentError -> {:error, Exception.message(e)}
    end
  end

  defp parse_user_uri(_, _), do: {:error, "invalid URI"}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-6 py-6 text-zinc-900 dark:text-zinc-100 max-w-3xl">
      <div class="flex items-center justify-between mb-4">
        <.page_header title={@page_title}>
          <:subtitle>
            {gettext("Manage operators for this tenant workspace.")}
          </:subtitle>
        </.page_header>
        <a
          href={"/autoservice/tenant/#{@tid}"}
          class="text-xs text-zinc-500 hover:text-zinc-700"
        >
          {gettext("Back to Dashboard")} ←
        </a>
      </div>

      <p :if={@flash_info} class="mb-4 text-sm text-amber-600 dark:text-amber-400 bg-amber-50 dark:bg-amber-950 p-3 rounded-md">
        {@flash_info}
      </p>

      <p :if={@error} class="mb-4 text-sm text-rose-600 dark:text-rose-400 bg-rose-50 dark:bg-rose-950 p-3 rounded-md">
        {@error}
      </p>

      <%!-- Add Operator Form --%>
      <.card id="add-operator" class="mb-4">
        <:header>{gettext("+ Add Operator")}</:header>
        <.form for={@new_form} phx-submit="add_operator">
          <div class="flex gap-2 items-end">
            <div class="flex-1">
              <label for="new_operator_uri" class="block text-xs font-medium mb-1 text-zinc-500">
                {gettext("Operator URI")}
              </label>
              <input
                type="text"
                name="new_operator[uri]"
                id="new_operator_uri"
                placeholder="entity://user/<tid>/<handle>"
                class="w-full px-3 py-1.5 text-sm border border-zinc-300 dark:border-zinc-700 rounded-md bg-white dark:bg-zinc-900 focus:outline-none focus:ring-2 focus:ring-zinc-500"
              />
            </div>
            <div class="w-40">
              <label for="new_operator_password" class="block text-xs font-medium mb-1 text-zinc-500">
                {gettext("Password (optional)")}
              </label>
              <input
                type="password"
                name="new_operator[password]"
                id="new_operator_password"
                class="w-full px-3 py-1.5 text-sm border border-zinc-300 dark:border-zinc-700 rounded-md bg-white dark:bg-zinc-900 focus:outline-none focus:ring-2 focus:ring-zinc-500"
              />
            </div>
            <button
              type="submit"
              class="px-4 py-1.5 text-sm bg-zinc-800 text-white rounded-md hover:bg-zinc-700"
            >
              {gettext("Add")}
            </button>
          </div>
        </.form>
      </.card>

      <%!-- Operator List --%>
      <.card>
        <:header>
          <div class="flex items-center justify-between">
            <span>{gettext("Operators")}</span>
            <button phx-click="refresh" class="text-xs underline text-zinc-500 hover:text-zinc-700">
              {gettext("Refresh")}
            </button>
          </div>
        </:header>

        <p :if={@operators == []} class="text-sm text-zinc-500 italic p-4">
          {gettext("No operators in this workspace. Add one above.")}
        </p>

        <table :if={@operators != []} class="w-full text-sm">
          <thead class="bg-zinc-50 dark:bg-zinc-950 border-b border-zinc-200 dark:border-zinc-800">
            <tr class="text-left text-xs uppercase tracking-wide text-zinc-500">
              <th class="px-4 py-2">{gettext("Handle")}</th>
              <th class="py-2">{gettext("URI")}</th>
              <th class="py-2">{gettext("Caps")}</th>
              <th class="py-2">{gettext("Status")}</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={op <- @operators}
              class="border-b border-zinc-100 dark:border-zinc-900 last:border-0"
            >
              <td class="px-4 py-2 font-medium">{op.handle}</td>
              <td class="py-2 font-mono text-xs text-zinc-500">{op.uri_str}</td>
              <td class="py-2 tabular-nums">{op.caps}</td>
              <td class="py-2">
                <.badge variant="success">{gettext("active")}</.badge>
              </td>
              <td class="py-2 pr-4 text-right">
                <button
                  phx-click="disable_operator"
                  phx-value-uri={op.uri_str}
                  class="text-xs text-rose-600 dark:text-rose-400 hover:text-rose-800 dark:hover:text-rose-300"
                >
                  {gettext("disable")}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </.card>
    </div>
    """
  end
end
