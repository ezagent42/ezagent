defmodule EzagentPluginCustomerChat.ConfigLive do
  @moduledoc """
  Per-tenant customer-soul editor at `/plugins/customer-chat/:tenant/config`.
  Gated by `ConfigAuth.config_admin?/2` (workspace-admin). Edits the soul body;
  Save → new conversations use it; Revert → previous; Reset → immutable fixture.
  """
  use Phoenix.LiveView
  import Phoenix.Component

  alias EzagentPluginCustomerChat.{ConfigAuth, SoulStore}

  @role "customer"

  @impl true
  def mount(%{"tenant" => tenant}, _session, socket) do
    caller = socket.assigns[:current_entity_uri]

    if ConfigAuth.config_admin?(caller, tenant) do
      {:ok, load(socket, tenant)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Configuration access required for #{tenant}.")
       |> redirect(to: "/operator/#{tenant}")}
    end
  end

  defp load(socket, tenant) do
    {:ok, body, source} = SoulStore.read_effective(tenant, @role)

    socket
    |> assign(:page_title, "Configure — #{tenant}")
    |> assign(:tenant, tenant)
    |> assign(:body, body)
    |> assign(:source, source)
    |> assign(:has_previous, SoulStore.has_previous?(tenant, @role))
    |> assign(:flash_error, nil)
  end

  @impl true
  def handle_event("save", %{"soul" => %{"body" => body}}, socket) do
    tenant = socket.assigns.tenant

    case SoulStore.write(tenant, @role, body) do
      :ok ->
        {:noreply,
         socket |> load(tenant) |> put_flash(:info, "Soul saved — new conversations will use it.")}

      {:error, reason} ->
        {:noreply, assign(socket, :flash_error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("revert", _params, socket) do
    tenant = socket.assigns.tenant

    case SoulStore.revert_previous(tenant, @role) do
      :ok ->
        {:noreply, socket |> load(tenant) |> put_flash(:info, "Reverted to previous version.")}

      {:error, :no_previous} ->
        {:noreply, put_flash(socket, :error, "No previous version to revert to.")}
    end
  end

  def handle_event("reset", _params, socket) do
    tenant = socket.assigns.tenant
    :ok = SoulStore.reset(tenant, @role)
    {:noreply, socket |> load(tenant) |> put_flash(:info, "Reset to default.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col bg-zinc-50">
      <header class="px-6 py-3 border-b border-zinc-200 bg-white flex items-center gap-3">
        <span class="font-semibold text-zinc-900">Configure Customer Soul</span>
        <span class="text-xs text-zinc-500 font-mono">{@tenant}</span>
        <span class="text-xs px-2 py-0.5 rounded-full bg-zinc-100 text-zinc-600">
          {if @source == :edited, do: "customized", else: "default"}
        </span>
        <.link navigate={"/operator/#{@tenant}"} class="ml-auto text-sm text-blue-600 hover:underline">
          ← Back to console
        </.link>
      </header>

      <form phx-submit="save" class="flex-1 flex flex-col p-6 gap-3 overflow-hidden">
        <textarea
          name="soul[body]"
          class="flex-1 w-full px-3 py-2 text-sm font-mono border rounded-md border-zinc-300 bg-white text-zinc-900 resize-none"
        >{@body}</textarea>

        <p :if={@flash_error} class="text-rose-700 text-sm">{@flash_error}</p>

        <div class="flex items-center gap-2 pt-2 border-t border-zinc-200">
          <button
            type="submit"
            class="px-3 py-1.5 text-sm rounded-md bg-blue-600 text-white hover:bg-blue-700"
          >
            Save
          </button>
          <button
            type="button"
            phx-click="revert"
            disabled={not @has_previous}
            class="px-3 py-1.5 text-sm rounded-md border border-zinc-300 text-zinc-700 hover:bg-zinc-100 disabled:opacity-40"
          >
            Revert to previous
          </button>
          <button
            type="button"
            phx-click="reset"
            data-confirm="Reset to the default soul? This discards your edits."
            class="px-3 py-1.5 text-sm rounded-md border border-rose-300 text-rose-700 hover:bg-rose-50"
          >
            Reset to default
          </button>
        </div>
      </form>
    </div>
    """
  end
end
