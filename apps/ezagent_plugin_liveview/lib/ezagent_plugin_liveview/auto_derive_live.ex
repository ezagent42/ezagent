defmodule EzagentPluginLiveview.AutoDeriveLive do
  @moduledoc """
  Phase 6 PR 10 — generic LV that lists / details any Kind via
  `EzagentDomainUi.AutoDerive`.

  Two modes (drive by URL):
    /plugins/auto/:kind          → list view (table of live URIs +
                                 slice keys + behaviors)
    /plugins/auto/:kind/:uri     → detail view (URI-decoded; slices
                                 rendered as <pre>{inspect})

  Validates the auto-derive thesis: ANY Kind, including 3rd-party
  plugin Kinds nobody on the core team knows about, gets a working
  admin surface for free.
  """

  use Phoenix.LiveView
  # i18n (Allen 2026-05-22) — runtime backend reference; no compile-time
  # dep on :ezagent_web.
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.WorkspaceShell
  alias EzagentPluginLiveview.AppShell
  use EzagentDomainUi.Components
  import Phoenix.Component

  alias EzagentDomainUi.AutoDerive
  alias EzagentPluginLiveview.CredentialCascadeUi

  @impl true
  def mount(params, _session, socket) do
    kind = String.to_atom(params["kind"])

    {:ok,
     socket
     |> assign(:kind, kind)
     |> assign(:detail_uri, decode_uri(params["uri"]))
     |> assign(:instances, AutoDerive.list_instances(kind))
     |> assign_cascade_caller()
     |> maybe_load_detail()
     |> assign_cascade_detail()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    new_kind = String.to_atom(params["kind"])

    {:noreply,
     socket
     |> assign(:kind, new_kind)
     |> assign(:detail_uri, decode_uri(params["uri"]))
     |> assign(:instances, AutoDerive.list_instances(new_kind))
     |> assign_cascade_caller()
     |> maybe_load_detail()
     |> assign_cascade_detail()}
  end

  @impl true
  def handle_event("set_default_source", %{"default_source" => params}, socket) do
    case CredentialCascadeUi.set_default_source(
           params,
           socket.assigns.cascade_caller_uri,
           socket.assigns.cascade_caller_caps
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:cascade_notice, gettext("Default source updated"))
         |> assign(:cascade_error, nil)
         |> maybe_load_detail()
         |> assign_cascade_detail()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:cascade_notice, nil)
         |> assign(
           :cascade_error,
           gettext("Set default source failed: %{reason}", reason: inspect(reason))
         )}
    end
  end

  def handle_event(
        "revoke_credential_grant",
        _params,
        %{assigns: %{detail_uri: %URI{} = uri}} = socket
      ) do
    case CredentialCascadeUi.revoke_grant(
           uri,
           socket.assigns.cascade_caller_uri,
           socket.assigns.cascade_caller_caps
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:cascade_notice, gettext("Grant revoked"))
         |> assign(:cascade_error, nil)
         |> maybe_load_detail()
         |> assign_cascade_detail()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:cascade_notice, nil)
         |> assign(
           :cascade_error,
           gettext("Grant revoke failed: %{reason}", reason: inspect(reason))
         )}
    end
  end

  defp decode_uri(nil), do: nil

  defp decode_uri(encoded) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # with try/rescue keeping the nil-fallback display semantics.
    try do
      Ezagent.URI.new!(URI.decode(encoded))
    rescue
      ArgumentError -> nil
    end
  end

  defp maybe_load_detail(%{assigns: %{detail_uri: nil}} = socket) do
    assign(socket, :detail, nil)
  end

  defp maybe_load_detail(%{assigns: %{detail_uri: uri}} = socket) do
    case AutoDerive.instance_detail(uri) do
      {:ok, detail} -> assign(socket, :detail, detail)
      {:error, reason} -> assign(socket, :detail, {:error, reason})
    end
  end

  defp assign_cascade_caller(socket) do
    caller = Map.get(socket.assigns, :current_entity_uri) || Ezagent.Entity.User.admin_uri()

    socket
    |> assign(:cascade_caller_uri, caller)
    |> assign(:cascade_caller_caps, Ezagent.Identity.list_caps_for(caller))
    |> assign_new(:cascade_notice, fn -> nil end)
    |> assign_new(:cascade_error, fn -> nil end)
  end

  defp assign_cascade_detail(%{assigns: %{detail_uri: %URI{} = uri, detail: detail}} = socket)
       when is_map(detail) do
    cascade = CredentialCascadeUi.detail_for(uri, detail)

    socket
    |> assign(:cascade_detail, cascade)
    |> assign(
      :default_source_form,
      to_form((cascade && cascade.form) || %{}, as: "default_source")
    )
  end

  defp assign_cascade_detail(socket) do
    socket
    |> assign(:cascade_detail, nil)
    |> assign(:default_source_form, to_form(%{}, as: "default_source"))
  end

  @impl true
  def render(assigns) do
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        Ezagent.URI.stable_key(
          Map.get(assigns, :current_entity_uri) || Ezagent.Entity.User.admin_uri()
        )
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
          current_path="/plugins/auto"
          status={%{agents_alive: 0, bridges: 0, debug_events: 0, version: "dev"}}
        >
          <:main_window>
            <div class="flex-1 overflow-auto px-6 py-6 text-zinc-900 dark:text-zinc-100">
              <.page_header title={gettext("Auto-derived: %{kind}", kind: Atom.to_string(@kind))}>
                <:subtitle>
                  {gettext("Generic admin surface, no hand-written code per Kind.")}
                  <a
                    href="/plugins"
                    class="text-zinc-600 dark:text-zinc-400 underline hover:text-zinc-900 dark:hover:text-zinc-100 ml-1"
                  >
                    ← {gettext("Plugins")}
                  </a>
                </:subtitle>
              </.page_header>

              <div :if={!@detail_uri}>
                <.card>
                  <:header>{gettext("%{count} live instance(s)", count: length(@instances))}</:header>
                  <p :if={@instances == []} class="text-zinc-500 italic text-sm">
                    {gettext("No live instances of %{kind}.", kind: to_string(@kind))}
                  </p>

                  <table :if={@instances != []} class="w-full text-sm">
                    <thead class="bg-zinc-50 dark:bg-zinc-950 border-b border-zinc-200 dark:border-zinc-800">
                      <tr class="text-left text-xs uppercase tracking-wide text-zinc-500">
                        <th class="px-2 py-2">{gettext("URI")}</th>
                        <th class="py-2">{gettext("Slice keys")}</th>
                        <th></th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr
                        :for={inst <- @instances}
                        class="border-b border-zinc-100 dark:border-zinc-900 last:border-0"
                      >
                        <td class="px-2 py-2 font-mono text-xs">{URI.to_string(inst.uri)}</td>
                        <td class="py-2">
                          <.badge :for={k <- inst.slice_keys} variant="info" class="mr-1">
                            {k}
                          </.badge>
                        </td>
                        <td class="py-2 text-right pr-2">
                          <a
                            href={"/plugins/auto/" <> Atom.to_string(@kind) <> "/" <> URI.encode_www_form(URI.to_string(inst.uri))}
                            class="text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100 text-xs"
                          >
                            {gettext("detail")} →
                          </a>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </.card>
              </div>

              <div :if={@detail_uri}>
                <.card class="mb-4">
                  <:header>{URI.to_string(@detail_uri)}</:header>
                  <%= case @detail do %>
                    <% nil -> %>
                      <p class="text-zinc-500 italic text-sm">{gettext("Loading…")}</p>
                    <% {:error, reason} -> %>
                      <p class="text-red-700 dark:text-red-300 text-sm">
                        {gettext("Error: %{reason}", reason: inspect(reason))}
                      </p>
                    <% detail when is_map(detail) -> %>
                      <div class="space-y-2">
                        <div>
                          <span class="text-xs uppercase text-zinc-500">
                            {gettext("Kind module")}
                          </span>
                          <code class="block text-xs">{detail.kind_module}</code>
                        </div>
                        <div>
                          <span class="text-xs uppercase text-zinc-500">{gettext("Behaviors")}</span>
                          <ul class="text-xs">
                            <li :for={b <- detail.behaviors}>
                              <code>{b.module}</code> — {Enum.join(b.actions, ", ")}
                            </li>
                          </ul>
                        </div>
                      </div>
                  <% end %>
                </.card>

                <.card :if={is_map(@detail)}>
                  <:header>{gettext("Slices")}</:header>
                  <%= for {slice_key, slice_val} <- (@detail && @detail[:slices]) || %{} do %>
                    <div class="mb-3">
                      <div class="text-xs uppercase text-zinc-500 mb-1">{slice_key}</div>
                      <pre class="text-xs bg-zinc-50 dark:bg-zinc-950 border border-zinc-200 dark:border-zinc-800 rounded p-2 overflow-x-auto"><%= inspect(slice_val, pretty: true) %></pre>
                    </div>
                  <% end %>
                </.card>

                <.card :if={@cascade_detail} id="credential-cascade-panel" class="mt-4">
                  <:header>{gettext("Credential cascade")}</:header>

                  <p
                    :if={@cascade_notice}
                    id="credential-cascade-notice"
                    class="text-xs text-emerald-700 dark:text-emerald-300 mb-3"
                  >
                    {@cascade_notice}
                  </p>
                  <p
                    :if={@cascade_error}
                    id="credential-cascade-error"
                    class="text-xs text-red-700 dark:text-red-300 mb-3"
                  >
                    {@cascade_error}
                  </p>

                  <div class="grid gap-4 lg:grid-cols-2">
                    <section id="cascade-layer-stack">
                      <h3 class="text-xs font-semibold uppercase text-zinc-500 mb-2">
                        {gettext("Layer stack")}
                      </h3>
                      <div class="space-y-1">
                        <div
                          :for={{level, source} <- @cascade_detail.layer_stack}
                          class="flex items-start gap-2 text-xs"
                        >
                          <span class="w-24 shrink-0 text-zinc-500">{level}</span>
                          <code class="break-all">{source || gettext("not selected")}</code>
                        </div>
                      </div>
                    </section>

                    <section id="cascade-credential-source">
                      <h3 class="text-xs font-semibold uppercase text-zinc-500 mb-2">
                        {gettext("Credential source")}
                      </h3>
                      <dl class="text-xs space-y-1">
                        <div class="flex gap-2">
                          <dt class="w-24 shrink-0 text-zinc-500">{gettext("selected")}</dt>
                          <dd>
                            <code class="break-all">
                              {@cascade_detail.credential_source_uri || gettext("none")}
                            </code>
                          </dd>
                        </div>
                        <div class="flex gap-2">
                          <dt class="w-24 shrink-0 text-zinc-500">{gettext("default")}</dt>
                          <dd>
                            <code class="break-all">
                              {@cascade_detail.default_source_uri || gettext("none")}
                            </code>
                          </dd>
                        </div>
                        <div class="flex gap-2">
                          <dt class="w-24 shrink-0 text-zinc-500">{gettext("flavor")}</dt>
                          <dd><code>{@cascade_detail.flavor}</code></dd>
                        </div>
                      </dl>
                    </section>
                  </div>

                  <div
                    id="credential-grant-row"
                    class="mt-4 border-t border-zinc-200 dark:border-zinc-800 pt-3"
                  >
                    <h3 class="text-xs font-semibold uppercase text-zinc-500 mb-2">
                      {gettext("Grant")}
                    </h3>
                    <%= if @cascade_detail.grant do %>
                      <div class="grid gap-1 text-xs">
                        <div>
                          <span class="text-zinc-500">{gettext("status")}</span>
                          <code>{@cascade_detail.grant.status}</code>
                        </div>
                        <div>
                          <span class="text-zinc-500">{gettext("approved by")}</span>
                          <code>{@cascade_detail.grant.approved_by}</code>
                        </div>
                        <div>
                          <span class="text-zinc-500">{gettext("version")}</span>
                          <code>{@cascade_detail.grant.version}</code>
                        </div>
                      </div>
                      <button
                        id="revoke-credential-grant"
                        type="button"
                        phx-click="revoke_credential_grant"
                        class="mt-3 px-3 py-1.5 text-xs rounded-md border border-red-300 dark:border-red-900 text-red-700 dark:text-red-300 hover:bg-red-50 dark:hover:bg-red-950"
                      >
                        {gettext("Revoke grant")}
                      </button>
                    <% else %>
                      <p class="text-xs text-zinc-500">
                        {gettext("No credential grant for this agent.")}
                      </p>
                    <% end %>
                  </div>

                  <.form
                    for={@default_source_form}
                    id="set-default-source-form"
                    phx-submit="set_default_source"
                    class="mt-4 border-t border-zinc-200 dark:border-zinc-800 pt-3 grid gap-2"
                  >
                    <h3 class="text-xs font-semibold uppercase text-zinc-500">
                      {gettext("Set default source")}
                    </h3>
                    <.input
                      type="hidden"
                      name="default_source[owner_uri]"
                      value={@default_source_form.params["owner_uri"]}
                    />
                    <.input
                      type="hidden"
                      name="default_source[workspace_uri]"
                      value={@default_source_form.params["workspace_uri"]}
                    />
                    <.input
                      field={@default_source_form[:flavor]}
                      type="text"
                      label={gettext("Flavor")}
                    />
                    <.input
                      field={@default_source_form[:source_uri]}
                      type="text"
                      label={gettext("Source URI")}
                      class="font-mono"
                    />
                    <button
                      type="submit"
                      class="w-fit px-3 py-1.5 text-xs rounded-md border border-zinc-300 dark:border-zinc-700 hover:bg-zinc-50 dark:hover:bg-zinc-900"
                    >
                      {gettext("Set default source")}
                    </button>
                  </.form>
                </.card>

                <p class="mt-4">
                  <a
                    href={"/plugins/auto/" <> Atom.to_string(@kind)}
                    class="text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100 text-xs"
                  >
                    ← {gettext("back to list")}
                  </a>
                </p>
              </div>
            </div>
          </:main_window>
        </WorkspaceShell.workspace_shell>
      </:body>
    </AppShell.app_shell>
    """
  end
end
