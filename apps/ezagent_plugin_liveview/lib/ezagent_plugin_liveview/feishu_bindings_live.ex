defmodule EzagentPluginLiveview.FeishuBindingsLive do
  @moduledoc """
  /plugins/feishu/bindings — Feishu user-identity binding admin LV.

  ## PR-EM-6 reshape (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md` §9)

  Pre-PR-EM-6 this LV had TWO sections: user bindings (open_id ↔
  user_uri) AND session bindings (chat_id ↔ session_uri, the one-off
  `EzagentPluginFeishu.SessionBinding` table). PR-EM-6 retires the
  session-binding side: chat-to-session mirroring is now a generic
  ExternalMirror Domain concern managed via:

  - `mix ezagent.external_mirror.bind <session_uri> feishu <chat_id>`
  - `/admin/sessions/:id/external_mirror` (the generic admin LV from
    PR-EM-4)

  This LV now manages ONLY user identity bindings (open_id ↔
  user_uri + the BindingPolicy cap grant). The session-binding form
  + listing + handle_events were deleted; this is the last LV in the
  Feishu plugin that has any state, by design (P1 plugin isolation).

  ## URI fields use `uri_picker`

  `user_uri` is a `EzagentDomainUi.Primitives.uri_picker/1` `:single`
  combobox over entities; `open_id` is a Feishu identifier (not a
  URI) so it stays a text input. `allow_freetext: true` lets the
  operator bind a user before its entity Kind is live; the shared
  `Ezagent.UI.UriOptions.valid_for?/4` revalidates every submit.
  """

  use Phoenix.LiveView
  # i18n — runtime backend reference; no compile-time dep on :ezagent_web.
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.WorkspaceShell
  alias EzagentPluginLiveview.AppShell
  alias Ezagent.UI.UriOptions
  use EzagentDomainUi.Components
  use EzagentDomainUi.Primitives
  import Phoenix.Component

  alias EzagentPluginFeishu.{BindingPolicy, UserBinding}

  @impl true
  def mount(_params, session, socket) do
    admin_uri =
      case Map.get(session || %{}, "current_entity_uri") do
        nil -> "entity://user/system/admin"
        s -> s
      end

    caller_uri = socket.assigns[:current_entity_uri]
    workspace_uri = socket.assigns[:current_workspace_uri]

    {:ok,
     socket
     |> assign(:admin_uri, admin_uri)
     |> assign(:bindings, UserBinding.list_all())
     |> assign(:flash_info, nil)
     |> assign(:flash_error, nil)
     |> assign(:entity_options, UriOptions.entities(caller_uri, workspace_uri))
     |> assign(:bind_form, to_form(%{"open_id" => "", "user_uri" => ""}, as: "bind"))}
  end

  @impl true
  def handle_event("bind", %{"bind" => %{"open_id" => open_id, "user_uri" => user_uri}}, socket) do
    open_id = String.trim(open_id)
    user_uri = String.trim(user_uri)

    caller_uri = socket.assigns[:current_entity_uri]
    workspace_uri = socket.assigns[:current_workspace_uri]

    cond do
      open_id == "" or user_uri == "" ->
        {:noreply, assign(socket, :flash_error, gettext("open_id and user_uri are required"))}

      not UriOptions.valid_for?(caller_uri, workspace_uri, user_uri, [:entity]) ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext(
             "Rejected %{uri} — must be an entity URI in this workspace. Pick from the list.",
             uri: inspect(user_uri)
           )
         )}

      true ->
        case UserBinding.bind(open_id, user_uri, socket.assigns.admin_uri) do
          {:ok, _} ->
            _ = BindingPolicy.apply(user_uri, socket.assigns.admin_uri)

            {:noreply,
             socket
             |> assign(:bindings, UserBinding.list_all())
             |> assign(
               :flash_info,
               gettext("Bound %{from} → %{to}", from: open_id, to: user_uri)
             )
             |> assign(:flash_error, nil)
             |> assign(:bind_form, to_form(%{"open_id" => "", "user_uri" => ""}, as: "bind"))}

          {:error, reason} ->
            {:noreply,
             assign(
               socket,
               :flash_error,
               gettext("bind failed: %{reason}", reason: inspect(reason))
             )}
        end
    end
  end

  def handle_event("unbind", %{"open-id" => open_id}, socket) do
    case UserBinding.unbind(open_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:bindings, UserBinding.list_all())
         |> assign(:flash_info, gettext("Unbound %{id}", id: open_id))
         |> assign(:flash_error, nil)}

      {:error, :not_found} ->
        {:noreply, assign(socket, :flash_error, gettext("no binding for %{id}", id: open_id))}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(
          Map.get(assigns, :current_entity_uri) || URI.parse("entity://user/system/admin")
        )
      end)

    ~H"""
    <AppShell.app_shell
      perspective={:workspace}
      current_entity_uri={@current_entity_uri_str}
      current_workspace_uri={@current_workspace_uri}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      workspaces={@workspaces}
      cmdk_nav_routes={@cmdk_nav_routes}
    >
      <:body>
        <WorkspaceShell.workspace_shell
          current_entity_uri={@current_entity_uri_str}
          current_path="/plugins/feishu/bindings"
          status={%{agents_alive: 0, bridges: 0, debug_events: 0, version: "dev"}}
        >
          <:main_window>
            <div class="flex-1 overflow-auto px-6 py-6 text-zinc-900 dark:text-zinc-100">
              <.page_header title={gettext("Feishu user bindings")}>
                <:subtitle>
                  {gettext(
                    "Bind Feishu open_id ↔ local user URI (grants chat caps via BindingPolicy)."
                  )}
                  <a
                    href="/plugins"
                    class="text-zinc-600 dark:text-zinc-400 underline hover:text-zinc-900 dark:hover:text-zinc-100 ml-1"
                  >
                    ← {gettext("Plugins")}
                  </a>
                </:subtitle>
              </.page_header>

              <p :if={@flash_info} class="text-emerald-700 dark:text-emerald-300 text-sm mb-3">
                {@flash_info}
              </p>
              <p :if={@flash_error} class="text-red-700 dark:text-red-300 text-sm mb-3">
                {@flash_error}
              </p>

              <.card class="mb-6">
                <:header>{gettext("Bind open_id ↔ user URI")}</:header>
                <.form for={@bind_form} phx-submit="bind" class="grid grid-cols-2 gap-2 items-start">
                  <label class="text-xs text-zinc-700 dark:text-zinc-300">
                    {gettext("Feishu open_id")}
                    <input
                      type="text"
                      name="bind[open_id]"
                      placeholder="ou_6b11faf8e9..."
                      class="block w-full px-2 py-1 mt-1 text-sm border border-zinc-300 dark:border-zinc-700 rounded-md font-mono bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
                    />
                  </label>
                  <.uri_picker
                    name="bind[user_uri]"
                    mode={:single}
                    kinds={[:entity]}
                    options={@entity_options}
                    allow_freetext={true}
                    label={gettext("local user URI")}
                    placeholder={gettext("pick the local entity to bind")}
                  />
                  <div class="col-span-2 flex justify-end">
                    <.button type="submit" variant="primary" size="sm">
                      {gettext("Bind + grant cap")}
                    </.button>
                  </div>
                </.form>
              </.card>

              <.card class="mb-8">
                <:header>
                  {gettext("Current user bindings (%{count})", count: length(@bindings))}
                </:header>
                <p :if={@bindings == []} class="text-zinc-500 italic text-sm">
                  {gettext(
                    "No bindings yet. Unbound Feishu users see the bot react with THUMBSDOWN — bind them above to enable chat."
                  )}
                </p>
                <table :if={@bindings != []} class="w-full text-sm">
                  <thead class="bg-zinc-50 dark:bg-zinc-950 border-b border-zinc-200 dark:border-zinc-800">
                    <tr class="text-left text-xs uppercase tracking-wide text-zinc-500">
                      <th class="px-2 py-2">open_id</th>
                      <th class="py-2">user_uri</th>
                      <th class="py-2">bound_by</th>
                      <th class="py-2">{gettext("when")}</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={b <- @bindings}
                      class="border-b border-zinc-100 dark:border-zinc-900 last:border-0"
                    >
                      <td class="px-2 py-2 font-mono text-xs">{b.open_id}</td>
                      <td class="py-2 font-mono text-xs">{b.user_uri}</td>
                      <td class="py-2 font-mono text-xs text-zinc-500">{b.bound_by}</td>
                      <td class="py-2 text-xs text-zinc-500">{DateTime.to_iso8601(b.bound_at)}</td>
                      <td class="py-2 text-right pr-2">
                        <.button
                          variant="danger"
                          size="sm"
                          phx-click="unbind"
                          phx-value-open-id={b.open_id}
                        >
                          {gettext("unbind")}
                        </.button>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </.card>

              <.card>
                <:header>{gettext("Session bindings → moved")}</:header>
                <p class="text-sm text-zinc-700 dark:text-zinc-300">
                  {gettext(
                    "PR-EM-6 moved chat ↔ session bindings to the generic ExternalMirror admin surface. Manage them at the per-session admin page or via mix tasks:"
                  )}
                </p>
                <ul class="text-sm mt-2 ml-4 list-disc text-zinc-700 dark:text-zinc-300">
                  <li>
                    <code class="font-mono text-xs">/admin/sessions/&lt;id&gt;/external_mirror</code>
                  </li>
                  <li>
                    <code class="font-mono text-xs">
                      mix ezagent.external_mirror.bind &lt;session_uri&gt; feishu &lt;chat_id&gt; --as &lt;user_uri&gt;
                    </code>
                  </li>
                  <li>
                    <code class="font-mono text-xs">
                      mix ezagent.external_mirror.list_bindings &lt;session_uri&gt; --as &lt;user_uri&gt;
                    </code>
                  </li>
                </ul>
              </.card>
            </div>
          </:main_window>
        </WorkspaceShell.workspace_shell>
      </:body>
    </AppShell.app_shell>
    """
  end
end
