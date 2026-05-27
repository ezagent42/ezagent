defmodule EzagentPluginLiveview.EntityCapsLive do
  @moduledoc """
  Phase 8c PR-G (Allen 2026-05-20) — generic caps grant UI for any
  Entity Kind. Mirrors the CLI surface of `Ezagent.Behavior.Identity`
  (`grant_cap` / `revoke_cap` / `list_caps`).

  Mounts at:

  - `/identities/users/:uri/caps` — preserves the legacy route
    (Phase 6 PR 6 originally shipped as user-only).
  - `/identities/agents/:uri/caps` — new in PR-G; agents already carry
    `Ezagent.Behavior.Identity` (`Ezagent.Entity.Agent.behaviors/0`),
    so the dispatch path works unchanged — this is purely a UI
    exposure of an API that always accepted any entity URI.

  URI param is URL-encoded. Operations dispatch via `Invocation`;
  CapBAC step 5.5 enforces admin caps on the calling LV session
  (the LV owner, not the target entity).

  ## Feishu user note

  Feishu webhook → ESR maps the inbound Feishu user_id to a User Kind
  URI (e.g. `entity://user/team-alpha/feishu:ou_xxx`). Once that User exists in
  the KindRegistry, this LV grants caps to it the same way as any
  local user — the "Feishu cap-grant UI" the SPEC calls out is
  exactly this page with the URI shaped accordingly.

  ## CLI equivalence

  No dedicated mix task exists for grant/revoke today — this LV is
  the canonical operator surface. The underlying calls are:

      Invocation.dispatch(%Invocation{
        target: URI.new!("\#{entity_uri}?action=identity.grant_cap"),
        mode: :call,
        args: %{cap: %Capability{...}},
        ctx: %{caller: admin_uri, caps: admin_caps, reply: :sync}
      })

  (replace `grant_cap` with `revoke_cap` / `list_caps` as appropriate).
  """

  use Phoenix.LiveView
  # i18n (Allen 2026-05-22) — runtime backend reference; no compile-time
  # dep on :ezagent_web.
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.WorkspaceShell
  alias EzagentPluginLiveview.AppShell
  use EzagentDomainUi.Components
  import Phoenix.Component

  alias Ezagent.{Capability, Invocation, KindRegistry}

  @impl true
  def mount(%{"uri" => encoded}, _session, socket) do
    entity_uri = encoded |> URI.decode_www_form() |> URI.new!()
    # PR #123 hardening: on_mount sets current_entity_uri; caller is
    # the logged-in user, not a hardcoded admin fallback.
    caller_uri = socket.assigns.current_entity_uri

    # SPEC caps-cleanup-v1 §4.4 — admin caps now live in slice.
    caller_caps = Ezagent.Identity.list_caps_for(caller_uri)

    {:ok,
     socket
     |> assign(:entity_uri, entity_uri)
     |> assign(:entity_kind, entity_kind(entity_uri))
     |> assign(:caller_uri, caller_uri)
     |> assign(:caller_caps, caller_caps)
     |> assign(:flash_error, nil)
     |> assign(:flash_info, nil)
     |> assign(:grant_form, to_form(%{"kind" => "", "behavior" => "any", "instance" => "any"}, as: "grant"))
     |> load_caps()}
  end

  # Returns "user" | "agent" | "entity" for breadcrumb/copy.
  defp entity_kind(%URI{scheme: "entity", host: host}) when host in ["user", "agent"], do: host
  defp entity_kind(_), do: "entity"

  defp load_caps(socket) do
    case KindRegistry.lookup(socket.assigns.entity_uri) do
      :error ->
        assign(socket, :caps, :entity_not_live)

      {:ok, _pid} ->
        # Dispatch list_caps and capture the result.
        target = URI.new!("#{URI.to_string(socket.assigns.entity_uri)}?action=identity.list_caps")

        case Invocation.dispatch(%Invocation{
               target: target,
               mode: :call,
               args: %{},
               ctx: %{
                 caller: socket.assigns.caller_uri,
                 caps: socket.assigns.caller_caps,
                 reply: :sync
               }
             }) do
          {:ok, %{caps: caps}} -> assign(socket, :caps, caps)
          {:error, reason} -> assign(socket, :caps, {:error, reason})
        end
    end
  rescue
    err -> assign(socket, :caps, {:error, err})
  end

  @impl true
  def handle_event("grant", %{"grant" => params}, socket) do
    kind_str = Map.get(params, "kind", "") |> String.trim()

    if kind_str == "" do
      {:noreply, assign(socket, :flash_error, gettext("Kind required (e.g. echo, agent, :any)"))}
    else
      cap = build_cap(params, socket.assigns.caller_uri)

      do_grant_or_revoke(
        socket,
        :grant_cap,
        cap,
        gettext("Granted cap to %{uri}", uri: URI.to_string(socket.assigns.entity_uri))
      )
    end
  end

  def handle_event("revoke", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)

    case Enum.at(socket.assigns.caps, idx) do
      nil ->
        {:noreply,
         assign(socket, :flash_error, gettext("cap not found at index %{index}", index: idx))}

      cap ->
        do_grant_or_revoke(socket, :revoke_cap, cap, gettext("Revoked cap"))
    end
  end

  defp do_grant_or_revoke(socket, action, cap, msg) do
    target =
      URI.new!("#{URI.to_string(socket.assigns.entity_uri)}?action=identity.#{action}")

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: %{cap: cap},
           ctx: %{
             caller: socket.assigns.caller_uri,
             caps: socket.assigns.caller_caps,
             reply: :sync
           }
         }) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:flash_info, msg)
         |> assign(:flash_error, nil)
         |> load_caps()}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext("%{action} failed: %{reason}", action: action, reason: inspect(reason))
         )}
    end
  end

  defp build_cap(params, granted_by) do
    # Phase 9 PR-3 (SPEC v3 §4): the LV form doesn't expose a
    # workspace picker yet — Phase 9 PR-5 adds it as part of the
    # workspace selector overhaul. For now, default to the granted
    # entity's workspace (intra-workspace grant — the most common
    # operator action). Cross-workspace grants will require an
    # explicit workspace dropdown wired in PR-5.
    workspace_uri =
      case Map.get(params, "workspace_uri", "") do
        "any" -> :any
        "" -> default_workspace_for_entity(params)
        s when is_binary(s) -> URI.parse(s)
      end

    %Capability{
      kind: to_atom_or_any(Map.get(params, "kind", "any")),
      behavior: to_atom_or_any(Map.get(params, "behavior", "any")),
      # SPEC 2026-05-27 capability-action-axis §3.1 — the admin LV form
      # does NOT yet expose an action selector; admins implicitly mint
      # behavior-wildcard caps. The grant-boundary runtime check
      # (`Identity.invoke(:grant_cap)`) admits this because the logged-
      # in admin's caps satisfy `holds_admin_caps?/1`. A future PR adds
      # an action dropdown so admins can mint narrow caps via the UI.
      action: to_atom_or_any(Map.get(params, "action", "any")),
      instance: to_uri_or_any(Map.get(params, "instance", "any")),
      workspace_uri: workspace_uri,
      granted_by: granted_by,
      granted_at: DateTime.utc_now()
    }
  end

  # Resolve the workspace for a grant when the LV form omits it —
  # falls back to the granted entity's own workspace.
  defp default_workspace_for_entity(_params) do
    # The LV doesn't currently pass entity_uri through the form
    # params (the form only carries kind/behavior/instance). Use
    # `:any` as the conservative default; PR-5 wires the entity
    # context through.
    :any
  end

  defp to_atom_or_any("any"), do: :any
  defp to_atom_or_any(""), do: :any
  defp to_atom_or_any(s) when is_binary(s), do: String.to_atom(s)

  defp to_uri_or_any("any"), do: :any
  defp to_uri_or_any(""), do: :any
  defp to_uri_or_any(s) when is_binary(s), do: URI.parse(s)

  # Breadcrumb back-link target — `/identities` for agents (no
  # dedicated agents-list page), `/identities/users` for users
  # (preserves the existing user admin surface).
  defp parent_path("user"), do: "/identities/users"
  defp parent_path(_), do: "/identities"

  defp parent_label("user"), do: "← /identities/users"
  defp parent_label(_), do: "← /identities"

  @impl true
  def render(assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(Map.get(assigns, :current_entity_uri) || URI.parse("entity://user/system/admin"))
      end)

    ~H"""
    <AppShell.app_shell
      perspective={:workspace}
      current_entity_uri={@current_entity_uri_str}
      current_workspace_uri={@current_workspace_uri}
      workspace_name={@workspace_name}
      is_admin?={@is_admin?}
      is_system_member?={@is_system_member?}
      workspaces={@workspaces}
      cmdk_nav_routes={@cmdk_nav_routes}
    >
      <:body>
        <WorkspaceShell.workspace_shell
          current_entity_uri={@current_entity_uri_str}
          current_path={"/identities/" <> @entity_kind <> "s"}
          status={%{agents_alive: 0, bridges: 0, debug_events: 0, version: "dev"}}
        >
      <:main_window>
        <div class="flex-1 overflow-auto px-6 py-6 text-zinc-900 dark:text-zinc-100">
          <.page_header title={gettext("Caps for %{uri}", uri: URI.to_string(@entity_uri))}>
            <:subtitle>
              {gettext("Live cap mutation via Identity Behavior. Admin caps required (CapBAC at dispatch step 5.5).")}
              <a href={parent_path(@entity_kind)} class="text-zinc-600 dark:text-zinc-400 underline hover:text-zinc-900 dark:hover:text-zinc-100 ml-1">{parent_label(@entity_kind)}</a>
            </:subtitle>
          </.page_header>

          <p :if={@flash_info} class="text-emerald-700 dark:text-emerald-300 text-sm mb-3">{@flash_info}</p>
          <p :if={@flash_error} class="text-red-700 dark:text-red-300 text-sm mb-3">{@flash_error}</p>

          <.card class="mb-6">
            <:header>{gettext("Grant new cap")}</:header>
            <.form for={@grant_form} phx-submit="grant" id="grant-cap-form" class="grid grid-cols-3 gap-2 items-end">
              <label class="text-xs">
                kind
                <input type="text" name="grant[kind]" placeholder="echo or :any"
                  class="block w-full px-2 py-1 text-sm border border-zinc-300 dark:border-zinc-700 rounded-md" />
              </label>
              <label class="text-xs">
                behavior
                <input type="text" name="grant[behavior]" value="any"
                  class="block w-full px-2 py-1 text-sm border border-zinc-300 dark:border-zinc-700 rounded-md" />
              </label>
              <label class="text-xs">
                instance
                <input type="text" name="grant[instance]" value="any"
                  class="block w-full px-2 py-1 text-sm border border-zinc-300 dark:border-zinc-700 rounded-md" />
              </label>
              <div class="col-span-3 flex justify-end">
                <.button type="submit" variant="primary" size="sm">{gettext("Grant")}</.button>
              </div>
            </.form>
          </.card>

          <.card>
            <:header>{gettext("Current caps")}</:header>
            <%= case @caps do %>
              <% :entity_not_live -> %>
                <p class="text-red-700 dark:text-red-300 text-sm">{gettext("%{kind} Kind not registered (not live in BEAM).", kind: String.capitalize(@entity_kind))}</p>
              <% {:error, reason} -> %>
                <p class="text-red-700 dark:text-red-300 text-sm">{gettext("Error reading caps: %{reason}", reason: inspect(reason))}</p>
              <% caps when is_list(caps) and caps == [] -> %>
                <p class="text-zinc-500 italic text-sm">{gettext("No caps. Grant one above.")}</p>
              <% caps when is_list(caps) -> %>
                <table class="w-full text-sm">
                  <thead class="bg-zinc-50 dark:bg-zinc-950 border-b border-zinc-200 dark:border-zinc-800">
                    <tr class="text-left text-xs uppercase tracking-wide text-zinc-500">
                      <th class="px-2 py-2">kind</th>
                      <th class="py-2">behavior</th>
                      <th class="py-2">instance</th>
                      <th class="py-2">granted_by</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={{cap, i} <- Enum.with_index(caps)} class="border-b border-zinc-100 dark:border-zinc-900 last:border-0">
                      <td class="px-2 py-2 font-mono text-xs">{inspect(cap.kind)}</td>
                      <td class="py-2 font-mono text-xs">{inspect(cap.behavior)}</td>
                      <td class="py-2 font-mono text-xs">{inspect(cap.instance)}</td>
                      <td class="py-2 font-mono text-xs">{cap.granted_by && URI.to_string(cap.granted_by)}</td>
                      <td class="py-2 text-right pr-2">
                        <.button variant="danger" size="sm" phx-click="revoke" phx-value-index={i}>
                          {gettext("revoke")}
                        </.button>
                      </td>
                    </tr>
                  </tbody>
                </table>
            <% end %>
          </.card>
        </div>
      </:main_window>

        </WorkspaceShell.workspace_shell>
      </:body>
    </AppShell.app_shell>
    """
  end
end
