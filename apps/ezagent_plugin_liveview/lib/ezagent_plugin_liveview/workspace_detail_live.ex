defmodule EzagentPluginLiveview.WorkspaceDetailLive do
  @moduledoc """
  /workspaces/:name — single Workspace view.

  Sections:
  1. Header: name + URI + live status
  2. Members: list + add-by-URI form + per-row remove button
  3. Session templates (Phase 4d: read-only; Phase 5 editor)
  4. Routing rules (Phase 4d: read-only; Phase 5 editor)

  Member mutations go through `Ezagent.Workspace.add_member/2` and
  `remove_member/2` — both persist (Store) + dispatch (live Kind) so
  the UI shows the new state immediately AND restart-safe.

  Phase 8c PR-H — inline `style=""` violations replaced with
  `EzagentDomainUi` atoms + Tailwind tokens (Allen 2026-05-20 audit).
  Helper functions that previously returned inline-style strings now
  return Tailwind class strings instead.
  """

  use Phoenix.LiveView
  alias EzagentDomainUi.AdminSettingsShell
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

  defp template_status_label(:class_registered), do: "Class registered"
  defp template_status_label(:no_class), do: "No Class registered"
  defp template_status_label(:no_class_field), do: "Missing \"class\" field"

  # Phase 8c PR-H — helper now returns Tailwind classes, not inline
  # `style=""` strings. Same green/red semantic mapping as before.
  defp template_status_class(:class_registered),
    do: "text-[11px] text-emerald-600 dark:text-emerald-400"

  defp template_status_class(_),
    do: "text-[11px] text-rose-600 dark:text-rose-400"

  defp input_class_for(:path),
    do:
      "px-2 py-1 border border-zinc-300 dark:border-zinc-700 rounded text-xs font-mono bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"

  defp input_class_for(:uri),
    do:
      "px-2 py-1 border border-zinc-300 dark:border-zinc-700 rounded text-xs font-mono bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"

  defp input_class_for(_),
    do:
      "px-2 py-1 border border-zinc-300 dark:border-zinc-700 rounded text-xs bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"

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
        {:noreply, assign(socket, :flash_error, "Not signed in.")}

      not Ezagent.UI.UriOptions.valid_for?(caller_uri, workspace_uri, trimmed, [:entity]) ->
        {:noreply,
         assign(
           socket,
           :flash_error,
           "Rejected #{inspect(trimmed)} — must be an entity URI in this workspace " <>
             "(#{URI.to_string(workspace_uri)}). Pick from the list."
         )}

      true ->
        case Ezagent.Workspace.add_member(socket.assigns.name, Ezagent.URI.parse!(trimmed)) do
          :ok ->
            ws = Ezagent.Workspace.Store.get_by_name(socket.assigns.name)

            {:noreply,
             socket
             |> assign(:workspace, ws)
             |> assign(:member_options, member_uri_options(socket, ws))
             |> assign(:add_form, to_form(%{"member_uri" => ""}, as: "add_member"))
             |> assign(:flash_error, nil)}

          {:error, reason} ->
            {:noreply, assign(socket, :flash_error, "add failed: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("add_member", _params, socket) do
    {:noreply, assign(socket, :flash_error, "Member URI is required.")}
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
        {:noreply, assign(socket, :flash_error, "template name required")}

      {_, {:ok, tmpl}} when is_map(tmpl) ->
        do_add_template(socket, tmpl_name, tmpl)

      {_, {:ok, _}} ->
        {:noreply, assign(socket, :flash_error, "JSON must be an object")}

      {_, {:error, _}} ->
        {:noreply, assign(socket, :flash_error, "invalid JSON")}
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
        {:noreply, assign(socket, :flash_error, "template name required")}

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
            {:noreply, assign(socket, :flash_error, "no registered Class: #{class_name}")}
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
        {:noreply, assign(socket, :flash_error, "remove_template failed: #{inspect(reason)}")}
    end
  end

  def handle_event("remove_member", %{"member_uri" => uri_str}, socket) do
    case URI.new(uri_str) do
      {:ok, uri} ->
        case Ezagent.Workspace.remove_member(socket.assigns.name, uri) do
          :ok ->
            {:noreply,
             socket
             |> assign(:workspace, Ezagent.Workspace.Store.get_by_name(socket.assigns.name))
             |> assign(:flash_error, nil)}

          {:error, reason} ->
            {:noreply, assign(socket, :flash_error, "remove failed: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, assign(socket, :flash_error, "Bad URI")}
    end
  end

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
        {:noreply, assign(socket, :flash_error, "add_template failed: #{inspect(reason)}")}
    end
  end

  defp trigger_instantiate(workspace_name, tmpl_name, tmpl) do
    workspace_uri = Ezagent.Entity.Workspace.uri_for(workspace_name)

    case tmpl["class"] do
      class_name when is_binary(class_name) ->
        case Ezagent.TemplateRegistry.lookup(class_name) do
          {:ok, class_module} ->
            class_module.instantiate(tmpl_name, tmpl, workspace_uri)

          :error ->
            {:error, {:no_template_class, class_name}}
        end

      _ ->
        {:error, :missing_class}
    end
  end

  @impl true
  def render(%{not_found: true} = assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto px-6 py-6 text-zinc-900 dark:text-zinc-100">
      <.page_header title="Workspace not found" />
      <p>No persisted workspace named <code>{@name}</code>.</p>
      <p>
        <a href="/workspaces" class="text-blue-600 dark:text-blue-400 hover:text-blue-700">
          ← Workspaces
        </a>
      </p>
    </div>
    """
  end

  def render(assigns) do
    # PR-M (Allen 2026-05-20) — wrap in AdminSettingsShell (drawer
    # perspective). Workspace MANAGEMENT (templates / members / routing
    # config) is a configuration surface, not a workflow surface.
    assigns =
      assign_new(assigns, :current_entity_uri_str, fn ->
        URI.to_string(assigns.current_entity_uri || URI.parse("entity://user/system/admin"))
      end)

    ~H"""
    <AdminSettingsShell.admin_settings_shell
      current_entity_uri={@current_entity_uri_str}
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
            <span>All workspaces</span>
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
                Workspace: <code>{@workspace.name}</code>
              </h1>
              <p class="mt-1 text-sm text-zinc-500">
                <code>{URI.to_string(@workspace.uri)}</code>
              </p>
            </div>
          </div>

          <.card id="members" class="mt-6">
            <h2 class="text-sm font-medium mb-3 text-zinc-900 dark:text-zinc-100">
              Members ({length(@workspace.members)})
            </h2>

            <p :if={@workspace.members == []} id="members-empty" class="text-zinc-500 italic">
              No members. Add one below to declare a Kind that should be alive
              whenever this Workspace is loaded.
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
                  data-confirm="Remove this member?"
                >
                  Remove
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
                  placeholder="pick an entity to add as a member"
                />
              </div>
              <.button type="submit" variant="primary" size="sm">Add member</.button>
            </.form>
            <p :if={@flash_error} class="text-rose-600 dark:text-rose-400 text-xs mt-2">
              {@flash_error}
            </p>
          </.card>

          <.card id="templates" class="mt-6">
            <h2 class="text-sm font-medium mb-3 text-zinc-900 dark:text-zinc-100">
              Session templates ({map_size(@workspace.session_templates)})
            </h2>
            <p
              :if={@workspace.session_templates == %{}}
              id="templates-empty"
              class="text-zinc-500 italic"
            >
              No session templates declared.
            </p>
            <table
              :if={@workspace.session_templates != %{}}
              id="templates-table"
              class="w-full text-xs border-collapse"
            >
              <thead>
                <tr class="border-b border-zinc-200 dark:border-zinc-800">
                  <th class="text-left px-1 py-1.5">Name</th>
                  <th class="text-left">Class</th>
                  <th class="text-left">Members</th>
                  <th class="text-left">Status</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={{tmpl_name, tmpl_data} <- @workspace.session_templates}
                  class="border-b border-zinc-100 dark:border-zinc-900"
                >
                  <td class="px-1 py-1 font-medium">{tmpl_name}</td>
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
                      data-confirm="Remove this template? (already-spawned Kinds stay alive)"
                    >
                      Remove
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
              Registered Template Classes:
              <code>{Enum.join(@registered_template_classes, ", ")}</code>
            </p>

            <div id="add-template" class="mt-4 pt-4 border-t border-zinc-200 dark:border-zinc-800">
              <h3 class="text-[13px] font-medium mb-2 text-zinc-900 dark:text-zinc-100">
                Add template
              </h3>

              <p class="text-[11px] text-zinc-500 mb-2">
                Class picker drives the form below — each registered Template Class self-describes its
                fields via <code>Ezagent.UI.Form.form_fields/0</code>. JSON mode is the escape hatch for
                custom Classes that don't implement the form behaviour.
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
                  JSON (custom class)
                </button>
              </div>

              <.form for={@add_template_form} phx-submit="add_template">
                <div class="grid grid-cols-[200px_1fr] gap-1.5 mb-3">
                  <input
                    type="text"
                    name="add_template[tmpl_name]"
                    placeholder="template name (e.g. main)"
                    class="px-2 py-1 border border-zinc-300 dark:border-zinc-700 rounded text-xs bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
                  />
                  <span class="text-[11px] text-zinc-500 self-center">
                    Class = <code>{@selected_class}</code>
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
                      Full template JSON — "class" field must reference a registered Class.
                    </p>
                  </div>
                <% else %>
                  <% selected_fields =
                    Enum.find_value(@form_classes, [], fn {n, _m, fields} ->
                      if n == @selected_class, do: fields
                    end) %>

                  <div
                    :for={field <- selected_fields}
                    class="grid grid-cols-[200px_1fr] gap-1.5 mb-2"
                  >
                    <label class="text-xs text-zinc-500 self-center">
                      {field.label}{if Map.get(field, :required, false), do: " *", else: ""}
                    </label>
                    <%= case field.type do %>
                      <% :select -> %>
                        <select
                          name={"add_template[" <> field.name <> "]"}
                          class="px-2 py-1 border border-zinc-300 dark:border-zinc-700 rounded text-xs font-mono bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
                        >
                          <option :for={opt <- Map.get(field, :options, [])} value={opt}>
                            {opt}
                          </option>
                        </select>
                      <% :path -> %>
                        <div class="flex flex-col gap-0.5">
                          <input
                            type="text"
                            name={"add_template[" <> field.name <> "]"}
                            placeholder={Map.get(field, :placeholder, "/path/to/dir")}
                            class={input_class_for(field.type)}
                          />
                          <span class="text-[10px] text-zinc-500">
                            📁 Filesystem path (server-side)
                          </span>
                        </div>
                      <% _ -> %>
                        <input
                          type="text"
                          name={"add_template[" <> field.name <> "]"}
                          placeholder={Map.get(field, :placeholder, "")}
                          class={input_class_for(field.type)}
                        />
                    <% end %>
                  </div>
                <% end %>

                <.button type="submit" variant="success" size="sm">Add template</.button>
              </.form>
            </div>
          </.card>

          <.card id="routing-rules" class="mt-6">
            <h2 class="text-sm font-medium mb-3 text-zinc-900 dark:text-zinc-100">
              Routing rules ({length(@workspace.routing_rules)})
              <span class="text-[11px] text-zinc-500 font-normal">(read-only — Phase 5 editor)</span>
            </h2>
            <p :if={@workspace.routing_rules == []} id="rules-empty" class="text-zinc-500 italic">
              No routing rules declared.
            </p>
            <pre
              :if={@workspace.routing_rules != []}
              id="rules-json"
              class="bg-zinc-100 dark:bg-zinc-900 p-3 rounded overflow-x-auto text-[11px] font-mono text-zinc-900 dark:text-zinc-100"
            >{Jason.encode!(@workspace.routing_rules, pretty: true)}</pre>
          </.card>
        </div>
      </:main>
    </AdminSettingsShell.admin_settings_shell>
    """
  end
end
