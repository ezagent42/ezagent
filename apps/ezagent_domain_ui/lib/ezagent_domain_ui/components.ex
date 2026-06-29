defmodule EzagentDomainUi.Components do
  @moduledoc """
  shadcn-inspired HEEx primitives for Ezagent admin/plugin UIs.

  `use EzagentDomainUi.Components` imports every component below so
  templates can call `<.button>`, `<.card>`, `<.badge>` etc. directly.

  Visual identity:
  - Ezagent DS tokens mapped through shadcn semantic names
  - pill controls and 22px floating cards
  - cobalt primary action, vermilion danger, jade success
  - soft elevation before hard borders
  - consistent spacing (4 / 6 / 8 px scale)

  Each component takes a `:class` attr that's appended after the
  default classes (shadcn pattern), so callers can override or extend
  without rewriting the primitive.
  """

  use Phoenix.Component

  defmacro __using__(_opts) do
    quote do
      import EzagentDomainUi.Components
    end
  end

  @doc """
  Button.

      <.button>Click me</.button>
      <.button variant="primary" phx-click="save">Save</.button>
      <.button variant="ghost" size="sm">Cancel</.button>
  """
  attr(:variant, :string,
    default: "default",
    values: ~w(default primary success danger ghost outline)
  )

  attr(:size, :string, default: "md", values: ~w(sm md lg))
  attr(:class, :string, default: "")
  attr(:rest, :global, include: ~w(type disabled phx-click phx-disable-with phx-value-name name))
  slot(:inner_block, required: true)

  def button(assigns) do
    ~H"""
    <button
      class={[
        "inline-flex items-center justify-center font-medium rounded-full transition-colors",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1",
        "disabled:opacity-50 disabled:cursor-not-allowed",
        size_class(@size),
        variant_class(@variant),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp size_class("sm"), do: "h-8 px-3 text-xs"
  defp size_class("md"), do: "h-9 px-4 text-sm"
  defp size_class("lg"), do: "h-10 px-6 text-sm"

  defp variant_class("default"),
    do:
      "bg-card text-foreground hover:bg-accent hover:text-accent-foreground border border-input shadow-[var(--shadow-card)]"

  defp variant_class("primary"),
    do: "bg-primary text-primary-foreground hover:bg-primary/90 shadow-[var(--shadow-soft)]"

  defp variant_class("success"),
    do: "bg-[var(--ez-jade)] text-white hover:brightness-95 shadow-[var(--shadow-soft)]"

  defp variant_class("danger"),
    do:
      "bg-destructive text-destructive-foreground hover:bg-destructive/90 shadow-[var(--shadow-soft)]"

  defp variant_class("ghost"),
    do: "text-foreground hover:bg-accent hover:text-accent-foreground"

  defp variant_class("outline"),
    do:
      "bg-transparent border border-input text-foreground hover:bg-accent hover:text-accent-foreground"

  @doc """
  Text input for plugin/domain UI forms.

      <.input field={@form[:name]} label="Name" />
  """
  attr(:field, Phoenix.HTML.FormField, default: nil)
  attr(:type, :string, default: "text")
  attr(:label, :string, default: nil)
  attr(:id, :string, default: nil)
  attr(:name, :string, default: nil)
  attr(:value, :any, default: nil)
  attr(:class, :string, default: "")

  attr(:rest, :global,
    include:
      ~w(autocomplete disabled max maxlength min minlength pattern placeholder readonly required size step)
  )

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil)
    |> assign(:id, assigns[:id] || field.id)
    |> assign(:name, assigns[:name] || field.name)
    |> assign(:value, assigns[:value] || field.value)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(assigns) do
    ~H"""
    <label class="grid gap-1 text-xs">
      <span :if={@label} class="text-muted-foreground">{@label}</span>
      <input
        type={@type}
        id={@id}
        name={@name}
        value={@value}
        class={[
          "px-3 py-1.5 rounded-full border border-input bg-card text-foreground shadow-sm focus:outline-none focus:ring-2 focus:ring-ring",
          @class
        ]}
        {@rest}
      />
    </label>
    """
  end

  @doc """
  Card — container with subtle border + shadow.

      <.card>
        <:header>Recent activity</:header>
        <p>body content</p>
      </.card>
  """
  attr(:class, :string, default: "")
  attr(:rest, :global)
  slot(:header)
  slot(:inner_block, required: true)

  def card(assigns) do
    ~H"""
    <div
      class={[
        "bg-card text-card-foreground rounded-[var(--radius)] shadow-[var(--shadow-card)]",
        @class
      ]}
      {@rest}
    >
      <div :if={@header != []} class="px-4 py-3 border-b border-border">
        <h3 class="text-sm font-semibold text-card-foreground">{render_slot(@header)}</h3>
      </div>
      <div class="p-4 text-sm text-muted-foreground">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Badge — small inline tag (status chips, counts).

      <.badge>main</.badge>
      <.badge variant="success">online</.badge>
      <.badge variant="danger">offline</.badge>
  """
  attr(:variant, :string,
    default: "default",
    values: ~w(default primary success warning danger info)
  )

  attr(:class, :string, default: "")
  slot(:inner_block, required: true)

  def badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center px-2.5 py-0.5 text-xs font-medium rounded-full border",
      badge_class(@variant),
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp badge_class("default"),
    do: "bg-muted text-muted-foreground border-transparent"

  defp badge_class("primary"),
    do: "bg-primary text-primary-foreground border-transparent"

  defp badge_class("success"),
    do:
      "bg-[color-mix(in_srgb,var(--ez-jade)_12%,white)] text-[var(--ez-jade)] border-transparent"

  defp badge_class("warning"),
    do:
      "bg-[color-mix(in_srgb,var(--ez-yellow)_24%,white)] text-[var(--ez-ink)] border-transparent"

  defp badge_class("danger"),
    do: "bg-destructive/10 text-destructive border-transparent"

  defp badge_class("info"),
    do: "bg-accent text-accent-foreground border-transparent"

  @doc """
  Page header — title + optional subtitle + actions slot.

      <.page_header title="Workspaces">
        <:subtitle>Persisted Session + Member declarations</:subtitle>
        <:actions>
          <.button variant="primary">New workspace</.button>
        </:actions>
      </.page_header>
  """
  attr(:title, :string, required: true)
  attr(:class, :string, default: "")
  slot(:subtitle)
  slot(:actions)

  def page_header(assigns) do
    ~H"""
    <div class={[
      "flex items-end justify-between mb-6 pb-4 border-b border-border",
      @class
    ]}>
      <div>
        <h1 class="text-xl font-semibold text-foreground">{@title}</h1>
        <p :if={@subtitle != []} class="mt-1 text-sm text-muted-foreground">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
    </div>
    """
  end

  @doc """
  Breadcrumb — comma-separated trail with chevrons + final non-link label.

  Used on /admin sub-pages so users always have a one-click path back to
  the parent surface (Allen 2026-05-20: every sub-page on /admin/* was
  reachable only by browser back).

      <.breadcrumb items={[{"Admin", "/admin"}, {"Logs & Audit", nil}]} />

  Items are `{label, href_or_nil}` tuples. The last item is expected to
  have `nil` href (it's the current page; don't link to self).
  """
  attr(:items, :list, required: true)
  attr(:class, :string, default: "")

  def breadcrumb(assigns) do
    ~H"""
    <nav
      class={["flex items-center gap-1 text-xs text-muted-foreground mb-3", @class]}
      aria-label="Breadcrumb"
    >
      <%= for {{label, href}, idx} <- Enum.with_index(@items) do %>
        <span :if={idx > 0} class="text-border select-none">/</span>
        <a
          :if={href}
          href={href}
          class="hover:text-foreground transition-colors"
        >
          {label}
        </a>
        <span
          :if={is_nil(href)}
          class="text-foreground"
          aria-current="page"
        >
          {label}
        </span>
      <% end %>
    </nav>
    """
  end

  @doc """
  Stat — single key/value pair used in summary rows.

      <.stat label="Sessions" value={5} />
      <.stat label="Online" value={3} variant="success" />
  """
  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:variant, :string, default: "default", values: ~w(default success warning danger))
  attr(:class, :string, default: "")

  def stat(assigns) do
    ~H"""
    <div class={["flex flex-col gap-0.5", @class]}>
      <span class="text-xs uppercase tracking-wide text-muted-foreground">{@label}</span>
      <span class={["text-lg font-semibold tabular-nums", stat_value_class(@variant)]}>
        {@value}
      </span>
    </div>
    """
  end

  defp stat_value_class("default"), do: "text-foreground"
  defp stat_value_class("success"), do: "text-emerald-700 dark:text-emerald-300"
  defp stat_value_class("warning"), do: "text-amber-700 dark:text-amber-300"
  defp stat_value_class("danger"), do: "text-red-700 dark:text-red-300"

  @doc """
  Plugin card — the unified `/plugins` listing tile (plugin authoring
  contract SPEC §6.2 / PR-4).

  ONE consistent card shape for every registered plugin: name +
  description + version badge + a config icon. The config icon is the
  Allen-#1 affordance — every card carries the SAME cog, so a plugin's
  config surface is always reachable in the same place.

  `config_path` decides the cog's behavior; it is derived by the caller
  from the plugin's `Ezagent.Plugin.config_surface/0`:

    - `:route`  → the surface's own `path`.
    - `:flavor` → `/identities?filter=agent:<flavor>` (manage that
      flavor's agents — SPEC §6.1, Allen Q1).
    - `nil`     → pass `config_path={nil}`; the cog renders disabled
      (present, but not a link — the shape stays consistent).

  `config_label` is the cog's tooltip / aria-label (e.g. "Bindings",
  "Claude Code Agents"). It defaults to "Configure".

      <.plugin_card
        name="Feishu (Lark)"
        description="Lark integration (inbound webhook + outbound bot)."
        version="0.1.0"
        config_path="/plugins/feishu/bindings"
        config_label="Bindings"
      />
  """
  attr(:name, :string, required: true)
  attr(:description, :string, required: true)
  attr(:version, :string, required: true)
  attr(:config_path, :string, default: nil)
  attr(:config_label, :string, default: "Configure")
  attr(:class, :string, default: "")

  def plugin_card(assigns) do
    ~H"""
    <div class={[
      "bg-card text-card-foreground rounded-[var(--radius)] shadow-[var(--shadow-card)] p-4",
      @class
    ]}>
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="text-sm font-semibold text-card-foreground truncate">
            {@name}
          </div>
          <div class="text-[11px] font-mono text-muted-foreground mt-0.5">
            v{@version}
          </div>
        </div>
        <a
          :if={@config_path}
          href={@config_path}
          title={@config_label}
          aria-label={@config_label}
          class="shrink-0 inline-flex items-center justify-center w-7 h-7 rounded-full text-muted-foreground hover:bg-accent hover:text-accent-foreground transition-colors"
        >
          {render_cog()}
        </a>
        <span
          :if={is_nil(@config_path)}
          title="No config surface"
          aria-label="No config surface"
          class="shrink-0 inline-flex items-center justify-center w-7 h-7 rounded-full text-muted-foreground/50 cursor-not-allowed"
        >
          {render_cog()}
        </span>
      </div>
      <p class="text-xs text-muted-foreground mt-2">{@description}</p>
    </div>
    """
  end

  # Inline cog SVG (Heroicons 24/outline `cog-6-tooth`). Inlined rather
  # than reaching for the `<.icon>` primitive so `components.ex` keeps
  # zero dependency on `primitives.ex` — same self-contained house style
  # as the other atoms in this file.
  defp render_cog do
    Phoenix.HTML.raw("""
    <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true">
      <path stroke-linecap="round" stroke-linejoin="round" d="M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.324.196.72.257 1.075.124l1.217-.456a1.125 1.125 0 0 1 1.37.49l1.296 2.247a1.125 1.125 0 0 1-.26 1.431l-1.003.827c-.293.241-.438.613-.43.992a7.723 7.723 0 0 1 0 .255c-.008.378.137.75.43.991l1.004.827c.424.35.534.955.26 1.43l-1.298 2.247a1.125 1.125 0 0 1-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.47 6.47 0 0 1-.22.128c-.331.183-.581.495-.644.869l-.213 1.281c-.09.543-.56.94-1.11.94h-2.594c-.55 0-1.019-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 0 1-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 0 1-1.369-.49l-1.297-2.247a1.125 1.125 0 0 1 .26-1.431l1.004-.827c.292-.24.437-.613.43-.991a6.932 6.932 0 0 1 0-.255c.007-.38-.138-.751-.43-.992l-1.004-.827a1.125 1.125 0 0 1-.26-1.43l1.297-2.247a1.125 1.125 0 0 1 1.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.086.22-.128.332-.183.582-.495.644-.869l.214-1.28Z" />
      <path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z" />
    </svg>
    """)
  end

  @doc """
  Flash group — renders `Phoenix.LiveView`-style flash messages
  (`:info` / `:error`) consistently across all admin/plugin LVs.

  PR-B (Allen 2026-05-23) — replaces the per-LV inline flash render
  patterns that had drifted (`assign(:flash_error, ...)` +
  conditional `<div class="error">...</div>` per LV). Single source
  of truth for visual + a11y.

  ## Usage

      # In your LV mount:
      put_flash(socket, :info, "Saved.")
      put_flash(socket, :error, "Validation failed: ...")

      # In your LV render:
      <.flash_group flash={@flash} />

  Renders nothing if both `:info` and `:error` are absent. Subscribers
  to flash events can also pass extra slots; v1 keeps the API minimal.

  ## Why not `<.flash_group>` from Phoenix's generator

  Phoenix 1.7+ ships a `flash_group` in `<your_app>_web/components/`,
  but each app's generator-output diverges. Putting the shared
  primitive in `EzagentDomainUi.Components` ensures every admin/plugin
  LV (which all already `use EzagentDomainUi.Components`) gets the
  same component for free.
  """
  attr(:flash, :map, required: true, doc: "the @flash map from socket.assigns")
  attr(:class, :string, default: "")

  def flash_group(assigns) do
    ~H"""
    <div :if={flash_present?(@flash)} class={["space-y-2 mb-4", @class]}>
      <div
        :if={msg = Phoenix.Flash.get(@flash, :info)}
        role="status"
        class="px-3 py-2 rounded-[var(--radius)] text-sm bg-[color-mix(in_srgb,var(--ez-jade)_12%,white)] text-[var(--ez-jade)] flex items-start gap-2"
      >
        <span class="font-mono text-[10px] uppercase tracking-wider mt-0.5 opacity-70">info</span>
        <span>{msg}</span>
      </div>

      <div
        :if={msg = Phoenix.Flash.get(@flash, :error)}
        role="alert"
        class="px-3 py-2 rounded-[var(--radius)] text-sm bg-destructive/10 text-destructive flex items-start gap-2"
      >
        <span class="font-mono text-[10px] uppercase tracking-wider mt-0.5 opacity-70">error</span>
        <span>{msg}</span>
      </div>
    </div>
    """
  end

  defp flash_present?(flash) when is_map(flash) do
    not is_nil(Phoenix.Flash.get(flash, :info)) or
      not is_nil(Phoenix.Flash.get(flash, :error))
  end

  defp flash_present?(_), do: false
end
