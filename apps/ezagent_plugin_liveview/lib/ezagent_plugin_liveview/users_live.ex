defmodule EzagentPluginLiveview.UsersLive do
  @moduledoc """
  /identities/users — list + create + disable Users (Phase 5 PR 2).

  Admin-only surface (route gate via RequireUser). Backed by `Ezagent.Users`
  (Phase 4-completion PR 4) — separate from User-Kind snapshot per
  Q-MU-2.

  Phase 8c PR-O (Allen 2026-05-20) — Username & Auth UI Tasks 1, 2, 3:
  - Display name primary, URI mono subtitle (Task 1).
  - Inline display-name editing via pencil button (Task 2).
  - Bare-handle input on create form (Task 3) — type `allen`, get
    `entity://user/default/allen` (also accepts full URI).
  """

  use Phoenix.LiveView
  # i18n V1 (Allen 2026-05-21) — see admin_dashboard_live for rationale.
  use Gettext, backend: EzagentPluginLiveview.Gettext
  import Phoenix.Component

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:users, list_users())
     |> assign(:editing_uri, nil)
     |> assign(:flash_error, nil)
     |> assign(:flash_info, nil)
     |> assign(:create_form, to_form(create_form_defaults(), as: "user"))}
  end

  # Task 3 — bare handle, not preformatted URI. Backend normalizes.
  defp create_form_defaults do
    %{"handle" => "", "password" => "", "caps" => "", "display_name" => ""}
  end

  defp list_users do
    users =
      Ezagent.Users.list_all()
      |> Enum.map(fn u ->
        Map.merge(u, %{
          has_password: not is_nil(u.password_hash),
          cap_count: length(u.caps),
          # PR-D of Presence rollout (SPEC
          # `docs/superpowers/specs/2026-05-23-presence.md` rev 3 §7) —
          # row carries `online?` from `Ezagent.Presence.list/1` to
          # render the online dot. Re-queried on every mount; future PR
          # can subscribe to `esr:presence:<uri>` for live update.
          online?: Ezagent.Presence.present?(u.uri),
          transports: u.uri |> Ezagent.Presence.list() |> transports_summary()
        })
      end)

    # Username & Auth UI Task 1 — batch-resolve display names so the
    # table can render display-name primary + URI mono subtitle.
    display_map =
      Ezagent.EntityPresenter.display_many(Enum.map(users, &URI.to_string(&1.uri)))

    Enum.map(users, fn u ->
      uri_str = URI.to_string(u.uri)
      Map.put(u, :display_name, Map.get(display_map, uri_str, uri_str))
    end)
  end

  # `Ezagent.Presence.list/1` returns `%{transport_id => [meta]}`. For
  # the table row we want a compact transports summary — the unique
  # `:transport` atoms (e.g. `[:liveview, :feishu]`) — so the operator
  # can see WHERE the user is connected.
  defp transports_summary(presence_list) do
    presence_list
    |> Map.values()
    |> Enum.flat_map(& &1)
    |> Enum.map(&Map.get(&1, :transport))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @impl true
  def handle_event("create_user", %{"user" => params}, socket) do
    # Task 3 — accept bare handle (`allen`) OR full URI (`entity://user/default/allen`).
    # Backend normalizes to canonical entity://user/<slug>.
    handle_or_uri = Map.get(params, "handle", "") |> String.trim()
    password = Map.get(params, "password", "")
    caps_str = Map.get(params, "caps", "")
    display_name = Map.get(params, "display_name", "") |> String.trim()

    uri = normalize_handle_to_uri(handle_or_uri)

    cond do
      uri == "" ->
        {:noreply, assign(socket, :flash_error, gettext("Username required (e.g. allen)"))}

      String.contains?(caps_str, "*") ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext("'*' caps require --allow-allcaps via mix; UI refuses for safety")
         )}

      true ->
        with {:ok, parsed_uri} <- parse_user_uri(uri),
             {:ok, caps} <-
               Ezagent.Capability.Parser.parse(caps_str, Ezagent.Entity.User.admin_uri()),
             pw = if(password == "", do: nil, else: password),
             {:ok, _decoded} <- Ezagent.Users.create(uri, pw, caps) do
          _ = maybe_spawn_kind(uri)
          _ = maybe_upsert_display_name(parsed_uri, display_name)

          {:noreply,
           socket
           |> assign(:users, list_users())
           |> assign(
             :flash_info,
             gettext("✓ created %{uri} (%{count} caps)", uri: uri, count: length(caps))
           )
           |> assign(:flash_error, nil)
           |> assign(:create_form, to_form(create_form_defaults(), as: "user"))}
        else
          {:error, reason} ->
            {:noreply,
             assign(
               socket,
               :flash_error,
               gettext("create failed: %{reason}", reason: inspect(reason))
             )}
        end
    end
  end

  # Task 2 — inline display-name editing.
  def handle_event("edit_display_name", %{"uri" => uri_str}, socket) do
    {:noreply, assign(socket, :editing_uri, uri_str)}
  end

  def handle_event("cancel_edit_display_name", _params, socket) do
    {:noreply, assign(socket, :editing_uri, nil)}
  end

  def handle_event("save_display_name", %{"uri" => uri_str, "display_name" => name}, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, assign(socket, :flash_error, gettext("Display name cannot be empty"))}
    else
      case Ezagent.Entity.Profile.upsert(%{entity_uri: uri_str, display_name: name}) do
        {:ok, _profile} ->
          {:noreply,
           socket
           |> assign(:users, list_users())
           |> assign(:editing_uri, nil)
           |> assign(
             :flash_info,
             gettext("✓ display name updated for %{uri}", uri: uri_str)
           )
           |> assign(:flash_error, nil)}

        {:error, changeset} ->
          {:noreply,
           assign(
             socket,
             :flash_error,
             gettext("update failed: %{reason}", reason: inspect(changeset.errors))
           )}
      end
    end
  end

  def handle_event("set_password", %{"uri" => uri, "password" => password}, socket)
      when is_binary(password) and password != "" do
    case Ezagent.Users.set_password(uri, password) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:users, list_users())
         |> assign(:flash_info, gettext("✓ password set for %{uri}", uri: uri))
         |> assign(:flash_error, nil)}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext("set_password failed: %{reason}", reason: inspect(reason))
         )}
    end
  end

  def handle_event("set_password", _params, socket) do
    {:noreply, assign(socket, :flash_error, gettext("password cannot be empty"))}
  end

  # PR #141 + #145: entity:// scheme; user URIs are entity://user/<name>.
  # Phase 9 PR-3 (SPEC v3 §3): now 3-segment
  # entity://user/<workspace>/<name>. Accepts both shapes — 2-segment
  # is auto-upgraded by normalize_handle_to_uri/1 above.
  defp parse_user_uri(s) do
    case URI.new(s) do
      {:ok, %URI{scheme: "entity", host: "user", path: "/" <> rest}}
      when is_binary(rest) and rest != "" ->
        {:ok, URI.parse(s)}

      _ ->
        {:error, {:bad_user_uri, s}}
    end
  end

  defp maybe_spawn_kind(uri_str) do
    uri = URI.parse(uri_str)

    if Code.ensure_loaded?(Ezagent.SpawnRegistry) do
      _ = Ezagent.SpawnRegistry.spawn(uri)
    end

    :ok
  end

  # Task 3 — bare handle (`allen`) or full URI (`entity://user/default/allen`).
  # Anything else falls through and parse_user_uri rejects with a
  # helpful error.
  #
  # Phase 9 PR-3 (SPEC v3 §3): entity URIs are 3-segment
  # `entity://user/<workspace>/<name>`. Bare handles default into
  # the `default` workspace; legacy 2-segment full URIs are upgraded
  # by injecting `default/`. Workspace selection UI lands in PR-5.
  defp normalize_handle_to_uri(""), do: ""

  defp normalize_handle_to_uri("entity://user/" <> rest = full) do
    if String.contains?(rest, "/") do
      # Already has workspace segment.
      full
    else
      # Legacy 2-segment shape — upgrade to 3-segment under `default`.
      "entity://user/default/" <> rest
    end
  end

  defp normalize_handle_to_uri(handle) do
    # Strip leading "@" if user typed `@allen`. Slug whitespace is invalid.
    handle = String.trim_leading(handle, "@") |> String.trim()
    "entity://user/default/" <> handle
  end

  # Task 1 + Task 2 — when create form supplies a display_name, persist
  # it. Best-effort: a failure here doesn't block user creation (the
  # row is created either way; admin can fix the display name later
  # via the inline edit).
  defp maybe_upsert_display_name(_uri, ""), do: :ok

  defp maybe_upsert_display_name(%URI{} = uri, name) do
    _ = Ezagent.Entity.Profile.upsert(%{entity_uri: URI.to_string(uri), display_name: name})
    :ok
  end

  alias EzagentDomainUi.WorkspaceShell
  alias EzagentPluginLiveview.AppShell
  use EzagentDomainUi.Components
  use EzagentDomainUi.Primitives

  @impl true
  def render(assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(assigns.current_entity_uri || URI.parse("entity://user/system/admin"))
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
          current_path="/identities/users"
          status={%{agents_alive: 0, bridges: 0, debug_events: 0, version: "dev"}}
        >
          <:main_window>
            <div class="flex-1 overflow-auto px-6 py-6">
              <.page_header title={gettext("Users")}>
                <:subtitle>
                  {gettext("Provisioned principals (independent of User Kind snapshot per Q-MU-2).")}
                </:subtitle>
              </.page_header>

              <%!-- Username & Auth UI Tasks 1+2 — display name primary, URI
                mono subtitle, inline pencil to edit display name. --%>
              <section id="users-list" class="mt-4">
                <p :if={@users == []} class="text-sm italic text-zinc-500">{gettext("No users.")}</p>

                <.card :if={@users != []}>
                  <table id="users-table" class="w-full text-sm">
                    <thead>
                      <tr class="border-b-2 border-zinc-200 dark:border-zinc-800 text-left text-xs uppercase tracking-wide text-zinc-500">
                        <th class="py-2">{gettext("Name / URI")}</th>
                        <th>{gettext("Password")}</th>
                        <th>{gettext("Caps")}</th>
                        <th>{gettext("Set password")}</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr
                        :for={u <- @users}
                        class="border-b border-zinc-100 dark:border-zinc-900 align-top"
                      >
                        <td class="py-2 pr-3 max-w-md">
                          <%= if @editing_uri == URI.to_string(u.uri) do %>
                            <form
                              phx-submit="save_display_name"
                              phx-click-away="cancel_edit_display_name"
                              class="flex gap-1 items-center"
                            >
                              <input type="hidden" name="uri" value={URI.to_string(u.uri)} />
                              <input
                                type="text"
                                name="display_name"
                                value={u.display_name}
                                autofocus
                                phx-key="escape"
                                phx-keydown="cancel_edit_display_name"
                                class="flex-1 px-2 py-1 text-xs border border-blue-400 dark:border-blue-600 rounded bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
                              />
                              <button
                                type="submit"
                                class="p-1 text-emerald-600 hover:text-emerald-700 dark:text-emerald-400"
                                aria-label={gettext("Save")}
                              >
                                <.icon name="check" size="xs" />
                              </button>
                              <button
                                type="button"
                                phx-click="cancel_edit_display_name"
                                class="p-1 text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300"
                                aria-label={gettext("Cancel")}
                              >
                                <.icon name="x" size="xs" />
                              </button>
                            </form>
                          <% else %>
                            <div class="flex items-center gap-1">
                              <%!-- PR-D of Presence rollout — online dot.
                               Green = at least one transport; gray = none. --%>
                              <span
                                class={[
                                  "inline-block w-2 h-2 rounded-full mr-1",
                                  u.online? && "bg-emerald-500",
                                  !u.online? && "bg-zinc-300 dark:bg-zinc-700"
                                ]}
                                title={
                                  if u.online?,
                                    do:
                                      gettext("online via %{transports}",
                                        transports: Enum.join(u.transports, ", ")
                                      ),
                                    else: gettext("offline")
                                }
                              >
                              </span>
                              <span class="font-medium text-zinc-900 dark:text-zinc-100">
                                {u.display_name}
                              </span>
                              <button
                                type="button"
                                phx-click="edit_display_name"
                                phx-value-uri={URI.to_string(u.uri)}
                                aria-label={
                                  gettext("Edit display name for %{name}", name: u.display_name)
                                }
                                class="p-1 text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-zinc-800 rounded"
                              >
                                <.icon name="pencil" size="xs" />
                              </button>
                            </div>
                          <% end %>
                          <div class="font-mono text-[10px] text-zinc-500 break-all">
                            {URI.to_string(u.uri)}
                          </div>
                        </td>
                        <td class="text-xs">
                          <.badge :if={u.has_password} variant="success">{gettext("set")}</.badge>
                          <.badge :if={!u.has_password} variant="danger">{gettext("unset")}</.badge>
                        </td>
                        <td class="text-xs">{u.cap_count}</td>
                        <td>
                          <form phx-submit="set_password" class="flex gap-1">
                            <input type="hidden" name="uri" value={URI.to_string(u.uri)} />
                            <input
                              type="password"
                              name="password"
                              placeholder={gettext("new password")}
                              class="px-2 py-1 text-xs border border-zinc-300 dark:border-zinc-700 rounded bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100 w-32"
                            />
                            <.button type="submit" variant="outline" size="sm">
                              {gettext("Set")}
                            </.button>
                          </form>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </.card>
              </section>

              <%!-- Username & Auth UI Task 3 — bare-handle input. Type
                "allen" → backend creates entity://user/allen. Full URI
                still accepted. --%>
              <section id="create-user" class="mt-6">
                <.card>
                  <h2 class="text-sm font-medium mb-3 text-zinc-900 dark:text-zinc-100">
                    {gettext("+ Create user")}
                  </h2>

                  <.form for={@create_form} phx-submit="create_user" class="space-y-3">
                    <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                      <div>
                        <label
                          for="user_handle"
                          class="block text-xs font-medium text-zinc-700 dark:text-zinc-300 mb-1"
                        >
                          {gettext("Username")}
                        </label>
                        <input
                          type="text"
                          id="user_handle"
                          name="user[handle]"
                          placeholder="allen"
                          value={@create_form.params["handle"]}
                          class="w-full px-2 py-1.5 text-xs border border-zinc-300 dark:border-zinc-700 rounded font-mono bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
                        />
                        <p class="mt-1 text-[11px] text-zinc-500">
                          {gettext("Accepts bare handle (%{handle}) or full URI (%{uri}).",
                            handle: "allen",
                            uri: "entity://user/default/allen"
                          )}
                        </p>
                      </div>
                      <div>
                        <label
                          for="user_display_name"
                          class="block text-xs font-medium text-zinc-700 dark:text-zinc-300 mb-1"
                        >
                          {gettext("Display name")}
                        </label>
                        <input
                          type="text"
                          id="user_display_name"
                          name="user[display_name]"
                          placeholder="Allen Woods"
                          value={@create_form.params["display_name"]}
                          class="w-full px-2 py-1.5 text-xs border border-zinc-300 dark:border-zinc-700 rounded bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
                        />
                        <p class="mt-1 text-[11px] text-zinc-500">
                          {gettext("Optional; editable later via pencil icon.")}
                        </p>
                      </div>
                      <div>
                        <label
                          for="user_password"
                          class="block text-xs font-medium text-zinc-700 dark:text-zinc-300 mb-1"
                        >
                          {gettext("Password")}
                        </label>
                        <input
                          type="password"
                          id="user_password"
                          name="user[password]"
                          placeholder={gettext("(optional)")}
                          class="w-full px-2 py-1.5 text-xs border border-zinc-300 dark:border-zinc-700 rounded bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
                        />
                        <p class="mt-1 text-[11px] text-zinc-500">
                          {gettext("If unset, user can only sign in via magic link.")}
                        </p>
                      </div>
                      <div>
                        <label
                          for="user_caps"
                          class="block text-xs font-medium text-zinc-700 dark:text-zinc-300 mb-1"
                        >
                          {gettext("Caps")}
                        </label>
                        <input
                          type="text"
                          id="user_caps"
                          name="user[caps]"
                          placeholder="chat.send,workspace.read"
                          class="w-full px-2 py-1.5 text-xs border border-zinc-300 dark:border-zinc-700 rounded font-mono bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
                        />
                        <p class="mt-1 text-[11px] text-zinc-500">
                          {gettext("%{format} comma-separated. %{wildcard} requires %{flag}.",
                            format: "kind.behavior[@instance_uri]",
                            wildcard: "*",
                            flag: "--allow-allcaps"
                          )}
                        </p>
                      </div>
                    </div>
                    <div class="flex justify-end">
                      <.button type="submit" variant="primary" size="sm">
                        {gettext("Create user")}
                      </.button>
                    </div>
                  </.form>

                  <p :if={@flash_error} class="text-rose-600 dark:text-rose-400 text-xs mt-3">
                    {@flash_error}
                  </p>
                  <p :if={@flash_info} class="text-emerald-600 dark:text-emerald-400 text-xs mt-3">
                    {@flash_info}
                  </p>
                </.card>
              </section>
            </div>
          </:main_window>
        </WorkspaceShell.workspace_shell>
      </:body>
    </AppShell.app_shell>
    """
  end
end
