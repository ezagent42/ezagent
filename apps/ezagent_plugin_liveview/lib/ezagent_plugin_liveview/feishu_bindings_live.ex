defmodule EzagentPluginLiveview.FeishuBindingsLive do
  @moduledoc """
  Phase 6 PR 15 — /plugins/feishu/bindings.

  Two sections:

  1. **User bindings** — `feishu_user_bindings` rows (open_id ↔ user_uri).
     The bind form goes through `BindingPolicy.apply/2` so the cap-grant
     side effect fires the same way `mix ezagent.feishu.bind` does. The
     unbind button deletes via `EzagentPluginFeishu.UserBinding.unbind/1`.

  2. **Session bindings** (V1 fix, 2026-05-22) — `feishu_session_bindings`
     rows (chat_id ↔ session_uri). Mirrors `mix ezagent.feishu.chat.bind`.
     A bound + enabled chat mirrors session messages outbound and routes
     Feishu replies inbound. Bind form + per-row unbind. The `enabled`
     flag is displayed; there is no `set_enabled/2` in
     `EzagentPluginFeishu.SessionBinding`'s public API (only `bind/2`
     which upserts `enabled: true`, and `unbind/1`), so an enable/disable
     toggle is deferred until that API is added.

  ## URI fields use `uri_picker` (fix 2026-05-22)

  The V1 UI `uri_picker` SPEC scoped 6 picker sites; this page's
  session-binding form postdated the SPEC, so its two ESR-URI fields
  (`user_uri`, `session_uri`) stayed raw text inputs. They are now
  `EzagentDomainUi.Primitives.uri_picker/1` `:single` comboboxes:

  - `user_uri` → picker over entities (`Ezagent.UI.UriOptions.entities/2`)
  - `session_uri` → picker over sessions (`Ezagent.UI.UriOptions.sessions/2`)

  `open_id` / `chat_id` are Feishu identifiers, NOT URIs — they stay
  text inputs. Both pickers set `allow_freetext: true`: a binding is a
  *declaration* (a Feishu chat may be bound to a session spawned from a
  template later; a user may be bound before its entity is live), so an
  operator must be able to name a not-yet-live URI. The shared
  `Ezagent.UI.UriOptions.valid_for?/4` revalidates every submit (SPEC
  §1.6) — well-formed + in-workspace, no liveness requirement — so the
  free-text path is still tenant-safe.
  """

  use Phoenix.LiveView
  # i18n (Allen 2026-05-22) — runtime backend reference; no compile-time
  # dep on :ezagent_web.
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.WorkspaceShell
  alias EzagentPluginLiveview.AppShell
  alias Ezagent.UI.UriOptions
  use EzagentDomainUi.Components
  use EzagentDomainUi.Primitives
  import Phoenix.Component

  alias EzagentPluginFeishu.{BindingPolicy, SessionBinding, UserBinding}

  @impl true
  def mount(_params, session, socket) do
    # `:require_entity` on_mount has already set `current_entity_uri`
    # (a `%URI{}`) + `current_workspace_uri` in socket.assigns. Keep
    # `admin_uri` (a string, what `UserBinding.bind/3` / `BindingPolicy`
    # expect as `bound_by`) derived from the session slot.
    admin_uri =
      case Map.get(session || %{}, "current_entity_uri") do
        nil -> "entity://user/system/admin"
        s -> s
      end

    # V1 UI `uri_picker` options. Caller-authorized: `UriOptions`
    # resolves workspace authority itself from `current_entity_uri` +
    # `current_workspace_uri`. A non-system caller viewing a foreign
    # workspace gets `[]` (never leaks).
    caller_uri = socket.assigns[:current_entity_uri]
    workspace_uri = socket.assigns[:current_workspace_uri]

    {:ok,
     socket
     |> assign(:admin_uri, admin_uri)
     |> assign(:bindings, UserBinding.list_all())
     |> assign(:session_bindings, SessionBinding.list_all())
     |> assign(:flash_info, nil)
     |> assign(:flash_error, nil)
     |> assign(:entity_options, UriOptions.entities(caller_uri, workspace_uri))
     |> assign(:session_options, UriOptions.sessions(caller_uri, workspace_uri))
     |> assign(:bind_form, to_form(%{"open_id" => "", "user_uri" => ""}, as: "bind"))
     |> assign(
       :session_bind_form,
       to_form(%{"chat_id" => "", "session_uri" => ""}, as: "session_bind")
     )}
  end

  @impl true
  def handle_event("bind", %{"bind" => %{"open_id" => open_id, "user_uri" => user_uri}}, socket) do
    open_id = String.trim(open_id)
    user_uri = String.trim(user_uri)

    # V1 UI PR-1 (SPEC §1.6) — the uri_picker hidden input is untrusted
    # user-controlled DOM. Revalidate server-side via the SHARED
    # validator: well-formed entity URI, in the caller's workspace (or
    # caller holds cross-workspace authority). `valid_for?/4` does NOT
    # require liveness — a binding may name an entity not yet spawned.
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
        {:noreply,
         assign(socket, :flash_error, gettext("no binding for %{id}", id: open_id))}
    end
  end

  # --- Session bindings (chat_id ↔ session_uri) -----------------------------
  #
  # Mirrors `mix ezagent.feishu.chat.bind`: chat_id must start with `oc_`
  # (Feishu open-chat-id convention), session_uri must be a `session://` URI.

  def handle_event(
        "bind_session",
        %{"session_bind" => %{"chat_id" => chat_id, "session_uri" => session_uri}},
        socket
      ) do
    chat_id = String.trim(chat_id)
    session_uri = String.trim(session_uri)

    # V1 UI PR-1 (SPEC §1.6) — the uri_picker hidden input is untrusted
    # user-controlled DOM. Revalidate server-side via the SHARED
    # validator: well-formed session URI, in the caller's workspace (or
    # caller holds cross-workspace authority). This subsumes the prior
    # `starts_with?("session://")` string check.
    caller_uri = socket.assigns[:current_entity_uri]
    workspace_uri = socket.assigns[:current_workspace_uri]

    cond do
      chat_id == "" or session_uri == "" ->
        {:noreply, assign(socket, :flash_error, gettext("chat_id and session_uri are required"))}

      not String.starts_with?(chat_id, "oc_") ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext("chat_id must start with `oc_` (Feishu open-chat-id)")
         )}

      not UriOptions.valid_for?(caller_uri, workspace_uri, session_uri, [:session]) ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext(
             "Rejected %{uri} — must be a session URI in this workspace. Pick from the list.",
             uri: inspect(session_uri)
           )
         )}

      true ->
        case SessionBinding.bind(chat_id, session_uri) do
          {:ok, _row} ->
            {:noreply,
             socket
             |> assign(:session_bindings, SessionBinding.list_all())
             |> assign(
               :flash_info,
               gettext("Bound %{from} → %{to}", from: chat_id, to: session_uri)
             )
             |> assign(:flash_error, nil)
             |> assign(
               :session_bind_form,
               to_form(%{"chat_id" => "", "session_uri" => ""}, as: "session_bind")
             )}

          {:error, reason} ->
            {:noreply,
             assign(
               socket,
               :flash_error,
               gettext("session bind failed: %{reason}", reason: inspect(reason))
             )}
        end
    end
  end

  def handle_event("unbind_session", %{"chat-id" => chat_id}, socket) do
    case SessionBinding.unbind(chat_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:session_bindings, SessionBinding.list_all())
         |> assign(:flash_info, gettext("Unbound %{id}", id: chat_id))
         |> assign(:flash_error, nil)}

      {:error, :not_found} ->
        {:noreply,
         assign(socket, :flash_error, gettext("no session binding for %{id}", id: chat_id))}
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
              <.page_header title={gettext("Feishu bindings")}>
                <:subtitle>
                  {gettext(
                    "Two binding kinds: user bindings (open_id ↔ user URI, grants chat caps) and session bindings (chat_id ↔ session URI, mirrors a session to a Feishu chat)."
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

              <h2 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100 mb-2">
                {gettext("User bindings")}
              </h2>

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
                  <%!--
            uri_picker :single over in-workspace entities. allow_freetext
            ON so an operator can bind a user before its entity Kind is
            live. Submits bind[user_uri] as a string; revalidated
            server-side via UriOptions.valid_for?/4.
          --%>
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
                    <.button type="submit" variant="primary" size="sm">{gettext("Bind + grant cap")}</.button>
                  </div>
                </.form>
              </.card>

              <.card class="mb-8">
                <:header>{gettext("Current user bindings (%{count})", count: length(@bindings))}</:header>
                <p :if={@bindings == []} class="text-zinc-500 italic text-sm">
                  {gettext("No bindings yet. Unbound Feishu users see the bot react with EYES — bind them above to enable chat.")}
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

              <h2 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100 mb-2">
                {gettext("Session bindings")}
              </h2>

              <.card class="mb-6">
                <:header>{gettext("Bind chat_id ↔ session URI")}</:header>
                <.form
                  for={@session_bind_form}
                  phx-submit="bind_session"
                  class="grid grid-cols-2 gap-2 items-start"
                >
                  <label class="text-xs text-zinc-700 dark:text-zinc-300">
                    {gettext("Feishu chat_id")}
                    <input
                      type="text"
                      name="session_bind[chat_id]"
                      placeholder="oc_abc123..."
                      class="block w-full px-2 py-1 mt-1 text-sm border border-zinc-300 dark:border-zinc-700 rounded-md font-mono bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
                    />
                  </label>
                  <%!--
            uri_picker :single over in-workspace sessions. allow_freetext
            ON so an operator can bind a chat to a session spawned from a
            template later. Submits session_bind[session_uri] as a
            string; revalidated server-side via UriOptions.valid_for?/4.
          --%>
                  <.uri_picker
                    name="session_bind[session_uri]"
                    mode={:single}
                    kinds={[:session]}
                    options={@session_options}
                    allow_freetext={true}
                    label={gettext("session URI")}
                    placeholder="session://default/default/main"
                  />
                  <div class="col-span-2 flex justify-end">
                    <.button type="submit" variant="primary" size="sm">{gettext("Bind chat")}</.button>
                  </div>
                </.form>
              </.card>

              <.card>
                <:header>{gettext("Current session bindings (%{count})", count: length(@session_bindings))}</:header>
                <p :if={@session_bindings == []} class="text-zinc-500 italic text-sm">
                  {gettext("No session bindings yet. Bind a Feishu chat_id above to mirror a session's messages into a Feishu chat (and route replies back in).")}
                </p>
                <table :if={@session_bindings != []} class="w-full text-sm">
                  <thead class="bg-zinc-50 dark:bg-zinc-950 border-b border-zinc-200 dark:border-zinc-800">
                    <tr class="text-left text-xs uppercase tracking-wide text-zinc-500">
                      <th class="px-2 py-2">chat_id</th>
                      <th class="py-2">session_uri</th>
                      <th class="py-2">{gettext("enabled")}</th>
                      <th class="py-2">{gettext("when")}</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={b <- @session_bindings}
                      class="border-b border-zinc-100 dark:border-zinc-900 last:border-0"
                    >
                      <td class="px-2 py-2 font-mono text-xs">{b.chat_id}</td>
                      <td class="py-2 font-mono text-xs">{b.session_uri}</td>
                      <td class="py-2">
                        <.badge variant={if b.enabled, do: "success", else: "warning"}>
                          {if b.enabled, do: gettext("enabled"), else: gettext("disabled")}
                        </.badge>
                      </td>
                      <td class="py-2 text-xs text-zinc-500">{DateTime.to_iso8601(b.created_at)}</td>
                      <td class="py-2 text-right pr-2">
                        <.button
                          variant="danger"
                          size="sm"
                          phx-click="unbind_session"
                          phx-value-chat-id={b.chat_id}
                        >
                          {gettext("unbind")}
                        </.button>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </.card>
            </div>
          </:main_window>
        </WorkspaceShell.workspace_shell>
      </:body>
    </AppShell.app_shell>
    """
  end
end
