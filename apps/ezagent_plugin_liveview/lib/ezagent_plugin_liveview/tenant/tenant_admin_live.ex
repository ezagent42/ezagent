defmodule EzagentPluginLiveview.Tenant.TenantAdminLive do
  @moduledoc """
  Tenant admin console — `/autoservice/admin`.

  Internal admin page for tenant content management. Panels:

  - **Soul**: edit `sandbox/souls/customer.md` — the tenant's soul override
    layer. "保存" writes the sandbox file. Gated on the tenant_admin
    content:write cap; renders read-only with a "无权限" notice if absent.

  - **Slots**: edit `sandbox/slots/customer.yaml` — variable substitutions
    for soul rendering. "保存" validates YAML via YamlElixir before writing;
    bad YAML → flash error, no write.

  - **CR**: shows the current active CR (version + status) and lint warnings.
    "[发布]" button calls `Publisher.publish/2`; on `{:ok, %{version: v}}`
    flashes the version and triggers F4 agent refresh. On `{:error, e}`
    flashes the lint/error reason.

  - **Skills**: read-only list of skill files under `sandbox/skills/`.

  - **Preview** (inline, not a separate agent): "[预览渲染]" calls
    `TenantContent.provision_context(tid, "slow", source: :sandbox)` and
    renders `.claude_md` in a `<pre>` block. No preview agent — inline only.

  ## Cap gate

  On `mount/3`, the LV reads `Ezagent.Identity.list_caps_for(current_entity_uri)`
  and checks for a `content:write` cap scoped to this workspace
  (matches `Roles.bundle(:tenant_admin, ws)` content cap).
  If absent, `can_write?` is `false`: textareas are `readonly`, publish +
  save buttons are disabled, and a "无权限" notice is shown.

  ## NP-1/2/3 (§11 naming lint)

  Module: `EzagentPluginLiveview.Tenant.TenantAdminLive` — plugin tier,
  admin namespace, unambiguous responsibility (`TenantAdmin`).
  """

  use Phoenix.LiveView
  import Phoenix.Component

  alias EzagentPluginAutoservice.Assembly.Refresh
  alias EzagentPluginContent.{TenantContent, TenantPaths}
  alias EzagentPluginCr.{CrStore, Lint, Publisher}

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

    # Load sandbox content (best-effort; sandbox may not exist yet for fresh tenants).
    soul_content = read_sandbox_soul(tid)
    slots_content = read_sandbox_slots(tid)
    cr_info = load_cr_info(tid)
    lint_results = load_lint_results(tid)
    skills = list_skills(tid)

    {:ok,
     assign(socket,
       page_title: "租户管理",
       admin_uri: admin_uri,
       workspace_uri: workspace_uri,
       tid: tid,
       can_write?: can_write?,
       # Soul panel
       soul_content: soul_content,
       soul_saved_flash: nil,
       # Slots panel
       slots_content: slots_content,
       slots_saved_flash: nil,
       # CR panel
       cr_info: cr_info,
       lint_results: lint_results,
       publish_flash: nil,
       publish_flash_type: :info,
       # Skills panel
       skills: skills,
       # Preview panel
       preview_content: nil
     )}
  end

  # ---------------------------------------------------------------------------
  # handle_event
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("save_soul", %{"soul" => content}, socket) do
    if socket.assigns.can_write? do
      tid = socket.assigns.tid
      path = Path.join([TenantPaths.sandbox_dir(tid), "souls", "customer.md"])

      case File.mkdir_p(Path.dirname(path)) do
        :ok ->
          case File.write(path, content) do
            :ok ->
              {:noreply,
               socket
               |> assign(:soul_content, content)
               |> assign(:soul_saved_flash, "已保存")}

            {:error, reason} ->
              {:noreply,
               socket
               |> put_flash(:error, "保存失败: #{inspect(reason)}")}
          end

        {:error, reason} ->
          {:noreply,
           socket
           |> put_flash(:error, "目录创建失败: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "无权限")}
    end
  end

  def handle_event("save_slots", %{"slots" => content}, socket) do
    if socket.assigns.can_write? do
      # Validate YAML before writing — bad YAML → flash error, no write.
      case YamlElixir.read_from_string(content) do
        {:ok, _parsed} ->
          tid = socket.assigns.tid
          path = Path.join([TenantPaths.sandbox_dir(tid), "slots", "customer.yaml"])

          case File.mkdir_p(Path.dirname(path)) do
            :ok ->
              case File.write(path, content) do
                :ok ->
                  {:noreply,
                   socket
                   |> assign(:slots_content, content)
                   |> assign(:slots_saved_flash, "已保存")}

                {:error, reason} ->
                  {:noreply, put_flash(socket, :error, "保存失败: #{inspect(reason)}")}
              end

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "目录创建失败: #{inspect(reason)}")}
          end

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "YAML 格式错误: #{yaml_error_message(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "无权限")}
    end
  end

  def handle_event("publish", _params, socket) do
    if socket.assigns.can_write? do
      tid = socket.assigns.tid
      admin_uri_str = URI.to_string(socket.assigns.admin_uri)

      case Publisher.publish(tid, admin_uri_str) do
        {:ok, %{version: v, warnings: warnings}} ->
          # F4: trigger agent refresh after successful publish.
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

          flash_msg =
            if warnings == [] do
              "发布成功 v#{v}"
            else
              "发布成功 v#{v}，警告: #{Enum.join(warnings, "; ")}"
            end

          cr_info = load_cr_info(tid)
          lint_results = load_lint_results(tid)

          {:noreply,
           socket
           |> assign(:cr_info, cr_info)
           |> assign(:lint_results, lint_results)
           |> assign(:publish_flash, flash_msg)
           |> assign(:publish_flash_type, :ok)}

        {:error, reason} ->
          flash_msg = "发布失败: #{format_publish_error(reason)}"

          {:noreply,
           socket
           |> assign(:publish_flash, flash_msg)
           |> assign(:publish_flash_type, :error)}
      end
    else
      {:noreply, put_flash(socket, :error, "无权限")}
    end
  end

  def handle_event("preview", _params, socket) do
    tid = socket.assigns.tid

    case TenantContent.provision_context(tid, "slow", source: :sandbox) do
      {:ok, sctx} ->
        {:noreply, assign(socket, :preview_content, sctx.claude_md || "(empty)")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:preview_content, nil)
         |> put_flash(:error, "预览失败: #{inspect(reason)}")}
    end
  end

  def handle_event("refresh_lint", _params, socket) do
    lint_results = load_lint_results(socket.assigns.tid)
    {:noreply, assign(socket, :lint_results, lint_results)}
  end

  @impl true
  def handle_info(_other, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Helpers — content loading
  # ---------------------------------------------------------------------------

  defp read_sandbox_soul(tid) do
    path = Path.join([TenantPaths.sandbox_dir(tid), "souls", "customer.md"])

    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  defp read_sandbox_slots(tid) do
    path = Path.join([TenantPaths.sandbox_dir(tid), "slots", "customer.yaml"])

    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  defp load_cr_info(tid) do
    case CrStore.get(tid) do
      {:ok, cr} -> cr
      {:error, :not_found} -> nil
    end
  end

  defp load_lint_results(tid) do
    # Lint uses the sandbox content — only run if sandbox exists.
    sandbox = TenantPaths.sandbox_dir(tid)

    if File.dir?(sandbox) do
      case Lint.run(tid) do
        {:ok, warnings} -> %{ok: true, warnings: warnings}
        {:error, reason} -> %{ok: false, error: reason}
      end
    else
      %{ok: true, warnings: []}
    end
  end

  defp list_skills(tid) do
    skills_dir = Path.join([TenantPaths.sandbox_dir(tid), "skills"])

    if File.dir?(skills_dir) do
      Path.wildcard(Path.join(skills_dir, "/**/SKILL.md"))
      |> Enum.map(fn path ->
        Path.relative_to(path, skills_dir)
      end)
      |> Enum.sort()
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers — cap check
  # ---------------------------------------------------------------------------

  # Check whether the entity holds a content:write cap scoped to this workspace
  # (or :any workspace). Matches the Roles.bundle(:tenant_admin, ws) content cap.
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

  defp yaml_error_message(%{message: msg}) when is_binary(msg), do: msg
  defp yaml_error_message(reason), do: inspect(reason)

  defp format_publish_error({:missing_skill, rel}), do: "缺少技能文件: #{rel}"
  defp format_publish_error({:unknown_role, r}), do: "未知角色: #{r}"
  defp format_publish_error(:no_sandbox), do: "沙箱不存在"
  defp format_publish_error({:release_root_unreadable, r}), do: "发布目录不可读: #{inspect(r)}"

  defp format_publish_error(other),
    do: inspect(other)

  # ---------------------------------------------------------------------------
  # render/1
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6 space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-xl font-bold text-gray-900">租户管理控制台</h1>
        <span class="text-xs text-gray-400">{URI.to_string(@workspace_uri)}</span>
      </div>

      <div
        :if={!@can_write?}
        class="rounded border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-800"
      >
        无权限：当前账号不持有 content:write 能力，页面为只读模式。
      </div>
      
    <!-- Soul panel -->
      <section class="rounded-xl border border-gray-200 bg-white overflow-hidden">
        <header class="px-4 py-3 bg-gray-800 text-white flex items-center justify-between">
          <h2 class="font-semibold text-sm">Soul 编辑 (sandbox/souls/customer.md)</h2>
          <span
            :if={@soul_saved_flash}
            class="text-xs rounded bg-green-200 text-green-800 px-2 py-0.5"
          >
            {@soul_saved_flash}
          </span>
        </header>
        <div class="p-4">
          <form phx-submit="save_soul">
            <textarea
              name="soul"
              rows="12"
              readonly={!@can_write?}
              class={[
                "w-full font-mono text-sm border border-gray-300 rounded p-2 focus:outline-none focus:ring-2 focus:ring-blue-400",
                !@can_write? && "bg-gray-50 text-gray-500 cursor-not-allowed"
              ]}
            >{@soul_content}</textarea>
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
      
    <!-- Slots panel -->
      <section class="rounded-xl border border-gray-200 bg-white overflow-hidden">
        <header class="px-4 py-3 bg-gray-800 text-white">
          <h2 class="font-semibold text-sm">Slots 编辑 (sandbox/slots/customer.yaml)</h2>
        </header>
        <div class="p-4">
          <form phx-submit="save_slots">
            <textarea
              name="slots"
              rows="8"
              readonly={!@can_write?}
              class={[
                "w-full font-mono text-sm border border-gray-300 rounded p-2 focus:outline-none focus:ring-2 focus:ring-blue-400",
                !@can_write? && "bg-gray-50 text-gray-500 cursor-not-allowed"
              ]}
            >{@slots_content}</textarea>
            <div class="mt-2 flex items-center justify-between">
              <span
                :if={@slots_saved_flash}
                class="text-xs text-green-700"
              >
                {@slots_saved_flash}
              </span>
              <div class="ml-auto">
                <button
                  type="submit"
                  disabled={!@can_write?}
                  class="rounded bg-blue-600 text-white px-4 py-1.5 text-sm font-medium hover:bg-blue-700 disabled:opacity-40 disabled:cursor-not-allowed"
                >
                  保存
                </button>
              </div>
            </div>
          </form>
        </div>
      </section>
      
    <!-- CR panel -->
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
          <!-- CR info -->
          <div class="text-sm text-gray-700">
            <span :if={is_nil(@cr_info)} class="text-gray-400">暂无 CR 记录</span>
            <%= if @cr_info do %>
              <span class="font-mono text-xs text-gray-500">{@cr_info["cr_id"]}</span>
              <span class={[
                "ml-2 rounded px-2 py-0.5 text-xs",
                @cr_info["status"] == "draft" && "bg-yellow-100 text-yellow-800",
                @cr_info["status"] == "published" && "bg-green-100 text-green-800"
              ]}>
                {@cr_info["status"]}
              </span>
              <span :if={@cr_info["published_version"]} class="ml-2 text-xs text-gray-500">
                v{@cr_info["published_version"]}
              </span>
            <% end %>
          </div>
          
    <!-- Lint results -->
          <div :if={@lint_results}>
            <p :if={@lint_results.ok && @lint_results.warnings == []} class="text-xs text-green-700">
              ✓ Lint 通过，无警告
            </p>
            <div :if={@lint_results.ok && @lint_results.warnings != []} class="space-y-1">
              <p class="text-xs text-amber-700 font-medium">Lint 警告:</p>
              <ul class="list-disc list-inside text-xs text-amber-700 space-y-0.5">
                <li :for={w <- @lint_results.warnings}>{w}</li>
              </ul>
            </div>
            <div :if={!@lint_results.ok} class="text-xs text-red-700">
              Lint 错误: {inspect(@lint_results[:error])}
            </div>
          </div>
          
    <!-- Publish flash -->
          <div
            :if={@publish_flash}
            class={[
              "rounded border px-3 py-2 text-sm",
              @publish_flash_type == :ok && "bg-green-50 border-green-300 text-green-800",
              @publish_flash_type == :error && "bg-red-50 border-red-300 text-red-800"
            ]}
          >
            {@publish_flash}
          </div>
          
    <!-- Publish button -->
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
      
    <!-- Skills panel -->
      <section class="rounded-xl border border-gray-200 bg-white overflow-hidden">
        <header class="px-4 py-3 bg-gray-800 text-white">
          <h2 class="font-semibold text-sm">Skills (sandbox/skills — 只读)</h2>
        </header>
        <div class="p-4">
          <p :if={@skills == []} class="text-sm text-gray-400">沙箱中暂无 skill 文件</p>
          <ul :if={@skills != []} class="space-y-1">
            <li :for={rel <- @skills} class="font-mono text-xs text-gray-700">
              {rel}
            </li>
          </ul>
        </div>
      </section>
      
    <!-- Preview panel (inline render) -->
      <section class="rounded-xl border border-gray-200 bg-white overflow-hidden">
        <header class="px-4 py-3 bg-gray-800 text-white flex items-center justify-between">
          <h2 class="font-semibold text-sm">预览渲染 (sandbox slow CLAUDE.md)</h2>
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
