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
    {:ok,
     socket
     |> assign(:snapshots, list_snapshots())
     |> assign(:selected_uri, nil)
     |> assign(:selected_dump, nil)
     |> assign(:flash_error, nil)}
  end

  defp list_snapshots do
    KindSnapshot.list_all()
    |> Enum.map(fn row ->
      bytes =
        if is_binary(row.state_binary), do: byte_size(row.state_binary), else: 0

      %{
        uri: row.uri,
        kind_type: row.kind_type,
        bytes: bytes,
        version: row.version,
        updated_at: row.updated_at
      }
    end)
  end

  @impl true
  def handle_event("dump", %{"uri" => uri}, socket) do
    case KindSnapshot.get(uri) do
      nil ->
        {:noreply,
         assign(socket, :flash_error, gettext("snapshot not found: %{uri}", uri: uri))}

      row ->
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
    end
  end

  def handle_event("close_dump", _, socket) do
    {:noreply,
     socket
     |> assign(:selected_uri, nil)
     |> assign(:selected_dump, nil)}
  end

  def handle_event("clear", %{"uri" => uri}, socket) do
    :ok = KindSnapshot.delete(uri)

    {:noreply,
     socket
     |> assign(:snapshots, list_snapshots())
     |> assign(:selected_uri, nil)
     |> assign(:selected_dump, nil)
     |> assign(:flash_error, nil)}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(Map.get(assigns, :current_entity_uri) || URI.parse("entity://user/system/admin"))
      end)

    ~H"""
    <AppShell.app_shell
      perspective={:admin}
      current_entity_uri={@current_entity_uri_str}
      current_workspace_uri={@current_workspace_uri}
      workspaces={@workspaces}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      cmdk_nav_routes={@cmdk_nav_routes}
    >
      <:body>
        <AdminShell.admin_shell current_path="/admin/snapshots" active_section={:snapshots}>
          <:main>
            <div class="px-6 py-6 text-zinc-900 dark:text-zinc-100">
          <header>
            <h1 style="font-size: 22px; font-weight: 600;">{gettext("Snapshots")}</h1>
            <p style="font-size: 13px; color: #666;">
              {gettext(
                "Per-Kind runtime state snapshots (Phase 4-completion PR 2, Decision #115). One row per kind_snapshots.uri."
              )}
            </p>
          </header>

          <section id="snapshots-list" style="margin-top: 16px;">
            <p :if={@snapshots == []} style="color: #57606a; font-style: italic;">
              {gettext("No snapshots yet.")}
            </p>

            <table
              :if={@snapshots != []}
              id="snapshots-table"
              style="width: 100%; font-size: 13px; border-collapse: collapse;"
            >
              <thead>
                <tr style="border-bottom: 2px solid #d1d5da;">
                  <th style="text-align: left; padding: 6px 4px;">{gettext("URI")}</th>
                  <th style="text-align: left;">{gettext("Kind")}</th>
                  <th style="text-align: right;">{gettext("Bytes")}</th>
                  <th style="text-align: left;">{gettext("Version")}</th>
                  <th style="text-align: left;">{gettext("Updated")}</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={s <- @snapshots} style="border-bottom: 1px solid #eaeef2;">
                  <td style="padding: 6px 4px; font-family: monospace; font-size: 11px;">{s.uri}</td>
                  <td style="font-size: 11px;">{s.kind_type}</td>
                  <td style="text-align: right; font-size: 11px;">{s.bytes}</td>
                  <td style="font-size: 11px;">{s.version}</td>
                  <td style="font-size: 11px; color: #57606a;">
                    {DateTime.to_iso8601(s.updated_at)}
                  </td>
                  <td>
                    <button
                      type="button"
                      phx-click="dump"
                      phx-value-uri={s.uri}
                      style="padding: 4px 10px; background: white; color: #0969da; border: 1px solid #0969da; border-radius: 4px; cursor: pointer; font-size: 11px; margin-right: 4px;"
                    >
                      {gettext("Dump")}
                    </button>
                    <button
                      type="button"
                      phx-click="clear"
                      phx-value-uri={s.uri}
                      style="padding: 4px 10px; background: white; color: #cf222e; border: 1px solid #cf222e; border-radius: 4px; cursor: pointer; font-size: 11px;"
                      data-confirm={gettext("Clear this snapshot? Next Kind spawn will init_fresh — granted caps / runtime state are LOST.")}
                    >
                      {gettext("Clear")}
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </section>

          <section
            :if={@selected_dump}
            id="dump-view"
            style="margin-top: 24px; padding: 16px; border: 1px solid #d1d5da; border-radius: 6px;"
          >
            <h2 style="font-size: 14px; font-weight: 500; margin: 0 0 8px 0;">
              {gettext("Dump:")} <code>{@selected_uri}</code>
              <button
                type="button"
                phx-click="close_dump"
                style="float: right; padding: 4px 10px; background: white; color: #57606a; border: 1px solid #d1d5da; border-radius: 4px; cursor: pointer; font-size: 11px;"
              >
                {gettext("Close")}
              </button>
            </h2>
            <pre style="background: #f6f8fa; padding: 12px; border-radius: 4px; overflow-x: auto; font-size: 11px; max-height: 480px;">{@selected_dump}</pre>
          </section>

          <p :if={@flash_error} style="color: #cf222e; font-size: 12px; margin-top: 8px;">
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
