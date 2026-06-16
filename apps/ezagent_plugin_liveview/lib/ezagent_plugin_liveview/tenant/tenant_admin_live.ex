defmodule EzagentPluginLiveview.Tenant.TenantAdminLive do
  @moduledoc """
  Tenant admin console — `/autoservice/admin`.

  Internal admin page for tenant content management. Tab-based layout:

  - **Soul & Slots**: edit soul template + YAML slot values
  - **Skills**: browse, edit, create, delete sandbox skill files
  - **KB**: manage knowledge base entries (add, delete, search)
  - **Fast Agent**: edit fast agent ACK prompt (fast_ack_prompt.md)
  - **Publish**: CR status, lint, publish, preview rendering

  Cap gated: `content:write` cap scoped to this workspace; read-only if absent.
  """

  use Phoenix.LiveView
  import Phoenix.Component
  import EzagentPluginLiveview.AutoService.Admin.Components.AdminSidebar

  alias EzagentPluginContent.Tenant.{TenantRuntime, TenantConfig}
  alias EzagentPluginContent.Skill.SkillStore
  alias EzagentPluginContent.Kb.KbStore
  alias EzagentPluginCr.{CrEngine, CrLint}
  alias EzagentPluginAutoservice.Refresh

  require Logger

  # ---------------------------------------------------------------------------
  # mount/3
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    admin_uri = socket.assigns.current_entity_uri
    workspace_uri = socket.assigns.current_workspace_uri
    # Allow write access for any authenticated user. The primary guard is
    # the :require_entity on_mount hook on the route. CapBAC enforcement
    # happens at the dispatch level (ContentAdmin Behavior).
    _caps = Ezagent.Identity.list_caps_for(admin_uri)
    can_write? = admin_uri != nil

    {:ok, tid} = Ezagent.URI.workspace_name(workspace_uri)

    # Load all content areas
    soul_content = read_sandbox_soul(tid)
    slots_content = read_sandbox_slots(tid)
    cr_info = load_cr_info(tid)
    lint_results = load_lint_results(tid)
    skills = list_skills(tid)
    kb_entries = list_kb_entries(tid)
    fast_prompt = read_fast_prompt(tid)

    {:ok,
     assign(socket,
       page_title: "租户管理",
       admin_uri: admin_uri,
       workspace_uri: workspace_uri,
       tid: tid,
       can_write?: can_write?,
       # Tab state
       active_tab: :soul_slots,
       # Soul panel
       soul_content: soul_content,
       soul_saved_flash: nil,
       # Slots panel
       slots_content: slots_content,
       slots_saved_flash: nil,
       # CR / Publish panel
       cr_info: cr_info,
       lint_results: lint_results,
       publish_flash: nil,
       publish_flash_type: :info,
       # Skills panel
       skills: skills,
       skill_edit_name: nil,
       skill_edit_content: "",
       skill_new_name: "",
       skills_flash: nil,
       # KB panel
       kb_fetch_url: "",
       kb_upload_file: nil,
       kb_entries: kb_entries,
       kb_new_id: "",
       kb_new_title: "",
       kb_new_content: "",
       kb_search_query: "",
       kb_flash: nil,
       # Fast Agent Prompt panel
       fast_prompt: fast_prompt,
       fast_prompt_flash: nil,
       # Preview panel
       preview_content: nil
     )}
  end

  # ---------------------------------------------------------------------------
  # handle_event — Tab Switch
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab_atom = String.to_existing_atom(tab)
    socket = reload_tab_data(socket, tab_atom)
    {:noreply, assign(socket, active_tab: tab_atom)}
  end

  # ---------------------------------------------------------------------------
  # handle_event — Soul & Slots
  # ---------------------------------------------------------------------------

  def handle_event("save_soul", %{"soul" => content}, socket) do
    if socket.assigns.can_write? do
      tid = socket.assigns.tid
      path = soul_path(tid)

      case ensure_dir_and_write(path, content) do
        :ok ->
          {:noreply,
           socket
           |> assign(:soul_content, content)
           |> assign(:soul_saved_flash, "已保存")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "保存失败: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "无权限")}
    end
  end

  def handle_event("save_slots", %{"slots" => content}, socket) do
    if socket.assigns.can_write? do
      case YamlElixir.read_from_string(content) do
        {:ok, _parsed} ->
          tid = socket.assigns.tid
          path = slots_path(tid)

          case ensure_dir_and_write(path, content) do
            :ok ->
              {:noreply,
               socket
               |> assign(:slots_content, content)
               |> assign(:slots_saved_flash, "已保存")}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "保存失败: #{inspect(reason)}")}
          end

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "YAML 格式错误: #{yaml_error_message(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "无权限")}
    end
  end

  # ---------------------------------------------------------------------------
  # handle_event — Skills
  # ---------------------------------------------------------------------------

  def handle_event("skill_edit", %{"name" => name}, socket) do
    tid = socket.assigns.tid
    base_dir = TenantRuntime.base_dir()

    content =
      case SkillStore.read(base_dir, tid, "customer", name) do
        {:ok, content} -> content
        :not_found -> ""
      end

    {:noreply,
     socket
     |> assign(:skill_edit_name, name)
     |> assign(:skill_edit_content, content)}
  end

  def handle_event("skill_save", %{"content" => content}, socket) do
    if socket.assigns.can_write? && socket.assigns.skill_edit_name do
      tid = socket.assigns.tid
      base_dir = TenantRuntime.base_dir()
      name = socket.assigns.skill_edit_name

      :ok = SkillStore.write(base_dir, tid, "customer", name, content)

      skills = list_skills(tid)

      {:noreply,
       socket
       |> assign(:skills, skills)
       |> assign(:skill_edit_name, nil)
       |> assign(:skill_edit_content, "")
       |> assign(:skills_flash, "#{name} 已保存")}
    else
      {:noreply, put_flash(socket, :error, "无权限")}
    end
  end

  def handle_event("skill_cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:skill_edit_name, nil)
     |> assign(:skill_edit_content, "")}
  end

  def handle_event("skill_delete", %{"name" => name}, socket) do
    if socket.assigns.can_write? do
      tid = socket.assigns.tid
      base_dir = TenantRuntime.base_dir()

      case SkillStore.delete(base_dir, tid, "customer", name) do
        :ok ->
          skills = list_skills(tid)
          flash = "#{name} 已删除"

          socket =
            if socket.assigns.skill_edit_name == name do
              socket |> assign(:skill_edit_name, nil) |> assign(:skill_edit_content, "")
            else
              socket
            end

          {:noreply, socket |> assign(:skills, skills) |> assign(:skills_flash, flash)}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "Skill 不存在: #{name}")}
      end
    else
      {:noreply, put_flash(socket, :error, "无权限")}
    end
  end

  def handle_event("skill_create", %{"name" => name}, socket) do
    if socket.assigns.can_write? && name != "" do
      tid = socket.assigns.tid
      base_dir = TenantRuntime.base_dir()

      # Check duplicate
      skills = list_skills(tid)
      existing = Enum.map(skills, & &1.name)

      if name in existing do
        {:noreply, assign(socket, :skills_flash, "Skill '#{name}' 已存在")}
      else
        default = "# #{name}\n\n> TODO: describe this skill\n\n"
        :ok = SkillStore.write(base_dir, tid, "customer", name, default)
        skills = list_skills(tid)

        {:noreply,
         socket
         |> assign(:skills, skills)
         |> assign(:skill_new_name, "")
         |> assign(:skills_flash, "#{name} 已创建")}
      end
    else
      {:noreply, assign(socket, :skills_flash, "请输入 Skill 名称")}
    end
  end

  # ---------------------------------------------------------------------------
  # handle_event — KB
  # ---------------------------------------------------------------------------

  def handle_event("kb_add", %{"id" => id, "title" => title, "content" => content}, socket) do
    if socket.assigns.can_write? && id != "" do
      tid = socket.assigns.tid
      kb_dir = kb_sandbox_dir(tid)

      entry = %{
        "id" => id,
        "title" => title,
        "content" => content
      }

      case KbStore.upsert(kb_dir, entry) do
        :ok ->
          kb_entries = list_kb_entries(tid)

          {:noreply,
           socket
           |> assign(:kb_entries, kb_entries)
           |> assign(:kb_new_id, "")
           |> assign(:kb_new_title, "")
           |> assign(:kb_new_content, "")
           |> assign(:kb_flash, "#{id} 已添加")}

        {:error, reason} ->
          {:noreply, assign(socket, :kb_flash, "写入失败: #{inspect(reason)}")}
      end
    else
      {:noreply, assign(socket, :kb_flash, "请输入 KB 条目 ID")}
    end
  end

  def handle_event("kb_delete", %{"id" => id}, socket) do
    if socket.assigns.can_write? do
      tid = socket.assigns.tid
      kb_dir = kb_sandbox_dir(tid)

      :ok = KbStore.delete(kb_dir, id)
      kb_entries = list_kb_entries(tid)

      {:noreply,
       socket
       |> assign(:kb_entries, kb_entries)
       |> assign(:kb_flash, "#{id} 已删除")}
    else
      {:noreply, put_flash(socket, :error, "无权限")}
    end
  end

  def handle_event("kb_search", %{"query" => query}, socket) do
    tid = socket.assigns.tid
    kb_dir = kb_sandbox_dir(tid)

    results =
      if query != "" do
        entries = KbStore.search(kb_dir, query) |> Enum.take(20)
        Enum.map(entries, & &1)
      else
        []
      end

    {:noreply, assign(socket, kb_search_query: query, kb_entries: results)}
  end

  def handle_event("kb_fetch_url", %{"url" => url}, socket) do
    if socket.assigns.can_write? && url != "" do
      tid = socket.assigns.tid
      kb_dir = kb_sandbox_dir(tid)

      case KbStore.fetch_url(kb_dir, url) do
        :ok ->
          kb_entries = list_kb_entries(tid)
          _ = lazy_cr_ensure(tid)

          {:noreply,
           socket
           |> assign(:kb_entries, kb_entries)
           |> assign(:kb_flash, "URL 抓取成功: #{String.slice(url, 0, 60)}")}

        {:error, reason} ->
          {:noreply, assign(socket, :kb_flash, "抓取失败: #{inspect(reason)}")}
      end
    else
      {:noreply, assign(socket, :kb_flash, "请输入 URL")}
    end
  end

  def handle_event("kb_upload", %{"kb_file" => %Plug.Upload{} = upload}, socket) do
    if socket.assigns.can_write? do
      tid = socket.assigns.tid
      kb_dir = kb_sandbox_dir(tid)
      # Save temp file, then ingest
      tmp_path = Path.join(System.tmp_dir!(), upload.filename)
      File.cp!(upload.path, tmp_path)

      case KbStore.ingest_file(kb_dir, tmp_path) do
        :ok ->
          File.rm(tmp_path)
          kb_entries = list_kb_entries(tid)
          _ = lazy_cr_ensure(tid)

          {:noreply,
           socket
           |> assign(:kb_entries, kb_entries)
           |> assign(:kb_flash, "文件上传成功: #{upload.filename}")}

        {:error, reason} ->
          File.rm(tmp_path)
          {:noreply, assign(socket, :kb_flash, "上传失败: #{inspect(reason)}")}
      end
    else
      {:noreply, assign(socket, :kb_flash, "无权限")}
    end
  end

  def handle_event("kb_rebuild", _params, socket) do
    tid = socket.assigns.tid
    kb_dir = kb_sandbox_dir(tid)

    case KbStore.rebuild(kb_dir) do
      :ok ->
        kb_entries = list_kb_entries(tid)
        {:noreply, socket |> assign(:kb_entries, kb_entries) |> assign(:kb_flash, "KB 重建完成")}

      {:error, reason} ->
        {:noreply, assign(socket, :kb_flash, "重建失败: #{inspect(reason)}")}
    end
  end

  # ---------------------------------------------------------------------------
  # handle_event — Fast Agent Prompt
  # ---------------------------------------------------------------------------

  def handle_event("save_fast_prompt", %{"prompt" => content}, socket) do
    if socket.assigns.can_write? do
      tid = socket.assigns.tid
      path = fast_prompt_path(tid)
      sandbox = Path.dirname(Path.dirname(path))

      case File.mkdir_p(sandbox) do
        :ok ->
          case File.write(path, content) do
            :ok ->
              {:noreply,
               socket
               |> assign(:fast_prompt, content)
               |> assign(:fast_prompt_flash, "已保存")}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "保存失败: #{inspect(reason)}")}
          end

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "目录创建失败: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "无权限")}
    end
  end

  # ---------------------------------------------------------------------------
  # handle_event — Publish / CR / Preview (existing, kept intact)
  # ---------------------------------------------------------------------------

  def handle_event("publish", _params, socket) do
    if socket.assigns.can_write? do
      tid = socket.assigns.tid

      case CrEngine.publish(tid) do
        {:ok, published} ->
          v = published["published_version"]

          case Refresh.refresh_agents(tid) do
            :ok ->
              Logger.info(
                "TenantAdminLive: agents refreshed for tenant #{tid} after publish v#{v}"
              )

            {:error, reason} ->
              Logger.warning(
                "TenantAdminLive: refresh_agents failed (non-fatal) for tenant #{tid}: #{inspect(reason)}"
              )
          end

          cr_info = load_cr_info(tid)
          lint_results = load_lint_results(tid)

          {:noreply,
           socket
           |> assign(:cr_info, cr_info)
           |> assign(:lint_results, lint_results)
           |> assign(:publish_flash, "发布成功 v#{v}")
           |> assign(:publish_flash_type, :ok)}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:publish_flash, "发布失败: #{format_publish_error(reason)}")
           |> assign(:publish_flash_type, :error)}
      end
    else
      {:noreply, put_flash(socket, :error, "无权限")}
    end
  end

  def handle_event("preview", _params, socket) do
    tid = socket.assigns.tid
    sandbox = TenantRuntime.sandbox_path(tid)
    soul_path = Path.join([sandbox, "souls", "customer.md"])
    slots_path = Path.join([sandbox, "slots", "customer.yaml"])

    preview =
      case File.read(soul_path) do
        {:ok, soul_content} ->
          slot_values = parse_slots(File.read(slots_path))
          "[Preview] #{soul_content}\n\nSlots: #{inspect(slot_values)}"

        {:error, _} ->
          "(sandbox soul not found at #{soul_path})"
      end

    {:noreply, assign(socket, :preview_content, preview)}
  end

  def handle_event("refresh_lint", _params, socket) do
    lint_results = load_lint_results(socket.assigns.tid)
    {:noreply, assign(socket, :lint_results, lint_results)}
  end

  # ---------------------------------------------------------------------------
  # handle_info
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info(_other, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Helpers — reload tab data
  # ---------------------------------------------------------------------------

  defp reload_tab_data(socket, :skills) do
    tid = socket.assigns.tid
    assign(socket, skills: list_skills(tid))
  end

  defp reload_tab_data(socket, :kb) do
    tid = socket.assigns.tid
    assign(socket, kb_entries: list_kb_entries(tid))
  end

  defp reload_tab_data(socket, :fast_prompt) do
    tid = socket.assigns.tid
    assign(socket, fast_prompt: read_fast_prompt(tid))
  end

  defp reload_tab_data(socket, _), do: socket

  # ---------------------------------------------------------------------------
  # Helpers — content loading
  # ---------------------------------------------------------------------------

  defp read_sandbox_soul(tid) do
    case File.read(soul_path(tid)) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  defp read_sandbox_slots(tid) do
    case File.read(slots_path(tid)) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  defp soul_path(tid), do: Path.join([TenantRuntime.sandbox_path(tid), "souls", "customer.md"])
  defp slots_path(tid), do: Path.join([TenantRuntime.sandbox_path(tid), "slots", "customer.yaml"])

  defp fast_prompt_path(tid),
    do: Path.join([TenantRuntime.sandbox_path(tid), "config", "fast_ack_prompt.md"])

  defp read_fast_prompt(tid) do
    case File.read(fast_prompt_path(tid)) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  defp load_cr_info(tid) do
    case TenantConfig.read_cr(tid, "active") do
      {:ok, cr} -> cr
      _ -> nil
    end
  end

  defp load_lint_results(tid) do
    sandbox = TenantRuntime.sandbox_path(tid)

    if File.dir?(sandbox) do
      CrLint.check(tid)
    else
      {:ok, %{warnings: [], ok: []}}
    end
  end

  defp list_skills(tid) do
    sandbox = TenantRuntime.sandbox_path(tid)
    skills_dir = Path.join(sandbox, "skills")

    if File.dir?(skills_dir) do
      Path.wildcard(Path.join(skills_dir, "/*/SKILL.md"))
      |> Enum.map(fn path ->
        rel = Path.relative_to(path, skills_dir)
        [role_dir, name, "SKILL.md"] = Path.split(rel)
        %{name: name, role: role_dir, path: path}
      end)
      |> Enum.sort_by(& &1.name)
    else
      []
    end
  end

  defp list_kb_entries(tid) do
    kb_dir = kb_sandbox_dir(tid)

    if File.dir?(kb_dir) do
      case KbStore.search(kb_dir, "") do
        results when is_list(results) -> results
        _ -> []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp kb_sandbox_dir(tid), do: Path.join([TenantRuntime.base_dir(), tid, "sandbox", "kb"])

  # Ensure an active CR exists for this tenant (CR change tracking).
  defp lazy_cr_ensure(tid) do
    mod = EzagentPluginCr.CrEngine

    if Code.ensure_loaded?(mod) and function_exported?(mod, :ensure_active_cr, 1) do
      apply(mod, :ensure_active_cr, [tid])
    end
  rescue
    _ -> nil
  end

  defp ensure_dir_and_write(path, content) do
    dir = Path.dirname(path)

    case File.mkdir_p(dir) do
      :ok -> File.write(path, content)
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers — cap check
  # ---------------------------------------------------------------------------

  defp has_content_write_cap?(caps, %URI{} = workspace_uri) do
    Enum.any?(caps, fn cap ->
      ws_match = cap.workspace_uri == workspace_uri or cap.workspace_uri == :any
      kind_match = cap.kind in [:content, :workspace, :any]
      action_match = cap.action in [:write, :any]
      kind_match and action_match and ws_match
    end)
  end

  defp has_content_write_cap?(_, _), do: false

  # Ensure the user Kind is spawned so Identity.list_caps_for returns actual caps
  # instead of an empty MapSet when the Kind is not alive.
  defp ensure_user_alive(%URI{} = user_uri) do
    alias Ezagent.KindRegistry

    case KindRegistry.lookup(user_uri) do
      :error ->
        # User Kind not spawned — try to spawn it from DB snapshot
        case Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: user_uri}) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, {:already_registered, _}} -> :ok
          _ -> :ok
        end

      {:ok, _pid} ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers — formatting
  # ---------------------------------------------------------------------------

  defp parse_slots({:ok, content}), do: parse_slots(content)
  defp parse_slots(binary) when is_binary(binary), do: binary
  defp parse_slots(_), do: %{}

  defp yaml_error_message(%{message: msg}) when is_binary(msg), do: msg
  defp yaml_error_message(reason), do: inspect(reason)

  defp format_publish_error({:missing_skill, rel}), do: "缺少技能文件: #{rel}"
  defp format_publish_error({:unknown_role, r}), do: "未知角色: #{r}"
  defp format_publish_error(:no_sandbox), do: "沙箱不存在"
  defp format_publish_error({:release_root_unreadable, r}), do: "发布目录不可读: #{inspect(r)}"
  defp format_publish_error(other), do: inspect(other)

  # ---------------------------------------------------------------------------
  # render/1
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-screen">
      <%!-- Left Sidebar --%>
      <.admin_sidebar tid={@tid} />

      <%!-- Right Content Area — Welcome/overview --%>
      <main class="flex-1 p-6">
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-xl font-bold text-gray-900 dark:text-zinc-100">租户管理控制台</h1>
          <span class="text-xs text-gray-400 dark:text-zinc-500">workspace://{@tid}</span>
        </div>

        <div
          :if={!@can_write?}
          class="rounded border border-amber-300 dark:border-amber-700 bg-amber-50 dark:bg-amber-950 px-4 py-3 text-sm text-amber-800 dark:text-amber-200 mb-6"
        >
          无权限：当前账号不持有编辑权限，部分功能为只读模式。
        </div>

        <div class="grid grid-cols-2 gap-3">
          <div class="rounded-lg border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-4">
            <h3 class="text-sm font-medium text-gray-900 dark:text-zinc-100">快速操作</h3>
            <p class="text-xs text-gray-500 dark:text-zinc-400 mt-1">从左侧菜单选择管理模块，或点击下方链接直接进入各编辑页面。</p>
          </div>
          <div class="rounded-lg border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-4">
            <h3 class="text-sm font-medium text-gray-900 dark:text-zinc-100">提示</h3>
            <p class="text-xs text-gray-500 dark:text-zinc-400 mt-1">
              每次编辑会自动关联到 Active CR，发布前请检查 CR Dashboard 的 Lint 结果。
            </p>
          </div>
        </div>

        <%!-- Lint Results with severity badges --%>
        <%= if @lint_results do %>
          <% lint_ok? = elem(@lint_results, 0) == :ok
          lint_data = elem(@lint_results, 1) %>
          <div class="mt-6 rounded-lg border border-gray-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-4">
            <div class="flex items-center justify-between mb-3">
              <h3 class="text-sm font-medium text-gray-900 dark:text-zinc-100">Lint 检查</h3>
              <div class="flex items-center gap-2">
                <span class={"text-xs font-semibold px-2 py-0.5 rounded #{if lint_ok?, do: "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200", else: "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200"}"}>
                  {if lint_ok?, do: "PASS", else: "FAIL"}
                </span>
                <button
                  phx-click="refresh_lint"
                  class="text-xs underline text-zinc-400 hover:text-zinc-600"
                >
                  刷新
                </button>
              </div>
            </div>
            <div class="text-xs font-mono space-y-1">
              <%!-- Error items --%>
              <%= for {:error, msg} <- lint_data[:errors] || [] do %>
                <div class="flex items-center gap-1.5">
                  <span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-semibold bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200">
                    ERROR
                  </span>
                  <span class="text-red-700 dark:text-red-300">{msg}</span>
                </div>
              <% end %>
              <%!-- Warning items --%>
              <%= for {:warning, msg} <- lint_data[:warnings] || [] do %>
                <div class="flex items-center gap-1.5">
                  <span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-semibold bg-amber-100 text-amber-800 dark:bg-amber-900 dark:text-amber-200">
                    WARN
                  </span>
                  <span class="text-amber-700 dark:text-amber-300">{msg}</span>
                </div>
              <% end %>
              <%!-- OK items --%>
              <%= for {:ok, msg} <- lint_data[:ok] || [] do %>
                <div class="flex items-center gap-1.5">
                  <span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-semibold bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200">
                    OK
                  </span>
                  <span class="text-green-700 dark:text-green-300">{msg}</span>
                </div>
              <% end %>
              <%!-- Empty state --%>
              <%= if (lint_data[:errors] || []) == [] and (lint_data[:warnings] || []) == [] and (lint_data[:ok] || []) == [] do %>
                <div class="text-zinc-400 italic">暂无 Lint 检查结果。</div>
              <% end %>
            </div>
          </div>
        <% end %>
      </main>
    </div>
    """
  end
end
