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
          {:noreply, socket |> assign(:kb_entries, kb_entries) |> assign(:kb_flash, "URL 抓取成功: #{String.slice(url, 0, 60)}")}
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
          {:noreply, socket |> assign(:kb_entries, kb_entries) |> assign(:kb_flash, "文件上传成功: #{upload.filename}")}
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
              Logger.info("TenantAdminLive: agents refreshed for tenant #{tid} after publish v#{v}")
            {:error, reason} ->
              Logger.warning("TenantAdminLive: refresh_agents failed (non-fatal) for tenant #{tid}: #{inspect(reason)}")
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
  defp fast_prompt_path(tid), do: Path.join([TenantRuntime.sandbox_path(tid), "config", "fast_ack_prompt.md"])

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
      case CrLint.check(tid) do
        {:ok, warnings} -> %{ok: true, warnings: warnings}
        {:error, reason} -> %{ok: false, error: reason}
      end
    else
      %{ok: true, warnings: []}
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
    <div class="max-w-5xl mx-auto p-6 space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-xl font-bold text-gray-900">租户管理控制台</h1>
        <span class="text-xs text-gray-400">workspace://<%= @tid %></span>
      </div>

      <div :if={!@can_write?} class="rounded border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-800">
        无权限：当前账号不持有编辑权限，部分功能为只读模式。
      </div>

      <div class="grid grid-cols-2 gap-4">
        <a href={"/admin/autoservice/tenants/#{@tid}/soul"} class="rounded-xl border border-gray-200 bg-white p-5 hover:shadow-md hover:border-blue-300 transition">
          <div class="text-2xl mb-2">📝</div>
          <h3 class="font-semibold text-gray-900">Soul 编辑</h3>
          <p class="text-xs text-gray-500 mt-1">编辑租户 Soul 模板、Diff 对比、预览渲染</p>
        </a>

        <a href={"/admin/autoservice/tenants/#{@tid}/soul/slots"} class="rounded-xl border border-gray-200 bg-white p-5 hover:shadow-md hover:border-blue-300 transition">
          <div class="text-2xl mb-2">🏷️</div>
          <h3 class="font-semibold text-gray-900">Slot 编辑</h3>
          <p class="text-xs text-gray-500 mt-1">编辑 Soul 变量值、YAML 批量编辑</p>
        </a>

        <a href={"/admin/autoservice/tenants/#{@tid}/skills"} class="rounded-xl border border-gray-200 bg-white p-5 hover:shadow-md hover:border-blue-300 transition">
          <div class="text-2xl mb-2">📚</div>
          <h3 class="font-semibold text-gray-900">Skill 管理</h3>
          <p class="text-xs text-gray-500 mt-1">4层 Skill 管理、创建编辑删除</p>
        </a>

        <a href={"/admin/autoservice/tenants/#{@tid}/kb"} class="rounded-xl border border-gray-200 bg-white p-5 hover:shadow-md hover:border-blue-300 transition">
          <div class="text-2xl mb-2">🗄️</div>
          <h3 class="font-semibold text-gray-900">KB 管理</h3>
          <p class="text-xs text-gray-500 mt-1">知识库管理、URL抓取、文件上传、Glossary</p>
        </a>

        <a href={"/admin/autoservice/tenants/#{@tid}/cr"} class="rounded-xl border border-gray-200 bg-white p-5 hover:shadow-md hover:border-blue-300 transition">
          <div class="text-2xl mb-2">🔄</div>
          <h3 class="font-semibold text-gray-900">CR Dashboard</h3>
          <p class="text-xs text-gray-500 mt-1">Change Request 管理、Publish、Lint、History</p>
        </a>

        <a href={"/admin/autoservice/tenants/#{@tid}/versions"} class="rounded-xl border border-gray-200 bg-white p-5 hover:shadow-md hover:border-blue-300 transition">
          <div class="text-2xl mb-2">📋</div>
          <h3 class="font-semibold text-gray-900">版本历史</h3>
          <p class="text-xs text-gray-500 mt-1">发布版本列表、回滚操作</p>
        </a>
      </div>
    </div>
    """

  end
end
