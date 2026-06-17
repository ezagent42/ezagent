defmodule EzagentPluginLiveview.WorkspaceDetailLive do
  @moduledoc """
  /workspaces/:name — single Workspace view.

  Sections:
  1. Header: name + URI + live status
  2. Members: list + add-by-URI form + per-row remove button
  3. Session templates (Phase 4d: read-only; Phase 5 editor)
  4. Routing rules (Phase 4d: read-only; Phase 5 editor)

  Member mutations go through the cap-checked `Ezagent.Workspace.add_member/3`
  and `remove_member/3` (the logged-in caller's caps drive step 5.5 CapBAC,
  SPEC 2026-05-27-capability-action-axis §7 — this route is `:require_entity`)
  — both persist (Store) + dispatch (live Kind) so the UI shows the new
  state immediately AND restart-safe.

  Phase 8c PR-H — inline `style=""` violations replaced with
  `EzagentDomainUi` atoms + Tailwind tokens (Allen 2026-05-20 audit).
  Helper functions that previously returned inline-style strings now
  return Tailwind class strings instead.
  """

  use Phoenix.LiveView
  # i18n (Allen 2026-05-22) — runtime backend reference; no compile-time
  # dep on :ezagent_web.
  use Gettext, backend: EzagentPluginLiveview.Gettext
  alias EzagentDomainUi.AdminShell
  alias EzagentPluginLiveview.AppShell
  alias EzagentPluginLiveview.ConfigForm
  use EzagentDomainUi.Components
  use EzagentDomainUi.Primitives
  import Phoenix.Component

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    case Ezagent.Workspace.Store.get_by_name(name) do
      nil ->
        {:ok,
         socket
         |> assign(:not_found, true)
         |> assign(:name, name)}

      ws ->
        {:ok,
         socket
         |> assign(:not_found, false)
         |> assign(:name, name)
         |> assign(:workspace, ws)
         |> assign(:flash_error, nil)
         # Phase 5 PR 2: selected_class is "<template_name>" for any
         # registered Class implementing Ezagent.UI.Form, or "__json__"
         # for the JSON escape hatch. Default is first registered Class.
         |> assign(:selected_class, default_selected_class())
         |> assign(:form_classes, Ezagent.UI.Form.list_form_classes())
         # V1 UI PR-1 (SPEC §1.2 / §1.5) — add-member uri_picker
         # options. Caller-authorized: UriOptions resolves workspace
         # authority itself. The workspace listed is THIS workspace
         # (ws.uri), not the caller's session workspace.
         |> assign(:member_options, member_uri_options(socket, ws))
         |> assign(:add_form, to_form(%{"member_uri" => ""}, as: "add_member"))
         |> assign(:add_template_form, to_form(%{"tmpl_name" => ""}, as: "add_template"))
         |> assign(
           :registered_template_classes,
           Ezagent.TemplateRegistry.registered_template_names()
         )}
    end
  end

  defp default_selected_class do
    case Ezagent.UI.Form.list_form_classes() do
      [{name, _, _} | _] -> name
      [] -> "__json__"
    end
  end

  # V1 UI PR-1 (SPEC §1.3) — entity options for the add-member
  # `:single` uri_picker, scoped to THIS workspace (`ws.uri`).
  # `UriOptions.entities/2` enforces the caller's authority: a
  # non-system caller viewing a workspace that is not their own gets
  # `[]`. `current_entity_uri` is set by `EzagentWeb.LiveAuth`.
  defp member_uri_options(socket, ws) do
    case Map.get(socket.assigns, :current_entity_uri) do
      %URI{} = caller_uri ->
        Ezagent.UI.UriOptions.entities(caller_uri, ws.uri)

      _ ->
        []
    end
  end

  defp template_class_name(%{"class" => name}) when is_binary(name), do: name
  defp template_class_name(_), do: "—"

  defp template_member_count(%{"members" => m}) when is_list(m), do: length(m)
  defp template_member_count(_), do: 0

  defp template_status(%{"class" => name}) when is_binary(name) do
    case Ezagent.TemplateRegistry.lookup(name) do
      {:ok, _module} -> :class_registered
      :error -> :no_class
    end
  end

  defp template_status(_), do: :no_class_field

  defp template_status_label(:class_registered), do: gettext("Class registered")
  defp template_status_label(:no_class), do: gettext("No Class registered")
  defp template_status_label(:no_class_field), do: gettext("Missing \"class\" field")

  # Phase 8c PR-H — helper now returns Tailwind classes, not inline
  # `style=""` strings. Same green/red semantic mapping as before.
  defp template_status_class(:class_registered),
    do: "text-[11px] text-emerald-600 dark:text-emerald-400"

  defp template_status_class(_),
    do: "text-[11px] text-rose-600 dark:text-rose-400"

  defp tmpl_mode_btn_class(true),
    do:
      "px-3 py-1 bg-blue-600 dark:bg-blue-500 text-white border-none rounded cursor-pointer text-[11px]"

  defp tmpl_mode_btn_class(false),
    do:
      "px-3 py-1 bg-white dark:bg-zinc-900 text-blue-600 dark:text-blue-400 border border-zinc-300 dark:border-zinc-700 rounded cursor-pointer text-[11px]"

  @impl true
  def handle_event("add_member", %{"add_member" => %{"member_uri" => uri_str}}, socket)
      when is_binary(uri_str) and uri_str != "" do
    trimmed = String.trim(uri_str)

    # V1 UI PR-1 (SPEC §1.6) — the uri_picker hidden input is untrusted
    # user-controlled DOM. Revalidate server-side via the SHARED
    # validator: well-formed entity URI, in THIS workspace (or caller
    # has cross-workspace authority). `valid_for?/4` does not require
    # liveness — a member declaration may name a Kind not yet live.
    caller_uri = Map.get(socket.assigns, :current_entity_uri)
    workspace_uri = socket.assigns.workspace.uri

    cond do
      not match?(%URI{}, caller_uri) ->
        {:noreply, assign(socket, :flash_error, gettext("Not signed in."))}

      not Ezagent.UI.UriOptions.valid_for?(caller_uri, workspace_uri, trimmed, [:entity]) ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext(
             "Rejected %{uri} — must be an entity URI in this workspace (%{workspace}). Pick from the list.",
             uri: inspect(trimmed),
             workspace: URI.to_string(workspace_uri)
           )
         )}

      true ->
        # SPEC 2026-05-27-capability-action-axis §7 (codex follow-up): the
        # `/workspaces/:name` route is `:require_entity`, so route through
        # the cap-checked `add_member/3` with the caller's FRESH caps —
        # NOT the `/2` system-loader path (which would authorize the
        # mutation as the trusted loader, bypassing the caller's CapBAC).
        case Ezagent.Workspace.add_member(
               socket.assigns.name,
               Ezagent.URI.new!(trimmed),
               %{caller: caller_uri, caps: Ezagent.Identity.list_caps_for(caller_uri)}
             ) do
          :ok ->
            ws = Ezagent.Workspace.Store.get_by_name(socket.assigns.name)

            {:noreply,
             socket
             |> assign(:workspace, ws)
             |> assign(:member_options, member_uri_options(socket, ws))
             |> assign(:add_form, to_form(%{"member_uri" => ""}, as: "add_member"))
             |> assign(:flash_error, nil)}

          {:error, reason} ->
            {:noreply,
             assign(
               socket,
               :flash_error,
               gettext("add failed: %{reason}", reason: inspect(reason))
             )}
        end
    end
  end

  def handle_event("add_member", _params, socket) do
    {:noreply, assign(socket, :flash_error, gettext("Member URI is required."))}
  end

  # Phase 5 PR 2: Class picker drives form_fields/0 rendering.
  def handle_event("select_template_class", %{"class" => class_name}, socket) do
    {:noreply, assign(socket, :selected_class, class_name)}
  end

  # JSON escape hatch — Class is read from JSON's "class" field.
  def handle_event(
        "add_template",
        %{"add_template" => params},
        %{assigns: %{selected_class: "__json__"}} = socket
      ) do
    tmpl_name = Map.get(params, "tmpl_name", "") |> String.trim()
    json = Map.get(params, "json", "")

    case {tmpl_name, Jason.decode(json)} do
      {"", _} ->
        {:noreply, assign(socket, :flash_error, gettext("template name required"))}

      {_, {:ok, tmpl}} when is_map(tmpl) ->
        do_add_template(socket, tmpl_name, tmpl)

      {_, {:ok, _}} ->
        {:noreply, assign(socket, :flash_error, gettext("JSON must be an object"))}

      {_, {:error, _}} ->
        {:noreply, assign(socket, :flash_error, gettext("invalid JSON"))}
    end
  end

  # Dynamic class-driven form — delegates translation to the Class's
  # form_to_args/1 (or default_form_to_args if not overridden).
  def handle_event(
        "add_template",
        %{"add_template" => params},
        %{assigns: %{selected_class: class_name}} = socket
      ) do
    tmpl_name = Map.get(params, "tmpl_name", "") |> String.trim()

    cond do
      tmpl_name == "" ->
        {:noreply, assign(socket, :flash_error, gettext("template name required"))}

      true ->
        case Ezagent.TemplateRegistry.lookup(class_name) do
          {:ok, class_module} ->
            tmpl =
              if function_exported?(class_module, :form_to_args, 1) do
                class_module.form_to_args(params)
              else
                Ezagent.UI.Form.default_form_to_args(
                  class_module,
                  Map.drop(params, ["tmpl_name"])
                )
              end

            do_add_template(socket, tmpl_name, tmpl)

          :error ->
            {:noreply,
             assign(
               socket,
               :flash_error,
               gettext("no registered Class: %{class}", class: class_name)
             )}
        end
    end
  end

  def handle_event("remove_template", %{"name" => tmpl_name}, socket) do
    case Ezagent.Workspace.remove_template(socket.assigns.name, tmpl_name) do
      :ok ->
        {:noreply,
         socket
         |> assign(:workspace, Ezagent.Workspace.Store.get_by_name(socket.assigns.name))
         |> assign(:flash_error, nil)}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext("remove_template failed: %{reason}", reason: inspect(reason))
         )}
    end
  end

  def handle_event("remove_member", %{"member_uri" => uri_str}, socket) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # with try/rescue keeping the "Bad URI" flash for malformed input.
    case (try do
            {:ok, Ezagent.URI.new!(uri_str)}
          rescue
            ArgumentError -> :error
          end) do
      {:ok, uri} ->
        # SPEC §7 (codex follow-up): cap-checked `remove_member/3` with the
        # caller's fresh caps — the `:require_entity` route must not strip
        # membership via the `/2` system-loader path. Also sweeps the
        # create_session cap (Part B).
        caller_uri = Map.get(socket.assigns, :current_entity_uri)

        case remove_member_cap_checked(socket.assigns.name, uri, caller_uri) do
          :ok ->
            {:noreply,
             socket
             |> assign(:workspace, Ezagent.Workspace.Store.get_by_name(socket.assigns.name))
             |> assign(:flash_error, nil)}

          {:error, reason} ->
            {:noreply,
             assign(
               socket,
               :flash_error,
               gettext("remove failed: %{reason}", reason: inspect(reason))
             )}
        end

      _ ->
        {:noreply, assign(socket, :flash_error, gettext("Bad URI"))}
    end
  end

  # SPEC §7 — cap-checked remove with a fail-closed caller guard. A
  # missing / non-URI caller is rejected rather than silently falling
  # back to the trusted `/2` loader path.
  defp remove_member_cap_checked(name, %URI{} = uri, %URI{} = caller_uri) do
    Ezagent.Workspace.remove_member(name, uri, %{
      caller: caller_uri,
      caps: Ezagent.Identity.list_caps_for(caller_uri)
    })
  end

  defp remove_member_cap_checked(_name, _uri, _caller), do: {:error, :unauthorized}

  # Helpers for handle_event("add_template", ...) — kept below the
  # handle_event/3 clauses so they group contiguously (clause-grouping
  # warning).
  defp do_add_template(socket, tmpl_name, tmpl) do
    case Ezagent.Workspace.add_template(socket.assigns.name, tmpl_name, tmpl) do
      :ok ->
        # Trigger Class.instantiate so the Session goes live immediately
        # (Loader path runs on boot; this is the runtime path).
        _ = trigger_instantiate(socket.assigns.name, tmpl_name, tmpl)

        {:noreply,
         socket
         |> assign(:workspace, Ezagent.Workspace.Store.get_by_name(socket.assigns.name))
         |> assign(:add_template_form, to_form(%{"tmpl_name" => ""}, as: "add_template"))
         |> assign(:flash_error, nil)}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           gettext("add_template failed: %{reason}", reason: inspect(reason))
         )}
    end
  end

  defp trigger_instantiate(workspace_name, tmpl_name, tmpl) do
    workspace_uri = Ezagent.Entity.Workspace.uri_for(workspace_name)

    case tmpl["class"] do
      class_name when is_binary(class_name) ->
        case Ezagent.TemplateRegistry.lookup(class_name) do
          {:ok, class_module} ->
            # PR-3 (domain.agent D2) — operator-create routes through the core
            # contract-boundary wrapper (domain-allocated config_dir TARGET).
            Ezagent.Kind.Template.provision_and_instantiate(
              class_module,
              tmpl_name,
              tmpl,
              workspace_uri
            )

          :error ->
            {:error, {:no_template_class, class_name}}
        end

      _ ->
        {:error, :missing_class}
    end
  end

  # loom 前端集成 — 模板名做成「新标签打开」链接:解析该模板配方的第一个 session URI
  # （类 export `session_uris_for_recipe/3` 时,如 LoomSession），跳到 /sessions?session=…。
  # 类没有这个 callback → 返回 nil → 渲染纯文本。
  defp template_open_url(tmpl_name, %{"class" => class_name} = recipe, %URI{} = ws_uri)
       when is_binary(tmpl_name) and is_binary(class_name) do
    with {:ok, module} <- Ezagent.TemplateRegistry.lookup(class_name),
         true <- function_exported?(module, :session_uris_for_recipe, 3),
         [%URI{} = session_uri | _] <-
           try_session_uris(module, tmpl_name, recipe, ws_uri) do
      "/sessions?session=" <> URI.encode_www_form(URI.to_string(session_uri))
    else
      _ -> nil
    end
  end

  defp template_open_url(_, _, _), do: nil

  defp try_session_uris(module, tmpl_name, recipe, ws_uri) do
    apply(module, :session_uris_for_recipe, [tmpl_name, recipe, ws_uri])
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @impl true
  def render(%{not_found: true} = assigns) do
    # Nested-shell PR-3 — the not-found page is still an admin surface;
    # wrap it in AppShell.app_shell (perspective :admin) over
    # AdminShell.admin_shell so it carries the universal chrome.
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        Ezagent.URI.stable_key(assigns.current_entity_uri || Ezagent.Entity.User.admin_uri())
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
        <AdminShell.admin_shell current_path="/workspaces" active_section={:workspaces}>
          <:main>
            <div class="max-w-3xl mx-auto px-6 py-6 text-zinc-900 dark:text-zinc-100">
              <.page_header title={gettext("Workspace not found")} />
              <p>{gettext("No persisted workspace named")} <code>{@name}</code>.</p>
              <p>
                <a
                  href="/workspaces"
                  class="text-blue-600 dark:text-blue-400 hover:text-blue-700"
                >
                  ← {gettext("Workspaces")}
                </a>
              </p>
            </div>
          </:main>
        </AdminShell.admin_shell>
      </:body>
    </AppShell.app_shell>
    """
  end

  def render(assigns) do
    # Nested-shell PR-3 — wrap in AppShell.app_shell (perspective :admin)
    # over AdminShell.admin_shell. Workspace MANAGEMENT (templates /
    # members / routing config) is a configuration surface, not a
    # workflow surface; it now gains the universal chrome.
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        Ezagent.URI.stable_key(assigns.current_entity_uri || Ezagent.Entity.User.admin_uri())
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
        <AdminShell.admin_shell
          current_path={"/workspaces/" <> @workspace.name}
          active_section={:workspaces}
        >
          <:main>
            <div class="flex-1 overflow-auto px-6 py-6 text-zinc-900 dark:text-zinc-100">
              <a
                href="/workspaces"
                class="inline-flex items-center gap-1 text-xs text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100 mb-4"
              >
                <.icon name="chevron-left" size="xs" />
                <span>{gettext("All workspaces")}</span>
              </a>
              <%!--
            Phase 8c PR-H: NOT using `<.page_header>` here because the page
            title contains a `<code>` child — a test (workspaces_live_test
            "detail page shows existing workspace + members section")
            asserts the literal string `Workspace: <code>NAME</code>`.
            The page_header atom takes a plain `:title` attr and can't host
            a child element. We use the same h1 classes the atom uses
            internally so the visual stays consistent with the atom layer.
          --%>
              <div class="flex items-end justify-between mb-6 pb-4 border-b border-zinc-200 dark:border-zinc-800">
                <div>
                  <h1 class="text-xl font-semibold text-zinc-900 dark:text-zinc-100">
                    {gettext("Workspace:")} <code>{@workspace.name}</code>
                  </h1>
                  <p class="mt-1 text-sm text-zinc-500">
                    <code>{URI.to_string(@workspace.uri)}</code>
                  </p>
                </div>
              </div>

              <.card id="members" class="mt-6">
                <h2 class="text-sm font-medium mb-3 text-zinc-900 dark:text-zinc-100">
                  {gettext("Members (%{count})", count: length(@workspace.members))}
                </h2>

                <p :if={@workspace.members == []} id="members-empty" class="text-zinc-500 italic">
                  {gettext(
                    "No members. Add one below to declare a Kind that should be alive whenever this Workspace is loaded."
                  )}
                </p>

                <ul :if={@workspace.members != []} id="members-list" class="list-none p-0 m-0">
                  <li
                    :for={member <- @workspace.members}
                    class="flex items-center py-1.5 border-b border-zinc-100 dark:border-zinc-900"
                  >
                    <code class="flex-1 text-xs">{URI.to_string(member)}</code>
                    <.button
                      variant="outline"
                      size="sm"
                      type="button"
                      phx-click="remove_member"
                      phx-value-member_uri={URI.to_string(member)}
                      class="text-rose-600 dark:text-rose-400 border-rose-600 dark:border-rose-400 hover:bg-rose-50 dark:hover:bg-rose-950 text-[11px]"
                      data-confirm={gettext("Remove this member?")}
                    >
                      {gettext("Remove")}
                    </.button>
                  </li>
                </ul>

                <%!--
              V1 UI PR-1 (SPEC §1.2 / §1.4) — :single uri_picker over
              in-workspace entities. allow_freetext ON so an operator
              can declare a member Kind not yet live (a member is a
              declaration of what should be alive when the workspace
              loads). Submits add_member[member_uri] as a string.
            --%>
                <.form for={@add_form} phx-submit="add_member" class="flex gap-2 mt-4 items-start">
                  <div class="flex-1">
                    <.uri_picker
                      name="add_member[member_uri]"
                      mode={:single}
                      kinds={[:entity]}
                      options={@member_options}
                      allow_freetext={true}
                      placeholder={gettext("pick an entity to add as a member")}
                    />
                  </div>
                  <.button type="submit" variant="primary" size="sm">{gettext("Add member")}</.button>
                </.form>
                <p :if={@flash_error} class="text-rose-600 dark:text-rose-400 text-xs mt-2">
                  {@flash_error}
                </p>
              </.card>

              <.card id="templates" class="mt-6">
                <h2 class="text-sm font-medium mb-1 text-zinc-900 dark:text-zinc-100">
                  {gettext("Spawn-template registrations (%{count})",
                    count: map_size(@workspace.session_templates)
                  )}
                </h2>
                <%!--
              G-12 partial (audit 2026-05-23) — distinguish the legacy
              `Workspace.Store.session_templates` map (Phase-4d
              spawn-template REGISTRATIONS like cc.agent / echo.agent)
              from Phase-7 SessionTemplate KINDS. Phase-7 templates
              live in their own surface — link to it so operators
              don't conflate the two.
            --%>
                <p class="text-[11px] text-zinc-500 mb-3">
                  {gettext(
                    "These are Template Class registrations (cc.agent, echo.agent, …) — the recipes used when an agent is created in this workspace. NOT the Phase-7 SessionTemplate Kinds."
                  )}
                  <a
                    href="/admin/templates?type=session_template"
                    class="ml-1 text-sky-700 dark:text-sky-300 hover:underline"
                  >
                    {gettext("View SessionTemplate Kinds →")}
                  </a>
                </p>
                <p
                  :if={@workspace.session_templates == %{}}
                  id="templates-empty"
                  class="text-zinc-500 italic"
                >
                  {gettext("No session templates declared.")}
                </p>
                <table
                  :if={@workspace.session_templates != %{}}
                  id="templates-table"
                  class="w-full text-xs border-collapse"
                >
                  <thead>
                    <tr class="border-b border-zinc-200 dark:border-zinc-800">
                      <th class="text-left px-1 py-1.5">{gettext("Name")}</th>
                      <th class="text-left">{gettext("Class")}</th>
                      <th class="text-left">{gettext("Members")}</th>
                      <th class="text-left">{gettext("Status")}</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={{tmpl_name, tmpl_data} <- @workspace.session_templates}
                      class="border-b border-zinc-100 dark:border-zinc-900"
                    >
                      <td class="px-1 py-1 font-medium">
                        <% open_url = template_open_url(tmpl_name, tmpl_data, @workspace.uri) %>
                        <%= if open_url do %>
                          <a
                            href={open_url}
                            target="_blank"
                            rel="noopener"
                            class="text-sky-700 dark:text-sky-300 hover:underline"
                            title={gettext("Open in new tab")}
                          >
                            {tmpl_name}
                          </a>
                        <% else %>
                          {tmpl_name}
                        <% end %>
                      </td>
                      <td class="font-mono text-[11px]">{template_class_name(tmpl_data)}</td>
                      <td>{template_member_count(tmpl_data)}</td>
                      <td class={template_status_class(template_status(tmpl_data))}>
                        {template_status_label(template_status(tmpl_data))}
                      </td>
                      <td>
                        <.button
                          variant="outline"
                          size="sm"
                          type="button"
                          phx-click="remove_template"
                          phx-value-name={tmpl_name}
                          class="text-rose-600 dark:text-rose-400 border-rose-600 dark:border-rose-400 hover:bg-rose-50 dark:hover:bg-rose-950 text-[10px] px-2 py-0.5 h-auto"
                          data-confirm={
                            gettext("Remove this template? (already-spawned Kinds stay alive)")
                          }
                        >
                          {gettext("Remove")}
                        </.button>
                      </td>
                    </tr>
                  </tbody>
                </table>
                <p
                  :if={@registered_template_classes != []}
                  id="registered-classes"
                  class="mt-3 text-[11px] text-zinc-500"
                >
                  {gettext("Registered Template Classes:")}
                  <code>{Enum.join(@registered_template_classes, ", ")}</code>
                </p>

                <div id="add-template" class="mt-4 pt-4 border-t border-zinc-200 dark:border-zinc-800">
                  <h3 class="text-[13px] font-medium mb-2 text-zinc-900 dark:text-zinc-100">
                    {gettext("Add template")}
                  </h3>

                  <p class="text-[11px] text-zinc-500 mb-2">
                    {gettext(
                      "Class picker drives the form below — each registered Template Class self-describes its fields via Ezagent.UI.Form.form_fields/0. JSON mode is the escape hatch for custom Classes that don't implement the form behaviour."
                    )}
                  </p>

                  <div class="mb-3 flex gap-1.5 flex-wrap">
                    <button
                      :for={{class_name, _module, _fields} <- @form_classes}
                      type="button"
                      phx-click="select_template_class"
                      phx-value-class={class_name}
                      class={tmpl_mode_btn_class(@selected_class == class_name)}
                    >
                      {class_name}
                    </button>
                    <button
                      type="button"
                      phx-click="select_template_class"
                      phx-value-class="__json__"
                      class={tmpl_mode_btn_class(@selected_class == "__json__")}
                    >
                      {gettext("JSON (custom class)")}
                    </button>
                  </div>

                  <.form for={@add_template_form} phx-submit="add_template">
                    <div class="grid grid-cols-[200px_1fr] gap-1.5 mb-3">
                      <input
                        type="text"
                        name="add_template[tmpl_name]"
                        placeholder={gettext("template name (e.g. main)")}
                        class="px-2 py-1 border border-zinc-300 dark:border-zinc-700 rounded text-xs bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
                      />
                      <span class="text-[11px] text-zinc-500 self-center">
                        {gettext("Class =")} <code>{@selected_class}</code>
                      </span>
                    </div>

                    <%= if @selected_class == "__json__" do %>
                      <div class="mb-2">
                        <textarea
                          name="add_template[json]"
                          rows="5"
                          placeholder={~s({"class":"some.class","field":"value"})}
                          class="w-full px-2.5 py-1.5 border border-zinc-300 dark:border-zinc-700 rounded font-mono text-[11px] bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
                        ></textarea>
                        <p class="text-[10px] text-zinc-500 mt-1">
                          {gettext(
                            "Full template JSON — \"class\" field must reference a registered Class."
                          )}
                        </p>
                      </div>
                    <% else %>
                      <% selected_fields =
                        Enum.find_value(@form_classes, [], fn {n, _m, fields} ->
                          if n == @selected_class, do: fields
                        end) %>

                      <ConfigForm.config_fields fields={selected_fields} name_prefix="add_template" />
                    <% end %>

                    <.button type="submit" variant="success" size="sm">
                      {gettext("Add template")}
                    </.button>
                  </.form>
                </div>
              </.card>

              <.card id="routing-rules" class="mt-6">
                <h2 class="text-sm font-medium mb-3 text-zinc-900 dark:text-zinc-100">
                  {gettext("Routing rules (%{count})", count: length(@workspace.routing_rules))}
                  <span class="text-[11px] text-zinc-500 font-normal">
                    {gettext("(read-only — Phase 5 editor)")}
                  </span>
                </h2>
                <p :if={@workspace.routing_rules == []} id="rules-empty" class="text-zinc-500 italic">
                  {gettext("No routing rules declared.")}
                </p>
                <pre
                  :if={@workspace.routing_rules != []}
                  id="rules-json"
                  class="bg-zinc-100 dark:bg-zinc-900 p-3 rounded overflow-x-auto text-[11px] font-mono text-zinc-900 dark:text-zinc-100"
                >{Jason.encode!(@workspace.routing_rules, pretty: true)}</pre>
              </.card>
            </div>
          </:main>
        </AdminShell.admin_shell>
      </:body>
    </AppShell.app_shell>
    """
  end
end
