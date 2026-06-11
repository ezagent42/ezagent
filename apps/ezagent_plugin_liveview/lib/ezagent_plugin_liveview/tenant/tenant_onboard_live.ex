defmodule EzagentPluginLiveview.Tenant.TenantOnboardLive do
  @moduledoc """
  T2A.1 — Tenant Onboard Wizard at `/autoservice/master/onboard`.

  3-step wizard:
    1. Basic info: tid, brand, industry
    2. Admin account (operator URI + password)
    3. Initialization — calls `TenantProvisioner.create_tenant/3` and
       shows result.

  Mount assigns: page_title, workspace_uri, current step, form data.
  """
  use Phoenix.LiveView
  use Gettext, backend: EzagentPluginLiveview.Gettext
  use EzagentDomainUi.Components
  import Phoenix.Component

  @steps [:basic_info, :admin_account, :initialize]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Onboard New Tenant"))
     |> assign(:workspace_uri, Map.get(socket.assigns, :current_workspace_uri))
     |> assign(:step, :basic_info)
     |> assign(:step_index, 0)
     |> assign(:form_data, %{
       tid: "",
       brand_name: "",
       industry: "cloud-comms",
       admin_uri: "",
       admin_password: ""
     })
     |> assign(:error, nil)
     |> assign(:result, nil)}
  end

  @impl true
  def handle_event("update_field", %{"field" => field, "value" => value}, socket) do
    field = String.to_existing_atom(field)
    data = Map.put(socket.assigns.form_data, field, value)
    {:noreply, assign(socket, form_data: data, error: nil)}
  end

  def handle_event("next", _params, socket) do
    idx = socket.assigns.step_index

    if idx < length(@steps) - 1 do
      next_idx = idx + 1
      {:noreply,
       socket
       |> assign(:step, Enum.at(@steps, next_idx))
       |> assign(:step_index, next_idx)
       |> assign(:error, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("prev", _params, socket) do
    idx = socket.assigns.step_index

    if idx > 0 do
      prev_idx = idx - 1
      {:noreply,
       socket
       |> assign(:step, Enum.at(@steps, prev_idx))
       |> assign(:step_index, prev_idx)
       |> assign(:error, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("create_tenant", _params, socket) do
    data = socket.assigns.form_data

    with :ok <- validate_step3(data),
         {:ok, _result} <- do_create_tenant(data) do
      {:noreply,
       socket
       |> assign(:result, %{
         tid: data.tid,
         brand_name: data.brand_name,
         industry: data.industry
       })
       |> assign(:step, :done)
       |> assign(:error, nil)}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :error, reason)}
    end
  end

  # --- Validation -----------------------------------------------------------

  defp validate_step3(data) do
    cond do
      data.tid == "" or data.brand_name == "" ->
        {:error, gettext("Tenant ID and brand name are required.")}

      data.admin_uri == "" ->
        {:error, gettext("Admin operator URI is required.")}

      true ->
        :ok
    end
  end

  # --- Side effect (soft-guarded) -------------------------------------------

  defp do_create_tenant(data) do
    mod = EzagentPluginContent.Tenant.TenantProvisioner

    if Code.ensure_loaded?(mod) and function_exported?(mod, :create_tenant, 3) do
      apply(mod, :create_tenant, [
        data.tid,
        data.brand_name,
        [industry: data.industry]
      ])
    else
      {:error, "TenantProvisioner not available"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="px-6 py-6 text-zinc-900 dark:text-zinc-100 max-w-2xl">
      <.page_header title={@page_title}>
        <:subtitle>
          {gettext("Step %{current} of %{total}: %{label}",
            current: @step_index + 1, total: length(@steps), label: step_label(@step)
          )}
        </:subtitle>
      </.page_header>

      <%!-- Step indicators --%>
      <div class="flex gap-2 mb-6 mt-2">
        <div
          :for={{s, i} <- Enum.with_index(@steps)}
          class={[
            "flex-1 h-1 rounded-full",
            i <= @step_index && "bg-zinc-800 dark:bg-zinc-200",
            i > @step_index && "bg-zinc-200 dark:bg-zinc-700"
          ]}
        />
      </div>

      <%!-- Error banner --%>
      <p :if={@error} class="mb-4 text-sm text-rose-600 dark:text-rose-400 bg-rose-50 dark:bg-rose-950 p-3 rounded-md">
        {@error}
      </p>

      <%!-- Done state --%>
      <%= if @step == :done do %>
        <.card>
          <:header><span class="text-green-700 dark:text-green-400"><%= gettext("Tenant created") %></span></:header>
          <div class="text-sm space-y-1">
            <p><strong><%= gettext("Tenant ID") %></strong>: <code>{@result.tid}</code></p>
            <p><strong><%= gettext("Brand") %></strong>: {@result.brand_name}</p>
            <p><strong><%= gettext("Industry") %></strong>: {@result.industry}</p>
          </div>
          <div class="mt-4 flex gap-2">
            <a
              href={"/autoservice/master"}
              class="px-3 py-1.5 text-sm border border-zinc-300 dark:border-zinc-700 rounded-md hover:bg-zinc-50 dark:hover:bg-zinc-800"
            >
              {gettext("Back to Dashboard")}
            </a>
            <a
              href={"/autoservice/master/onboard"}
              class="px-3 py-1.5 text-sm bg-zinc-800 text-white rounded-md hover:bg-zinc-700"
            >
              {gettext("Onboard Another")}
            </a>
          </div>
        </.card>
      <% else %>
        <%!-- Step 1: Basic Info --%>
        <%= if @step == :basic_info do %>
          <.card>
            <:header>{gettext("Step 1: Basic Information")}</:header>
            <div class="space-y-4">
              <div>
                <label for="f_tid" class="block text-sm font-medium mb-1">
                  {gettext("Tenant ID")} <span class="text-rose-500">*</span>
                </label>
                <input
                  id="f_tid" type="text" name="tid" value={@form_data.tid}
                  phx-change="update_field" phx-value-field="tid"
                  placeholder="example-tenant"
                  class="w-full px-3 py-1.5 text-sm border border-zinc-300 dark:border-zinc-700 rounded-md bg-white dark:bg-zinc-900 focus:outline-none focus:ring-2 focus:ring-zinc-500"
                />
              </div>
              <div>
                <label for="f_brand" class="block text-sm font-medium mb-1">
                  {gettext("Brand Name")} <span class="text-rose-500">*</span>
                </label>
                <input
                  id="f_brand" type="text" name="brand_name" value={@form_data.brand_name}
                  phx-change="update_field" phx-value-field="brand_name"
                  placeholder="Example Corp"
                  class="w-full px-3 py-1.5 text-sm border border-zinc-300 dark:border-zinc-700 rounded-md bg-white dark:bg-zinc-900 focus:outline-none focus:ring-2 focus:ring-zinc-500"
                />
              </div>
              <div>
                <label for="f_industry" class="block text-sm font-medium mb-1">
                  {gettext("Industry")}
                </label>
                <select
                  id="f_industry" name="industry"
                  phx-change="update_field" phx-value-field="industry"
                  class="w-full px-3 py-1.5 text-sm border border-zinc-300 dark:border-zinc-700 rounded-md bg-white dark:bg-zinc-900 focus:outline-none focus:ring-2 focus:ring-zinc-500"
                >
                  <option value="cloud-comms" selected={@form_data.industry == "cloud-comms"}>Cloud Communications</option>
                  <option value="ecommerce" selected={@form_data.industry == "ecommerce"}>E-Commerce</option>
                  <option value="fintech" selected={@form_data.industry == "fintech"}>Fintech</option>
                  <option value="gaming" selected={@form_data.industry == "gaming"}>Gaming</option>
                  <option value="other" selected={@form_data.industry == "other"}>Other</option>
                </select>
              </div>
            </div>
          </.card>
        <% end %>

        <%!-- Step 2: Admin Account --%>
        <%= if @step == :admin_account do %>
          <.card>
            <:header>{gettext("Step 2: Admin Account")}</:header>
            <div class="space-y-4">
              <div>
                <label for="f_admin_uri" class="block text-sm font-medium mb-1">
                  {gettext("Admin Operator URI")} <span class="text-rose-500">*</span>
                </label>
                <input
                  id="f_admin_uri" type="text" name="admin_uri" value={@form_data.admin_uri}
                  phx-change="update_field" phx-value-field="admin_uri"
                  placeholder="entity://user/example-tenant/admin"
                  class="w-full px-3 py-1.5 text-sm border border-zinc-300 dark:border-zinc-700 rounded-md bg-white dark:bg-zinc-900 focus:outline-none focus:ring-2 focus:ring-zinc-500"
                />
                <p class="text-xs text-zinc-500 mt-1">
                  {gettext("The operator URI that will manage this tenant (e.g. entity://user/<tid>/admin).")}
                </p>
              </div>
              <div>
                <label for="f_admin_pass" class="block text-sm font-medium mb-1">
                  {gettext("Password (optional)")}
                </label>
                <input
                  id="f_admin_pass" type="password" name="admin_password" value={@form_data.admin_password}
                  phx-change="update_field" phx-value-field="admin_password"
                  class="w-full px-3 py-1.5 text-sm border border-zinc-300 dark:border-zinc-700 rounded-md bg-white dark:bg-zinc-900 focus:outline-none focus:ring-2 focus:ring-zinc-500"
                />
              </div>
            </div>
          </.card>
        <% end %>

        <%!-- Step 3: Confirm & Initialize --%>
        <%= if @step == :initialize do %>
          <.card>
            <:header>{gettext("Step 3: Confirm & Initialize")}</:header>
            <div class="text-sm space-y-2 mb-4">
              <div class="flex justify-between py-1 border-b border-zinc-100 dark:border-zinc-800">
                <span class="text-zinc-500">{gettext("Tenant ID")}</span>
                <span class="font-mono">{@form_data.tid}</span>
              </div>
              <div class="flex justify-between py-1 border-b border-zinc-100 dark:border-zinc-800">
                <span class="text-zinc-500">{gettext("Brand")}</span>
                <span>{@form_data.brand_name}</span>
              </div>
              <div class="flex justify-between py-1 border-b border-zinc-100 dark:border-zinc-800">
                <span class="text-zinc-500">{gettext("Industry")}</span>
                <span>{@form_data.industry}</span>
              </div>
              <div class="flex justify-between py-1 border-b border-zinc-100 dark:border-zinc-800">
                <span class="text-zinc-500">{gettext("Admin URI")}</span>
                <span class="font-mono text-xs">{@form_data.admin_uri}</span>
              </div>
            </div>
            <p class="text-xs text-zinc-500 mb-4">
              {gettext("This will create a sandbox directory, clone skeleton templates, and register the tenant in ConfigStore.")}
            </p>
            <button
              phx-click="create_tenant"
              class="px-4 py-2 text-sm bg-zinc-800 text-white rounded-md hover:bg-zinc-700"
            >
              {gettext("Create Tenant")}
            </button>
          </.card>
        <% end %>

        <%!-- Navigation buttons --%>
        <div :if={@step != :done} class="flex justify-between mt-4">
          <button
            phx-click="prev"
            disabled={@step_index == 0}
            class={[
              "px-4 py-1.5 text-sm border rounded-md",
              @step_index == 0 && "border-zinc-200 text-zinc-300 cursor-not-allowed",
              @step_index > 0 && "border-zinc-300 dark:border-zinc-700 hover:bg-zinc-50 dark:hover:bg-zinc-800"
            ]}
          >
            {gettext("Previous")}
          </button>
          <button
            phx-click="next"
            class="px-4 py-1.5 text-sm bg-zinc-800 text-white rounded-md hover:bg-zinc-700"
          >
            {@step_index == length(@steps) - 1 && gettext("Review") || gettext("Next")}
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  defp step_label(:basic_info), do: gettext("Basic Info")
  defp step_label(:admin_account), do: gettext("Admin Account")
  defp step_label(:initialize), do: gettext("Confirm & Initialize")
  defp step_label(:done), do: gettext("Done")
end
