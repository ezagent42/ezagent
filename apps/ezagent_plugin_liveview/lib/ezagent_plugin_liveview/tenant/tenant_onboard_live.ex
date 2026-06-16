defmodule EzagentPluginLiveview.Tenant.TenantOnboardLive do
  @moduledoc """
  T2A.1 — Tenant Onboard LiveView at `/admin/autoservice/tenants/new`.

  A simple single-form page: Tenant ID + Brand Name only.
  On creation, redirects to the init wizard at
  `/admin/autoservice/tenants/:tid/init`.
  """
  use Phoenix.LiveView
  import Phoenix.Component

  alias EzagentPluginContent.Tenant.TenantProvisioner

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "新建租户"
     )}
  end

  @impl true
  def handle_event("create", %{"tid" => tid, "brand_name" => brand_name}, socket) do
    case TenantProvisioner.create_tenant(tid, brand_name) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> put_flash(:info, "租户 #{tid} 创建成功")
         |> push_navigate(to: "/admin/autoservice/tenants/#{tid}/init")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "创建失败: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-lg mx-auto p-6">
      <h1 class="text-xl font-bold text-gray-900 mb-6">新建租户</h1>
      <form phx-submit="create" class="space-y-4">
        <div>
          <label class="text-sm font-medium text-gray-700">Tenant ID *</label>
          <input type="text" name="tid" required placeholder="demo-acme"
            class="w-full rounded border border-gray-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-400" />
          <p class="text-xs text-gray-400 mt-1">唯一标识，创建后不可修改</p>
        </div>
        <div>
          <label class="text-sm font-medium text-gray-700">Brand Name</label>
          <input type="text" name="brand_name" placeholder="Acme Corp"
            class="w-full rounded border border-gray-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-400" />
        </div>
        <button type="submit"
          class="w-full rounded bg-blue-600 text-white px-4 py-2 text-sm font-medium hover:bg-blue-700">
          创建租户
        </button>
      </form>
    </div>
    """
  end
end
