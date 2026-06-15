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
    caps = Ezagent.Identity.list_caps_for(admin_uri)
    can_write? = has_content_write_cap?(caps, workspace_uri)

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
      cap.kind == :content and
        cap.action in [:write, :any] and
        (cap.workspace_uri == workspace_uri or cap.workspace_uri == :any)
    end)
  end

  defp has_content_write_cap?(_, _), do: false

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
        <span class="text-xs text-gray-400">{URI.to_string(@workspace_uri)}</span>
      </div>

      <div :if={!@can_write?} class="rounded border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-800">
        无权限：当前账号不持有 content:write 能力，页面为只读模式。
      </div>

      <%!-- Tab bar --%>
      <nav class="flex border-b border-gray-200 space-x-1">
        <button phx-click="switch_tab" phx-value-tab="soul_slots"
          class={["px-4 py-2 text-sm font-medium rounded-t-lg", @active_tab == :soul_slots && "bg-white border border-gray-200 border-b-white text-blue-700 -mb-px", @active_tab != :soul_slots && "text-gray-500 hover:text-gray-700"]}>
          Soul &amp; Slots
        </button>
        <button phx-click="switch_tab" phx-value-tab="skills"
          class={["px-4 py-2 text-sm font-medium rounded-t-lg", @active_tab == :skills && "bg-white border border-gray-200 border-b-white text-blue-700 -mb-px", @active_tab != :skills && "text-gray-500 hover:text-gray-700"]}>
          Skills
        </button>
        <button phx-click="switch_tab" phx-value-tab="kb"
          class={["px-4 py-2 text-sm font-medium rounded-t-lg", @active_tab == :kb && "bg-white border border-gray-200 border-b-white text-blue-700 -mb-px", @active_tab != :kb && "text-gray-500 hover:text-gray-700"]}>
          KB
        </button>
        <button phx-click="switch_tab" phx-value-tab="fast_prompt"
          class={["px-4 py-2 text-sm font-medium rounded-t-lg", @active_tab == :fast_prompt && "bg-white border border-gray-200 border-b-white text-blue-700 -mb-px", @active_tab != :fast_prompt && "text-gray-500 hover:text-gray-700"]}>
          Fast Agent
        </button>
        <button phx-click="switch_tab" phx-value-tab="publish"
          class={["px-4 py-2 text-sm font-medium rounded-t-lg", @active_tab == :publish && "bg-white border border-gray-200 border-b-white text-blue-700 -mb-px", @active_tab != :publish && "text-gray-500 hover:text-gray-700"]}>
          发布
        </button>
      </nav>

      <%!-- Tab content --%>
      <div class="bg-white rounded-b-xl border border-t-0 border-gray-200">

        <%!-- Soul & Slots Tab --%>
        <div :if={@active_tab == :soul_slots} class="p-4 space-y-6">
          <%!-- Soul --%>
          <section>
            <header class="px-4 py-3 bg-gray-800 text-white rounded-t-lg flex items-center justify-between">
              <h2 class="font-semibold text-sm">Soul 编辑 (sandbox/souls/customer.md)</h2>
              <span :if={@soul_saved_flash} class="text-xs rounded bg-green-200 text-green-800 px-2 py-0.5">{@soul_saved_flash}</span>
            </header>
            <div class="border border-t-0 border-gray-200 rounded-b-lg p-4">
              <form phx-submit="save_soul">
                <textarea name="soul" rows="14" readonly={!@can_write?}
                  class={["w-full font-mono text-sm border border-gray-300 rounded p-2 focus:outline-none focus:ring-2 focus:ring-blue-400", !@can_write? && "bg-gray-50 text-gray-500 cursor-not-allowed"]}
                >{@soul_content}</textarea>
                <div class="mt-2 flex justify-end">
                  <button type="submit" disabled={!@can_write?}
                    class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700 disabled:opacity-40 disabled:cursor-not-allowed">
                    保存
                  </button>
                </div>
              </form>
            </div>
          </section>

          <%!-- Slots --%>
          <section>
            <header class="px-4 py-3 bg-gray-800 text-white rounded-t-lg">
              <h2 class="font-semibold text-sm">Slots 编辑 (sandbox/slots/customer.yaml)</h2>
            </header>
            <div class="border border-t-0 border-gray-200 rounded-b-lg p-4">
              <form phx-submit="save_slots">
                <textarea name="slots" rows="8" readonly={!@can_write?}
                  class={["w-full font-mono text-sm border border-gray-300 rounded p-2 focus:outline-none focus:ring-2 focus:ring-blue-400", !@can_write? && "bg-gray-50 text-gray-500 cursor-not-allowed"]}
                >{@slots_content}</textarea>
                <div class="mt-2 flex items-center justify-between">
                  <span :if={@slots_saved_flash} class="text-xs text-green-700">{@slots_saved_flash}</span>
                  <div class="ml-auto">
                    <button type="submit" disabled={!@can_write?}
                      class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700 disabled:opacity-40 disabled:cursor-not-allowed">
                      保存
                    </button>
                  </div>
                </div>
              </form>
            </div>
          </section>
        </div>

        <%!-- Skills Tab --%>
        <div :if={@active_tab == :skills} class="p-4 space-y-4">
          <div :if={@skills_flash} class="text-xs text-green-700 bg-green-50 rounded px-3 py-1.5">{@skills_flash}</div>

          <%!-- Create new skill --%>
          <section :if={@can_write?}>
            <header class="px-4 py-2.5 bg-gray-800 text-white rounded-t-lg">
              <h2 class="font-semibold text-sm">新建 Skill</h2>
            </header>
            <div class="border border-t-0 border-gray-200 rounded-b-lg p-4">
              <form phx-submit="skill_create" class="flex gap-2">
                <input type="text" name="name" value={@skill_new_name} placeholder="skill-name (不含 SKILL.md)"
                  class="flex-1 rounded border border-gray-300 px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-400" />
                <button type="submit" class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700">创建</button>
              </form>
            </div>
          </section>

          <%!-- Skill list --%>
          <section>
            <header class="px-4 py-2.5 bg-gray-800 text-white rounded-t-lg flex justify-between items-center">
              <h2 class="font-semibold text-sm">Sandbox Skills ({length(@skills)} 个)</h2>
            </header>
            <div class="border border-t-0 border-gray-200 rounded-b-lg">
              <p :if={@skills == []} class="p-4 text-sm text-gray-400">沙箱中暂无 skill 文件。使用上方表单创建。</p>
              <div :if={@skills != []} class="divide-y divide-gray-100">
                <%= for skill <- @skills do %>
                  <div class="px-4 py-2.5 flex items-center justify-between hover:bg-gray-50">
                    <div>
                      <span class="font-mono text-xs text-gray-700">{skill.role}/{skill.name}</span>
                    </div>
                    <div class="flex gap-2">
                      <button phx-click="skill_edit" phx-value-name={skill.name}
                        class="text-xs rounded bg-gray-100 text-gray-700 px-2.5 py-1 hover:bg-blue-100 hover:text-blue-700">
                        编辑
                      </button>
                      <button :if={@can_write?} phx-click="skill_delete" phx-value-name={skill.name}
                        class="text-xs rounded bg-red-50 text-red-600 px-2.5 py-1 hover:bg-red-100"
                        phx-confirm={"确认删除 skill '#{skill.name}'?"}>
                        删除
                      </button>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          </section>

          <%!-- Skill Editor (shown when a skill is selected) --%>
          <section :if={@skill_edit_name}>
            <header class="px-4 py-2.5 bg-gray-800 text-white rounded-t-lg flex justify-between items-center">
              <h2 class="font-semibold text-sm">编辑: {@skill_edit_name}</h2>
              <button phx-click="skill_cancel_edit" class="text-xs underline opacity-80 hover:opacity-100">取消</button>
            </header>
            <div class="border border-t-0 border-gray-200 rounded-b-lg p-4">
              <form phx-submit="skill_save">
                <textarea name="content" rows="16" readonly={!@can_write?}
                  class={["w-full font-mono text-sm border border-gray-300 rounded p-2 focus:outline-none focus:ring-2 focus:ring-blue-400", !@can_write? && "bg-gray-50 text-gray-500 cursor-not-allowed"]}
                >{@skill_edit_content}</textarea>
                <div class="mt-2 flex justify-end gap-2">
                  <button type="button" phx-click="skill_cancel_edit"
                    class="rounded border border-gray-300 text-gray-700 px-4 py-1.5 text-sm hover:bg-gray-50">取消</button>
                  <button type="submit" disabled={!@can_write?}
                    class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700 disabled:opacity-40">保存</button>
                </div>
              </form>
            </div>
          </section>
        </div>

        <%!-- KB Tab --%>
        <div :if={@active_tab == :kb} class="p-4 space-y-4">
          <div :if={@kb_flash} class="text-xs text-green-700 bg-green-50 rounded px-3 py-1.5">{@kb_flash}</div>

          <%!-- KB Search --%>
          <section>
            <header class="px-4 py-2.5 bg-gray-800 text-white rounded-t-lg">
              <h2 class="font-semibold text-sm">KB 搜索</h2>
            </header>
            <div class="border border-t-0 border-gray-200 rounded-b-lg p-4">
              <form phx-submit="kb_search" class="flex gap-2">
                <input type="text" name="query" value={@kb_search_query} placeholder="输入搜索关键词..."
                  class="flex-1 rounded border border-gray-300 px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-400" />
                <button type="submit" class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700">搜索</button>
              </form>
            </div>
          </section>

          <%!-- KB Add --%>
          <section :if={@can_write?}>
            <header class="px-4 py-2.5 bg-gray-800 text-white rounded-t-lg">
              <h2 class="font-semibold text-sm">添加 KB 条目</h2>
            </header>
            <div class="border border-t-0 border-gray-200 rounded-b-lg p-4 space-y-3">
              <form phx-submit="kb_add">
                <div class="grid grid-cols-1 gap-2">
                  <input type="text" name="id" value={@kb_new_id} placeholder="条目 ID（唯一标识）"
                    class="rounded border border-gray-300 px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-400" />
                  <input type="text" name="title" value={@kb_new_title} placeholder="标题"
                    class="rounded border border-gray-300 px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-400" />
                  <textarea name="content" rows="4" placeholder="内容"
                    class="w-full rounded border border-gray-300 px-3 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-400"
                  >{@kb_new_content}</textarea>
                </div>
                <div class="mt-2 flex justify-end">
                  <button type="submit" class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700">添加</button>
                </div>
              </form>
            </div>
          </section>

          <%!-- KB Entries List --%>
          <section>
            <header class="px-4 py-2.5 bg-gray-800 text-white rounded-t-lg flex justify-between items-center">
              <h2 class="font-semibold text-sm">KB 条目 ({length(@kb_entries)} 个)</h2>
            </header>
            <div class="border border-t-0 border-gray-200 rounded-b-lg">
              <p :if={@kb_entries == []} class="p-4 text-sm text-gray-400">
                KB 中暂无几录。输入搜索关键词或使用上方表单添加。
              </p>
              <div :if={@kb_entries != []} class="divide-y divide-gray-100">
                <%= for entry <- @kb_entries do %>
                  <div class="px-4 py-2.5">
                    <div class="flex items-center justify-between">
                      <div class="flex-1 min-w-0">
                        <span class="font-mono text-xs text-gray-500">{entry["id"]}</span>
                        <span :if={entry["title"]} class="ml-2 text-sm text-gray-800 font-medium">{entry["title"]}</span>
                      </div>
                      <button :if={@can_write?} phx-click="kb_delete" phx-value-id={entry["id"]}
                        class="text-xs rounded bg-red-50 text-red-600 px-2.5 py-1 hover:bg-red-100 ml-2 flex-shrink-0"
                        phx-confirm={"确认删除 KB 条目 '#{entry["id"]}'?"}>
                        删除
                      </button>
                    </div>
                    <p :if={entry["content"]} class="mt-1 text-xs text-gray-600 line-clamp-2">{String.slice(entry["content"], 0, 200)}</p>
                  </div>
                <% end %>
              </div>
            </div>
          </section>
        </div>

        <%!-- Fast Agent Prompt Tab --%>
        <div :if={@active_tab == :fast_prompt} class="p-4 space-y-4">
          <section>
            <header class="px-4 py-3 bg-gray-800 text-white rounded-t-lg flex items-center justify-between">
              <div>
                <h2 class="font-semibold text-sm">Fast Agent ACK Prompt</h2>
                <p class="text-xs opacity-60 mt-0.5">sandbox/config/fast_ack_prompt.md — DeepSeek 即时安抚回复的提示词</p>
              </div>
              <span :if={@fast_prompt_flash} class="text-xs rounded bg-green-200 text-green-800 px-2 py-0.5">{@fast_prompt_flash}</span>
            </header>
            <div class="border border-t-0 border-gray-200 rounded-b-lg p-4">
              <form phx-submit="save_fast_prompt">
                <textarea name="prompt" rows="12" readonly={!@can_write?}
                  class={["w-full font-mono text-sm border border-gray-300 rounded p-2 focus:outline-none focus:ring-2 focus:ring-blue-400", !@can_write? && "bg-gray-50 text-gray-500 cursor-not-allowed"]}
                >{@fast_prompt}</textarea>
                <div class="mt-2 flex justify-between items-center">
                  <p class="text-xs text-gray-400">发布 CR 后，Refresh.after_publish 会将此提示词写入 fast agent 的 system_prompt</p>
                  <button type="submit" disabled={!@can_write?}
                    class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700 disabled:opacity-40 disabled:cursor-not-allowed">
                    保存
                  </button>
                </div>
              </form>
            </div>
          </section>
        </div>

        <%!-- Publish Tab --%>
        <div :if={@active_tab == :publish} class="p-4 space-y-6">
          <%!-- CR panel --%>
          <section>
            <header class="px-4 py-3 bg-gray-800 text-white rounded-t-lg flex items-center justify-between">
              <h2 class="font-semibold text-sm">发布 (Change Request)</h2>
              <button phx-click="refresh_lint" class="text-xs underline opacity-80 hover:opacity-100">重新检查</button>
            </header>
            <div class="border border-t-0 border-gray-200 rounded-b-lg p-4 space-y-3">
              <div class="text-sm text-gray-700">
                <span :if={is_nil(@cr_info)} class="text-gray-400">暂无 CR 记录</span>
                <%= if @cr_info do %>
                  <span class="font-mono text-xs text-gray-500">{@cr_info["cr_id"]}</span>
                  <span class={["ml-2 rounded px-2 py-0.5 text-xs", @cr_info["status"] == "draft" && "bg-yellow-100 text-yellow-800", @cr_info["status"] == "published" && "bg-green-100 text-green-800"]}>
                    {@cr_info["status"]}
                  </span>
                  <span :if={@cr_info["published_version"]} class="ml-2 text-xs text-gray-500">v{@cr_info["published_version"]}</span>
                <% end %>
              </div>

              <%!-- Lint results --%>
              <div :if={@lint_results}>
                <p :if={@lint_results.ok && @lint_results.warnings == []} class="text-xs text-green-700">✓ Lint 通过，无警告</p>
                <div :if={@lint_results.ok && @lint_results.warnings != []} class="space-y-1">
                  <p class="text-xs text-amber-700 font-medium">Lint 警告:</p>
                  <ul class="list-disc list-inside text-xs text-amber-700 space-y-0.5">
                    <li :for={w <- @lint_results.warnings}>{w}</li>
                  </ul>
                </div>
                <div :if={!@lint_results.ok} class="text-xs text-red-700">Lint 错误: {inspect(@lint_results[:error])}</div>
              </div>

              <%!-- Publish flash --%>
              <div :if={@publish_flash} class={["rounded border px-3 py-2 text-sm", @publish_flash_type == :ok && "bg-green-50 border-green-300 text-green-800", @publish_flash_type == :error && "bg-red-50 border-red-300 text-red-800"]}>
                {@publish_flash}
              </div>

              <div class="flex justify-end">
                <button phx-click="publish" disabled={!@can_write?}
                  class="rounded bg-emerald-600 text-white px-5 py-2 text-sm font-medium hover:bg-emerald-700 disabled:opacity-40 disabled:cursor-not-allowed">发布</button>
              </div>
            </div>
          </section>

          <%!-- Preview panel --%>
          <section>
            <header class="px-4 py-3 bg-gray-800 text-white rounded-t-lg flex items-center justify-between">
              <h2 class="font-semibold text-sm">预览渲染 (sandbox CLAUDE.md)</h2>
              <button phx-click="preview" class="text-xs rounded bg-blue-500 text-white px-3 py-1 hover:bg-blue-600">预览渲染</button>
            </header>
            <div class="border border-t-0 border-gray-200 rounded-b-lg p-4">
              <p :if={is_nil(@preview_content)} class="text-sm text-gray-400">点击「预览渲染」查看沙箱内容渲染结果（不创建 agent，仅本地渲染）</p>
              <pre :if={@preview_content} class="text-xs text-gray-800 whitespace-pre-wrap font-mono bg-gray-50 border border-gray-200 rounded p-3 overflow-auto max-h-96">{@preview_content}</pre>
            </div>
          </section>
        </div>

      </div>
    </div>
    """
  end
end
