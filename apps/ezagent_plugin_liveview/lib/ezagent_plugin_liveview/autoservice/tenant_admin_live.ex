defmodule EzagentPluginLiveview.AutoService.TenantAdminLive do
  @moduledoc """
  Tenant content-admin console -- `/autoservice/admin`.

  Ported from PR #731's `EzagentPluginAutoservice.Admin.TenantAdminLive`,
  rewired to the AutoService v2 (autoservice-dev) content + CR APIs. The
  panels keep #731's structure/UX but every data call goes through dev's
  modules (`EzagentPluginContent.*` + `EzagentPluginCr.CrEngine`), NOT
  #731's TenantContent/TenantPaths/Publisher (which do not exist here).

  ## dev's content model (why the panels differ from #731)

  dev's soul model is **fixed templates + editable slot VALUES**:
  `souls = SoulLoader.load(...)` (read-only templates with `{{key}}`
  placeholders) rendered against editable `slot_values` (per-role YAML in
  the tenant sandbox). There is **no raw-soul write API**, so #731's
  "Soul 编辑" panel (which wrote `sandbox/souls/customer.md` verbatim) is
  DROPPED and replaced by a **Slots** panel that edits the slot values.

  ## Panels

  - **Slots** (editable): `SoulStore.read_slots/4` / `write_slots/5`
    against `(base_dir, tid, role, :sandbox)`. Edited as YAML in a
    textarea; "保存" parses the YAML to a map (bad YAML → flash, no
    write) and merges it into the sandbox slot file. Sandbox-only.

  - **Skills** (editable): lists the tenant-layer sandbox skill files via
    `SkillLoader.list/4` and lets the admin open/edit/save a single
    skill's `SKILL.md` via `SkillStore.read/5` + `write/5`. Sandbox-only.

  - **Preview** (inline render, no agent): `SoulLoader.load/3` +
    `SoulRenderer.full_claude_md/3` render the sandbox slot values against
    the soul templates into a `<pre>`. No agent spawn.

  - **CR / Publish**: `CrEngine.ensure_active_cr/1` (on mount) shows the
    active CR (`"cr_id"` / `"status"` / `"published_version"`).
    `CrLint.check/1` shows lint results. "[发布]" calls
    `CrEngine.publish/1` (which lints + snapshots + flips `_current`);
    on `{:ok, cr}` flashes the published version, on `{:error, reasons}`
    flashes the lint/error reasons. Release content only ever changes via
    `CrEngine.publish/1` -- this LV never writes release directly.

  ## Cap gate (server-side, mirrors #731)

  dev's `Roles.bundle(:admin, ws)` grants **workspace management** caps
  (`kind: :workspace`, `behavior: Ezagent.Behavior.Workspace`,
  `action: :any`) -- NOT a `content:write` cap (that does not exist on
  this branch). So `can_write?` checks for the workspace-admin cap scoped
  to the current workspace (or `:any`). Every write/publish
  `handle_event` re-checks `can_write?` server-side and early-returns with
  a flash if absent (NOT just disabled buttons). When the entity lacks the
  cap the panels render read-only with a notice.

  ## Wiring convention

  Like the sibling `Tenant.CrDashboardLive`, this LV lives in
  `ezagent_plugin_liveview` which deliberately does NOT take a compile-time
  dep on `ezagent_plugin_content` / `ezagent_plugin_cr` (avoids dep churn /
  cycles). Cross-plugin calls therefore go through runtime
  `Code.ensure_loaded?/1` + `apply/3` guards, degrading gracefully if a
  plugin is absent.
  """

  use Phoenix.LiveView
  import Phoenix.Component

  # Role whose slots/skills/soul this console edits. dev's customer path
  # provisions the slow agent with `role = "slow"` (see
  # EzagentPluginAutoservice.CustomerSession: `Keyword.get(opts, :role, "slow")`).
  @role "slow"

  # ---------------------------------------------------------------------------
  # mount/3
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    admin_uri = socket.assigns.current_entity_uri
    workspace_uri = socket.assigns.current_workspace_uri
    # `current_caps` is set by EzagentWeb.LiveAuth :require_entity on_mount.
    caps = Map.get(socket.assigns, :current_caps, [])
    can_write? = admin_cap?(caps, workspace_uri)

    tid = tid_from_workspace(workspace_uri)

    {:ok,
     socket
     |> assign(:page_title, "租户内容管理")
     |> assign(:admin_uri, admin_uri)
     |> assign(:workspace_uri, workspace_uri)
     |> assign(:tid, tid)
     |> assign(:role, @role)
     |> assign(:can_write?, can_write?)
     # Slots panel
     |> assign(:slots_yaml, load_slots_yaml(tid))
     |> assign(:slots_saved_flash, nil)
     # Skills panel
     |> assign(:skills, list_skills(tid))
     |> assign(:selected_skill, nil)
     |> assign(:skill_content, nil)
     |> assign(:skill_saved_flash, nil)
     # CR panel
     |> assign(:cr_info, load_cr_info(tid))
     |> assign(:lint_results, load_lint_results(tid))
     |> assign(:publish_flash, nil)
     |> assign(:publish_flash_type, :info)
     # Preview panel
     |> assign(:preview_content, nil)}
  end

  # ---------------------------------------------------------------------------
  # handle_event — writes (all cap-gated server-side)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("save_slots", %{"slots" => yaml}, socket) do
    if socket.assigns.can_write? do
      case parse_yaml_map(yaml) do
        {:ok, values} ->
          case write_slots(socket.assigns.tid, socket.assigns.role, values) do
            :ok ->
              {:noreply,
               socket
               |> assign(:slots_yaml, yaml)
               |> assign(:slots_saved_flash, "已保存")}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "保存失败: #{inspect(reason)}")}
          end

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "YAML 格式错误: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "无权限")}
    end
  end

  def handle_event("open_skill", %{"name" => name}, socket) do
    content =
      case read_skill(socket.assigns.tid, socket.assigns.role, name) do
        {:ok, c} -> c
        :not_found -> ""
      end

    {:noreply,
     socket
     |> assign(:selected_skill, name)
     |> assign(:skill_content, content)
     |> assign(:skill_saved_flash, nil)}
  end

  def handle_event("save_skill", %{"content" => content}, socket) do
    name = socket.assigns.selected_skill

    cond do
      !socket.assigns.can_write? ->
        {:noreply, put_flash(socket, :error, "无权限")}

      is_nil(name) ->
        {:noreply, put_flash(socket, :error, "未选择 skill")}

      true ->
        case write_skill(socket.assigns.tid, socket.assigns.role, name, content) do
          :ok ->
            {:noreply,
             socket
             |> assign(:skill_content, content)
             |> assign(:skills, list_skills(socket.assigns.tid))
             |> assign(:skill_saved_flash, "已保存")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "保存失败: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("publish", _params, socket) do
    if socket.assigns.can_write? do
      tid = socket.assigns.tid

      case publish_cr(tid) do
        {:ok, cr} ->
          version = cr["published_version"] || "?"

          {:noreply,
           socket
           |> assign(:cr_info, cr)
           |> assign(:lint_results, load_lint_results(tid))
           |> assign(:publish_flash, "发布成功 v#{version}")
           |> assign(:publish_flash_type, :ok)}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:lint_results, load_lint_results(tid))
           |> assign(:publish_flash, "发布失败: #{format_publish_error(reason)}")
           |> assign(:publish_flash_type, :error)}
      end
    else
      {:noreply, put_flash(socket, :error, "无权限")}
    end
  end

  # ---------------------------------------------------------------------------
  # handle_event — reads (no cap gate)
  # ---------------------------------------------------------------------------

  def handle_event("preview", _params, socket) do
    {:noreply,
     assign(socket, :preview_content, render_preview(socket.assigns.tid, socket.assigns.role))}
  end

  def handle_event("refresh_lint", _params, socket) do
    {:noreply, assign(socket, :lint_results, load_lint_results(socket.assigns.tid))}
  end

  @impl true
  def handle_info(_other, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Cap gate — admin workspace cap (mirrors Roles.bundle(:admin, ws))
  # ---------------------------------------------------------------------------

  @doc """
  Whether `caps` contains a workspace-admin cap scoped to `workspace_uri`
  (or `:any`). Matches `EzagentPluginAutoservice.Roles.bundle(:admin, ws)`,
  which grants `kind: :workspace`, `behavior: Ezagent.Behavior.Workspace`,
  `action: :any`. Exposed for unit testing the gate.
  """
  @spec admin_cap?([map()], URI.t() | nil) :: boolean()
  def admin_cap?(caps, workspace_uri) when is_list(caps) do
    Enum.any?(caps, fn cap ->
      Map.get(cap, :kind) == :workspace and
        Map.get(cap, :behavior) == Ezagent.Behavior.Workspace and
        Map.get(cap, :action) in [:any, :create_agent, :set_routing_rules] and
        workspace_scope_matches?(Map.get(cap, :workspace_uri), workspace_uri)
    end)
  end

  def admin_cap?(_caps, _workspace_uri), do: false

  defp workspace_scope_matches?(:any, _), do: true
  defp workspace_scope_matches?(%URI{} = a, %URI{} = b), do: a == b
  defp workspace_scope_matches?(_, _), do: false

  # ---------------------------------------------------------------------------
  # tid / workspace
  # ---------------------------------------------------------------------------

  defp tid_from_workspace(%URI{} = workspace_uri) do
    case Ezagent.URI.workspace_name(workspace_uri) do
      {:ok, name} -> name
      :error -> nil
    end
  end

  defp tid_from_workspace(_), do: nil

  # ---------------------------------------------------------------------------
  # Content base_dir resolution
  #
  # dev's content APIs take TWO different base-dir conventions:
  #   - SoulStore/SoulLoader/CrLint: base = TenantRuntime.base_dir()
  #     (".../tenants"); they join `[base, tid, ...]` directly.
  #   - SkillStore/SkillLoader: they append "tenants" themselves, so they
  #     need base = Path.dirname(TenantRuntime.base_dir())
  #     ("~/.ezagent/default").
  # ---------------------------------------------------------------------------

  defp content_base_dir do
    mod = EzagentPluginContent.Tenant.TenantRuntime

    if Code.ensure_loaded?(mod) and function_exported?(mod, :base_dir, 0) do
      apply(mod, :base_dir, [])
    else
      nil
    end
  end

  # Base dir for the SkillStore/SkillLoader convention.
  defp skill_base_dir do
    case content_base_dir() do
      nil -> nil
      base -> Path.dirname(base)
    end
  end

  defp priv_dir do
    case :code.priv_dir(:ezagent_plugin_content) do
      {:error, _} -> nil
      dir -> to_string(dir)
    end
  rescue
    _ -> nil
  end

  # ---------------------------------------------------------------------------
  # Slots
  # ---------------------------------------------------------------------------

  defp load_slots_yaml(nil), do: ""

  defp load_slots_yaml(tid) do
    mod = EzagentPluginContent.Soul.SoulStore
    base = content_base_dir()

    with true <- not is_nil(base),
         true <- Code.ensure_loaded?(mod) and function_exported?(mod, :read_slots, 4),
         {:ok, values} <- apply(mod, :read_slots, [base, tid, @role, :sandbox]) do
      map_to_yaml(values)
    else
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp write_slots(nil, _role, _values), do: {:error, :no_tenant}

  defp write_slots(tid, role, values) do
    mod = EzagentPluginContent.Soul.SoulStore
    base = content_base_dir()

    cond do
      is_nil(base) ->
        {:error, :content_unavailable}

      Code.ensure_loaded?(mod) and function_exported?(mod, :write_slots, 5) ->
        apply(mod, :write_slots, [base, tid, role, values, :sandbox])

      true ->
        {:error, :content_unavailable}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # Skills
  # ---------------------------------------------------------------------------

  defp list_skills(nil), do: []

  defp list_skills(tid) do
    mod = EzagentPluginContent.Skill.SkillLoader
    base = skill_base_dir()

    with true <- not is_nil(base),
         true <- Code.ensure_loaded?(mod) and function_exported?(mod, :list, 4) do
      apply(mod, :list, [base, tid, @role, :tenant])
      |> Enum.map(& &1.name)
      |> Enum.sort()
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp read_skill(nil, _role, _name), do: :not_found

  defp read_skill(tid, role, name) do
    mod = EzagentPluginContent.Skill.SkillStore
    base = skill_base_dir()

    cond do
      is_nil(base) ->
        :not_found

      Code.ensure_loaded?(mod) and function_exported?(mod, :read, 4) ->
        apply(mod, :read, [base, tid, role, name])

      true ->
        :not_found
    end
  rescue
    _ -> :not_found
  end

  defp write_skill(nil, _role, _name, _content), do: {:error, :no_tenant}

  defp write_skill(tid, role, name, content) do
    mod = EzagentPluginContent.Skill.SkillStore
    base = skill_base_dir()

    cond do
      is_nil(base) ->
        {:error, :content_unavailable}

      Code.ensure_loaded?(mod) and function_exported?(mod, :write, 5) ->
        apply(mod, :write, [base, tid, role, name, content])

      true ->
        {:error, :content_unavailable}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # Preview (inline render, no agent)
  # ---------------------------------------------------------------------------

  defp render_preview(nil, _role), do: "(no tenant)"

  defp render_preview(tid, role) do
    loader = EzagentPluginContent.Soul.SoulLoader
    renderer = EzagentPluginContent.Soul.SoulRenderer
    store = EzagentPluginContent.Soul.SoulStore
    priv = priv_dir()
    base = content_base_dir()

    with true <- not is_nil(priv) and not is_nil(base),
         true <- Code.ensure_loaded?(loader) and function_exported?(loader, :load, 3),
         true <-
           Code.ensure_loaded?(renderer) and function_exported?(renderer, :full_claude_md, 3) do
      templates = apply(loader, :load, [priv, tid, role])

      slot_values =
        case apply(store, :read_slots, [base, tid, role, :sandbox]) do
          {:ok, v} -> v
          _ -> %{}
        end

      skill_index = build_skill_index(tid)

      case apply(renderer, :full_claude_md, [templates, slot_values, skill_index]) do
        "" -> "(empty)"
        rendered -> rendered
      end
    else
      _ -> "(content plugin unavailable)"
    end
  rescue
    e -> "(preview failed: #{Exception.message(e)})"
  end

  # A minimal skill index for the preview: a bulleted list of the sandbox
  # skill names. The real release skill index lives in the release tree;
  # this is a faithful sandbox preview, not the published artifact.
  defp build_skill_index(tid) do
    case list_skills(tid) do
      [] -> ""
      names -> "## Skills\n" <> Enum.map_join(names, "\n", &"- #{&1}")
    end
  end

  # ---------------------------------------------------------------------------
  # CR / publish / lint
  # ---------------------------------------------------------------------------

  defp load_cr_info(nil), do: nil

  defp load_cr_info(tid) do
    mod = EzagentPluginCr.CrEngine

    if Code.ensure_loaded?(mod) and function_exported?(mod, :ensure_active_cr, 1) do
      case apply(mod, :ensure_active_cr, [tid]) do
        {:ok, cr} -> cr
        {:error, _} -> nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp publish_cr(tid) do
    mod = EzagentPluginCr.CrEngine

    if Code.ensure_loaded?(mod) and function_exported?(mod, :publish, 1) do
      apply(mod, :publish, [tid])
    else
      {:error, :cr_unavailable}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp load_lint_results(nil), do: %{ok: true, warnings: []}

  defp load_lint_results(tid) do
    mod = EzagentPluginCr.CrLint

    if Code.ensure_loaded?(mod) and function_exported?(mod, :check, 1) do
      case apply(mod, :check, [tid]) do
        :ok -> %{ok: true, warnings: []}
        {:error, reasons} when is_list(reasons) -> %{ok: false, warnings: reasons}
        {:error, reason} -> %{ok: false, warnings: [inspect(reason)]}
      end
    else
      %{ok: true, warnings: []}
    end
  rescue
    _ -> %{ok: true, warnings: []}
  end

  defp format_publish_error(reasons) when is_list(reasons), do: Enum.join(reasons, "; ")
  defp format_publish_error(reason) when is_binary(reason), do: reason
  defp format_publish_error(reason), do: inspect(reason)

  # ---------------------------------------------------------------------------
  # YAML helpers (slots edited as YAML text)
  # ---------------------------------------------------------------------------

  # Parse YAML text into a string-keyed map. Empty input == empty map.
  defp parse_yaml_map(text) do
    trimmed = String.trim(text)

    if trimmed == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(trimmed) do
        {:ok, map} when is_map(map) -> {:ok, map}
        {:ok, _other} -> {:error, "顶层必须是 key: value 映射"}
        {:error, reason} -> {:error, yaml_error_message(reason)}
      end
    end
  end

  defp yaml_error_message(%{message: msg}) when is_binary(msg), do: msg
  defp yaml_error_message(reason), do: inspect(reason)

  # Render a (possibly nested) string-keyed map back to a simple YAML text
  # for the textarea. Mirrors SoulStore's own encoder shape.
  defp map_to_yaml(map) when is_map(map) and map_size(map) == 0, do: ""

  defp map_to_yaml(map) when is_map(map), do: encode_yaml(map, 0)

  defp map_to_yaml(_), do: ""

  defp encode_yaml(map, indent) when is_map(map) do
    map
    |> Enum.map(fn {k, v} ->
      prefix = String.duplicate("  ", indent)

      if is_map(v) do
        "#{prefix}#{k}:\n#{encode_yaml(v, indent + 1)}"
      else
        "#{prefix}#{k}: #{v}"
      end
    end)
    |> Enum.join("\n")
  end

  defp encode_yaml(value, _indent), do: "#{value}"

  # ---------------------------------------------------------------------------
  # render/1
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6 space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-xl font-bold text-gray-900">租户内容管理控制台</h1>
        <span class="text-xs text-gray-400">{@tid || "(no tenant)"} · role={@role}</span>
      </div>

      <div
        :if={!@can_write?}
        class="rounded border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-800"
      >
        无权限：当前账号不持有 workspace 管理能力（admin），页面为只读模式，无法保存或发布。
      </div>
      
    <!-- Slots panel (editable slot VALUES; dev has no raw-soul editing) -->
      <section class="rounded-xl border border-gray-200 bg-white overflow-hidden">
        <header class="px-4 py-3 bg-gray-800 text-white flex items-center justify-between">
          <h2 class="font-semibold text-sm">Slots 编辑 (sandbox 槽位值 · {@role})</h2>
          <span
            :if={@slots_saved_flash}
            class="text-xs rounded bg-green-200 text-green-800 px-2 py-0.5"
          >
            {@slots_saved_flash}
          </span>
        </header>
        <div class="p-4">
          <p class="text-xs text-gray-500 mb-2">
            soul 模板为固定层（只读），此处编辑的是模板 <code>{"{{key}}"}</code> 占位符的取值（YAML）。
          </p>
          <form phx-submit="save_slots">
            <textarea
              name="slots"
              rows="10"
              readonly={!@can_write?}
              class={[
                "w-full font-mono text-sm border border-gray-300 rounded p-2 focus:outline-none focus:ring-2 focus:ring-blue-400",
                !@can_write? && "bg-gray-50 text-gray-500 cursor-not-allowed"
              ]}
            >{@slots_yaml}</textarea>
            <div class="mt-2 flex justify-end">
              <button
                type="submit"
                disabled={!@can_write?}
                class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700 disabled:opacity-40 disabled:cursor-not-allowed"
              >
                保存
              </button>
            </div>
          </form>
        </div>
      </section>
      
    <!-- Skills panel (editable) -->
      <section class="rounded-xl border border-gray-200 bg-white overflow-hidden">
        <header class="px-4 py-3 bg-gray-800 text-white">
          <h2 class="font-semibold text-sm">Skills (sandbox · {@role})</h2>
        </header>
        <div class="p-4 space-y-3">
          <p :if={@skills == []} class="text-sm text-gray-400">沙箱中暂无 skill 文件</p>
          <ul :if={@skills != []} class="flex flex-wrap gap-2">
            <li :for={name <- @skills}>
              <button
                phx-click="open_skill"
                phx-value-name={name}
                class={[
                  "font-mono text-xs rounded px-2 py-1 border",
                  @selected_skill == name && "bg-blue-50 border-blue-400 text-blue-700",
                  @selected_skill != name &&
                    "bg-gray-50 border-gray-300 text-gray-700 hover:bg-gray-100"
                ]}
              >
                {name}
              </button>
            </li>
          </ul>

          <div :if={@selected_skill}>
            <div class="flex items-center justify-between mb-1">
              <span class="text-xs font-medium text-gray-600">
                {@selected_skill}/SKILL.md
              </span>
              <span
                :if={@skill_saved_flash}
                class="text-xs text-green-700"
              >
                {@skill_saved_flash}
              </span>
            </div>
            <form phx-submit="save_skill">
              <textarea
                name="content"
                rows="10"
                readonly={!@can_write?}
                class={[
                  "w-full font-mono text-sm border border-gray-300 rounded p-2 focus:outline-none focus:ring-2 focus:ring-blue-400",
                  !@can_write? && "bg-gray-50 text-gray-500 cursor-not-allowed"
                ]}
              >{@skill_content}</textarea>
              <div class="mt-2 flex justify-end">
                <button
                  type="submit"
                  disabled={!@can_write?}
                  class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700 disabled:opacity-40 disabled:cursor-not-allowed"
                >
                  保存
                </button>
              </div>
            </form>
          </div>
        </div>
      </section>
      
    <!-- CR / Publish panel -->
      <section class="rounded-xl border border-gray-200 bg-white overflow-hidden">
        <header class="px-4 py-3 bg-gray-800 text-white flex items-center justify-between">
          <h2 class="font-semibold text-sm">发布 (Change Request)</h2>
          <button
            phx-click="refresh_lint"
            class="text-xs underline opacity-80 hover:opacity-100"
          >
            重新检查
          </button>
        </header>
        <div class="p-4 space-y-3">
          <div class="text-sm text-gray-700">
            <span :if={is_nil(@cr_info)} class="text-gray-400">暂无 CR 记录</span>
            <%= if @cr_info do %>
              <span class="font-mono text-xs text-gray-500">{@cr_info["cr_id"]}</span>
              <span class={[
                "ml-2 rounded px-2 py-0.5 text-xs",
                @cr_info["status"] == "open" && "bg-yellow-100 text-yellow-800",
                @cr_info["status"] == "published" && "bg-green-100 text-green-800",
                @cr_info["status"] == "cancelled" && "bg-gray-100 text-gray-600"
              ]}>
                {@cr_info["status"]}
              </span>
              <span :if={@cr_info["published_version"]} class="ml-2 text-xs text-gray-500">
                v{@cr_info["published_version"]}
              </span>
            <% end %>
          </div>

          <div :if={@lint_results}>
            <p :if={@lint_results.ok && @lint_results.warnings == []} class="text-xs text-green-700">
              ✓ Lint 通过，无警告
            </p>
            <div :if={@lint_results.warnings != []} class="space-y-1">
              <p class={[
                "text-xs font-medium",
                @lint_results.ok && "text-amber-700",
                !@lint_results.ok && "text-red-700"
              ]}>
                {if @lint_results.ok, do: "Lint 警告:", else: "Lint 错误:"}
              </p>
              <ul class={[
                "list-disc list-inside text-xs space-y-0.5",
                @lint_results.ok && "text-amber-700",
                !@lint_results.ok && "text-red-700"
              ]}>
                <li :for={w <- @lint_results.warnings}>{w}</li>
              </ul>
            </div>
          </div>

          <div
            :if={@publish_flash}
            class={[
              "rounded border px-3 py-2 text-sm",
              @publish_flash_type == :ok && "bg-green-50 border-green-300 text-green-800",
              @publish_flash_type == :error && "bg-red-50 border-red-300 text-red-800",
              @publish_flash_type == :info && "bg-blue-50 border-blue-300 text-blue-800"
            ]}
          >
            {@publish_flash}
          </div>

          <div class="flex justify-end">
            <button
              phx-click="publish"
              disabled={!@can_write?}
              class="rounded bg-emerald-600 text-white px-5 py-2 text-sm font-medium hover:bg-emerald-700 disabled:opacity-40 disabled:cursor-not-allowed"
            >
              发布
            </button>
          </div>
        </div>
      </section>
      
    <!-- Preview panel (inline render — no agent) -->
      <section class="rounded-xl border border-gray-200 bg-white overflow-hidden">
        <header class="px-4 py-3 bg-gray-800 text-white flex items-center justify-between">
          <h2 class="font-semibold text-sm">预览渲染 (sandbox {@role} CLAUDE.md)</h2>
          <button
            phx-click="preview"
            class="text-xs rounded bg-blue-500 text-white px-3 py-1 hover:bg-blue-600"
          >
            预览渲染
          </button>
        </header>
        <div class="p-4">
          <p :if={is_nil(@preview_content)} class="text-sm text-gray-400">
            点击「预览渲染」查看沙箱内容渲染结果（不创建 agent，仅本地渲染）
          </p>
          <pre
            :if={@preview_content}
            class="text-xs text-gray-800 whitespace-pre-wrap font-mono bg-gray-50 border border-gray-200 rounded p-3 overflow-auto max-h-96"
          >{@preview_content}</pre>
        </div>
      </section>
    </div>
    """
  end
end
