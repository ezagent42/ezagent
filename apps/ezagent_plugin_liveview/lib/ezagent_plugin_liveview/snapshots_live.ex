defmodule EzagentPluginLiveview.SnapshotsLive do
  @moduledoc """
  /admin/snapshots — operator visibility into the `kind_snapshots` table
  (Phase 5 PR 3).

  Per Phase 5 SPEC §PR-3 D4: read-only list + dump-to-JSON modal +
  per-row Clear (deletes the snapshot row — next Kind spawn will
  init_fresh).
  """

  use Phoenix.LiveView
  # i18n (Allen 2026-05-22) — runtime backend reference; no compile-time
  # dep on :ezagent_web.
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.AdminShell
  alias EzagentPluginLiveview.AppShell
  use EzagentDomainUi.Components
  import Phoenix.Component

  alias Ezagent.Ecto.KindSnapshot

  @impl true
  def mount(_params, _session, socket) do
    # Admin gate enforced upstream by `live_session :require_admin`
    # in `EzagentWeb.Router` (codex PR #305 round-2 HIGH fix).
    # The codex round-1 finding (KindSnapshot.list_all/0 leaking
    # cross-tenant rows + clear/dump touching other tenants' state)
    # is still addressed below by `workspace_filter_for/1` and the
    # per-handler `workspace_allowed?/2` check — defence-in-depth
    # so a workspace admin only sees their own workspace, never
    # the system-scope all-rows view.
    workspace_filter = workspace_filter_for(socket.assigns)

    {:ok,
     socket
     |> assign(:workspace_filter, workspace_filter)
     |> assign(:snapshots, list_snapshots(workspace_filter))
     |> assign(:selected_uri, nil)
     |> assign(:selected_dump, nil)
     |> assign(:flash_error, nil)}
  end

  defp workspace_filter_for(%{is_system_member?: true}), do: :all

  defp workspace_filter_for(%{current_workspace_uri: %URI{} = wsu}),
    do: {:scoped, URI.to_string(wsu)}

  defp workspace_filter_for(%{current_workspace_uri: wsu}) when is_binary(wsu),
    do: {:scoped, wsu}

  defp workspace_filter_for(_), do: {:scoped, "workspace://__none__"}

  defp list_snapshots(:all) do
    KindSnapshot.list_all() |> Enum.map(&row_to_view/1)
  end

  defp list_snapshots({:scoped, workspace_uri}) do
    KindSnapshot.list_in_workspace(workspace_uri) |> Enum.map(&row_to_view/1)
  end

  defp row_to_view(row) do
    bytes = if is_binary(row.state_binary), do: byte_size(row.state_binary), else: 0

    %{
      uri: row.uri,
      kind_type: row.kind_type,
      bytes: bytes,
      version: row.version,
      updated_at: row.updated_at,
      workspace_uri: row.workspace_uri
    }
  end

  @impl true
  def handle_event("dump", %{"uri" => uri}, socket) do
    # Codex PR #305 round-2 HIGH fix: verify the row's
    # workspace_uri before decoding/showing it. The list page is
    # already filtered, but a hostile deep-link could POST a `uri`
    # from another tenant via the dump handler.
    with row when not is_nil(row) <- KindSnapshot.get(uri),
         :ok <- workspace_allowed?(row.workspace_uri, socket.assigns.workspace_filter) do
      decoded =
        case KindSnapshot.decode_state(row) do
          {:ok, state} ->
            # Use inspect/2 since term_to_binary may contain MapSet etc.
            # which JSON can't represent.
            inspect(state, pretty: true, limit: :infinity, width: 80)

          {:error, reason} ->
            "(decode error: #{inspect(reason)})"
        end

      {:noreply,
       socket
       |> assign(:selected_uri, uri)
       |> assign(:selected_dump, decoded)
       |> assign(:flash_error, nil)}
    else
      nil ->
        {:noreply,
         assign(socket, :flash_error, gettext("snapshot not found: %{uri}", uri: uri))}

      {:error, :cross_workspace} ->
        # Fail-closed: don't reveal that the row exists in another
        # tenant; mirror the "not found" message.
        {:noreply,
         assign(socket, :flash_error, gettext("snapshot not found: %{uri}", uri: uri))}
    end
  end

  def handle_event("close_dump", _, socket) do
    {:noreply,
     socket
     |> assign(:selected_uri, nil)
     |> assign(:selected_dump, nil)}
  end

  def handle_event("clear", %{"uri" => uri}, socket) do
    # Codex PR #305 round-2 HIGH fix: verify workspace before DELETE.
    # Cross-tenant deletion would destroy state the operator can't
    # see + can't undo.
    with row when not is_nil(row) <- KindSnapshot.get(uri),
         :ok <- workspace_allowed?(row.workspace_uri, socket.assigns.workspace_filter) do
      :ok = KindSnapshot.delete(uri)

      {:noreply,
       socket
       |> assign(:snapshots, list_snapshots(socket.assigns.workspace_filter))
       |> assign(:selected_uri, nil)
       |> assign(:selected_dump, nil)
       |> assign(:flash_error, nil)}
    else
      nil ->
        {:noreply,
         assign(socket, :flash_error, gettext("snapshot not found: %{uri}", uri: uri))}

      {:error, :cross_workspace} ->
        {:noreply,
         assign(socket, :flash_error, gettext("snapshot not found: %{uri}", uri: uri))}
    end
  end

  defp workspace_allowed?(_row_workspace, :all), do: :ok

  defp workspace_allowed?(row_workspace, {:scoped, scope_workspace})
       when row_workspace == scope_workspace,
       do: :ok

  defp workspace_allowed?(_row_workspace, {:scoped, _}), do: {:error, :cross_workspace}

  @impl true
  def render(assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(Map.get(assigns, :current_entity_uri) || Ezagent.URI.parse!("entity://user/system/admin"))
      end)

    ~H"""
    <AppShell.app_shell
      perspective={:admin}
      current_entity_uri={@current_entity_uri_str}
      current_workspace_uri={@current_workspace_uri}
      workspaces={@workspaces}
      workspace_name={@workspace_name}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      cmdk_nav_routes={@cmdk_nav_routes}
    >
      <:body>
        <AdminShell.admin_shell current_path="/admin/snapshots" active_section={:snapshots}>
          <:main>
            <div class="px-6 py-6 text-zinc-900 dark:text-zinc-100">
              <.page_header title={gettext("Snapshots")}>
                <:subtitle>
                  {gettext(
                    "Per-Kind runtime state snapshots (Phase 4-completion PR 2, Decision #115). One row per kind_snapshots.uri."
                  )}
                </:subtitle>
              </.page_header>

              <%!-- V-4 scrub (audit 2026-05-23): inline style="" purged
                    in favour of EzagentDomainUi atoms + Tailwind tokens. --%>
              <.card id="snapshots-list">
                <p :if={@snapshots == []} class="text-sm text-zinc-500 italic">
                  {gettext("No snapshots yet.")}
                </p>

                <table
                  :if={@snapshots != []}
                  id="snapshots-table"
                  class="w-full text-xs border-collapse"
                >
                  <thead>
                    <tr class="border-b border-zinc-200 dark:border-zinc-800">
                      <th class="text-left px-1 py-1.5">{gettext("URI")}</th>
                      <th class="text-left">{gettext("Kind")}</th>
                      <th class="text-right">{gettext("Bytes")}</th>
                      <th class="text-left">{gettext("Version")}</th>
                      <th class="text-left">{gettext("Updated")}</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={s <- @snapshots}
                      class="border-b border-zinc-100 dark:border-zinc-900"
                    >
                      <td class="px-1 py-1 font-mono text-[11px] break-all">{s.uri}</td>
                      <td class="text-[11px]">{s.kind_type}</td>
                      <td class="text-right text-[11px]">{s.bytes}</td>
                      <td class="text-[11px]">{s.version}</td>
                      <td class="text-[11px] text-zinc-500">
                        {DateTime.to_iso8601(s.updated_at)}
                      </td>
                      <td class="whitespace-nowrap">
                        <.button
                          variant="outline"
                          size="sm"
                          type="button"
                          phx-click="dump"
                          phx-value-uri={s.uri}
                          class="text-[11px] px-2 py-0.5 h-auto mr-1 text-sky-700 dark:text-sky-300 border-sky-300 dark:border-sky-700"
                        >
                          {gettext("Dump")}
                        </.button>
                        <.button
                          variant="outline"
                          size="sm"
                          type="button"
                          phx-click="clear"
                          phx-value-uri={s.uri}
                          class="text-[11px] px-2 py-0.5 h-auto text-rose-700 dark:text-rose-300 border-rose-300 dark:border-rose-700"
                          data-confirm={gettext("Clear this snapshot? Next Kind spawn will init_fresh — granted caps / runtime state are LOST.")}
                        >
                          {gettext("Clear")}
                        </.button>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </.card>

              <.card :if={@selected_dump} id="dump-view" class="mt-6">
                <:header>
                  <div class="flex items-center justify-between gap-2">
                    <span>{gettext("Dump:")} <code class="font-mono text-[11px]">{@selected_uri}</code></span>
                    <.button
                      variant="ghost"
                      size="sm"
                      type="button"
                      phx-click="close_dump"
                      class="text-[11px] px-2 py-0.5 h-auto"
                    >
                      {gettext("Close")}
                    </.button>
                  </div>
                </:header>
                <pre class="bg-zinc-50 dark:bg-zinc-950 p-3 rounded-md overflow-x-auto text-[11px] max-h-[480px] text-zinc-700 dark:text-zinc-300">{@selected_dump}</pre>
              </.card>

              <p :if={@flash_error} class="text-rose-700 dark:text-rose-300 text-xs mt-2">
                {@flash_error}
              </p>
            </div>
          </:main>
        </AdminShell.admin_shell>
      </:body>
    </AppShell.app_shell>
    """
  end
end
