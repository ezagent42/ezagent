defmodule EzagentDomainUi.Primitives do
  @moduledoc """
  Phase 8 — additional primitives for the IDE Shell.

  Extends the shadcn-inspired set in `EzagentDomainUi.Components`
  with the building blocks that IDE-Shell layouts need: status dots,
  avatars, tabs, modals, toasts, tree lists, empty states, form
  fields, URI chips, toolbars, tooltips, icons.

  `use EzagentDomainUi.Primitives` imports every component below so
  templates can call `<.status_dot>`, `<.uri_chip>` etc. directly.

  Visual identity matches Components — neutral zinc palette, tight
  border-radius, subtle shadows.
  """

  use Phoenix.Component
  alias Phoenix.LiveView.JS

  defmacro __using__(_opts) do
    quote do
      import EzagentDomainUi.Primitives
    end
  end

  # --- status_dot ------------------------------------------------------------

  @doc """
  Small colored dot for online/offline/connecting/error states.

      <.status_dot color="green" />
      <.status_dot color="amber" pulse />
  """
  attr(:color, :string, default: "gray", values: ~w(green gray amber red))
  attr(:pulse, :boolean, default: false)
  attr(:class, :string, default: "")

  def status_dot(assigns) do
    ~H"""
    <span class={[
      "inline-block w-2 h-2 rounded-full",
      @color == "green" && "bg-emerald-500",
      @color == "gray" && "bg-zinc-400",
      @color == "amber" && "bg-amber-500",
      @color == "red" && "bg-rose-500",
      @pulse && "animate-pulse",
      @class
    ]} />
    """
  end

  # --- avatar ----------------------------------------------------------------

  @doc """
  Monogram or icon avatar for an Entity URI.

      <.avatar uri="entity://user/system/admin" />
      <.avatar uri="entity://agent/default/cc_demo" size="md" />
  """
  attr(:uri, :any, required: true)
  attr(:size, :string, default: "sm", values: ~w(xs sm md))
  attr(:class, :string, default: "")

  def avatar(assigns) do
    # Phase 8c PR-C — procedural avatar (Allen 2026-05-20). Each entity
    # gets a unique 2-color conic gradient derived from a hash of its
    # URI seed, with a single-letter monogram on top. No two entities
    # look alike, but the palette stays in a curated zone (saturated
    # mid-tones, no purple-on-white "AI slop").
    {label, hue1, hue2} = avatar_label_and_hues(assigns.uri)

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(
        :bg_style,
        "background: conic-gradient(from 220deg at 30% 30%, hsl(#{hue1} 70% 52%) 0%, hsl(#{hue2} 65% 45%) 100%);"
      )

    ~H"""
    <span
      style={@bg_style}
      class={[
        "inline-flex items-center justify-center rounded-full font-medium text-white shrink-0",
        @size == "xs" && "w-4 h-4 text-[8px]",
        @size == "sm" && "w-6 h-6 text-[10px]",
        @size == "md" && "w-8 h-8 text-xs",
        @class
      ]}
    >
      {@label}
    </span>
    """
  end

  defp avatar_label_and_hues(uri) do
    str = uri_to_string(uri)

    {label, hue_seed} =
      case URI.new(str) do
        # Phase 9 PR-2 (SPEC v3 §3): entity URIs are 3-segment;
        # extract entity_name (second path segment) for label/hue.
        {:ok, %URI{scheme: "entity", host: "user", path: "/" <> rest}} ->
          name = entity_name_from_path(rest)
          {String.upcase(String.first(name) || "?"), name}

        {:ok, %URI{scheme: "entity", host: "agent", path: "/" <> rest}} ->
          name = entity_name_from_path(rest)
          flavor = name |> String.split("_", parts: 2) |> List.first()
          {flavor |> String.first() |> String.upcase(), flavor}

        {:ok, %URI{host: host}} when is_binary(host) ->
          {String.upcase(String.first(host) || "?"), host}

        _ ->
          {"?", "fallback"}
      end

    hue1 = :erlang.phash2({hue_seed, :h1}, 360)
    # Offset 2nd hue 80-160° away for visible contrast
    hue2 = rem(hue1 + 80 + :erlang.phash2({hue_seed, :h2}, 80), 360)
    {label, hue1, hue2}
  end

  defp uri_to_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_to_string(s) when is_binary(s), do: s
  defp uri_to_string(_), do: ""

  # Phase 9 PR-2 (SPEC v3 §3): pull the entity-name segment out of a
  # 3-segment entity URI path (`<workspace>/<entity_name>`).
  defp entity_name_from_path(rest) when is_binary(rest) do
    case String.split(rest, "/", parts: 2) do
      [_workspace, entity_name] -> entity_name
      [name] -> name
    end
  end

  # --- tabs ------------------------------------------------------------------

  @doc """
  Horizontal tab strip.

      <.tabs
        items={[{:overview, "Overview"}, {:members, "Members"}]}
        selected={:overview}
        on_select="select_tab"
      />
  """
  attr(:items, :list, required: true)
  attr(:selected, :any, required: true)
  attr(:on_select, :string, default: nil)
  attr(:class, :string, default: "")

  def tabs(assigns) do
    ~H"""
    <div class={[
      "flex items-center gap-px border-b border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-950",
      @class
    ]}>
      <button
        :for={{key, label} <- @items}
        type="button"
        phx-click={@on_select}
        phx-value-key={inspect(key)}
        class={[
          "px-3 py-1.5 text-xs font-medium transition-colors border-b-2",
          (to_string(key) == to_string(@selected) &&
             "border-zinc-900 dark:border-zinc-100 text-zinc-900 dark:text-zinc-100 bg-white dark:bg-zinc-900") ||
            "border-transparent text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800"
        ]}
      >
        {label}
      </button>
    </div>
    """
  end

  # --- modal -----------------------------------------------------------------

  @doc """
  Modal with optional header/body/footer slots.

      <.modal id="confirm-delete" open={@show_modal}>
        <:header>Delete user?</:header>
        <:body>This is irreversible.</:body>
        <:footer>
          <.button variant="danger" phx-click="confirm">Delete</.button>
        </:footer>
      </.modal>
  """
  attr(:id, :string, required: true)
  attr(:open, :boolean, default: false)
  attr(:on_close, :string, default: nil)
  slot(:header)
  slot(:body)
  slot(:footer)

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "fixed inset-0 z-50 flex items-center justify-center",
        not @open && "hidden"
      ]}
      phx-window-keydown={if @on_close, do: JS.push(@on_close)}
      phx-key="escape"
    >
      <div
        class="absolute inset-0 bg-zinc-900/40 backdrop-blur-sm"
        phx-click={if @on_close, do: @on_close}
      />
      <div class="relative z-10 w-full max-w-md mx-4 bg-white dark:bg-zinc-900 rounded-lg shadow-2xl overflow-hidden">
        <div
          :if={@header != []}
          class="px-4 py-3 border-b border-zinc-200 dark:border-zinc-800 font-medium text-sm"
        >
          {render_slot(@header)}
        </div>
        <div :if={@body != []} class="px-4 py-3 text-sm text-zinc-700 dark:text-zinc-300">
          {render_slot(@body)}
        </div>
        <div
          :if={@footer != []}
          class="px-4 py-3 border-t border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-950 flex justify-end gap-2"
        >
          {render_slot(@footer)}
        </div>
      </div>
    </div>
    """
  end

  # --- toast -----------------------------------------------------------------

  @doc """
  Toast notification at the bottom-right corner.

      <.toast kind="success">Saved</.toast>
  """
  attr(:kind, :string, default: "info", values: ~w(info success error))
  attr(:class, :string, default: "")
  slot(:inner_block, required: true)

  def toast(assigns) do
    ~H"""
    <div class={[
      "fixed bottom-4 right-4 z-40 px-3 py-2 rounded-md shadow-lg text-sm font-medium",
      @kind == "info" && "bg-zinc-800 text-white",
      @kind == "success" && "bg-emerald-600 text-white",
      @kind == "error" && "bg-rose-600 text-white",
      @class
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # --- tree_list -------------------------------------------------------------

  @doc """
  Hierarchical list for resource panels.

      <.tree_list>
        <:section title="Direct Sessions">
          <:item>session://default/default/dm-1</:item>
        </:section>
      </.tree_list>

  Use the `section` slot for groups; pass plain children for ungrouped items.
  """
  attr(:class, :string, default: "")

  slot :section do
    attr(:title, :string, required: true)
    attr(:count, :integer)
  end

  slot(:inner_block)

  def tree_list(assigns) do
    ~H"""
    <div class={["flex flex-col gap-1 text-xs", @class]}>
      <div :for={section <- @section} class="mb-2">
        <div class="px-2 py-1 text-[10px] uppercase tracking-wide text-zinc-500 font-medium flex items-center justify-between">
          <span>{section.title}</span>
          <span
            :if={Map.get(section, :count)}
            class="text-zinc-400 dark:text-zinc-600 normal-case tracking-normal"
          >
            {section.count}
          </span>
        </div>
        <div class="flex flex-col gap-px">
          {render_slot(section)}
        </div>
      </div>
      <div :if={@inner_block != []}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # --- empty_state -----------------------------------------------------------

  @doc """
  Placeholder for empty lists / unconfigured surfaces.

      <.empty_state title="No sessions" description="Create one to start chatting">
        <:action>
          <.button variant="primary">+ New session</.button>
        </:action>
      </.empty_state>
  """
  attr(:title, :string, required: true)
  attr(:description, :string, default: nil)
  attr(:icon, :string, default: "📭")
  slot(:action)

  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-12 px-4 text-center">
      <div class="text-3xl mb-3 opacity-50">{@icon}</div>
      <div class="text-sm font-medium text-zinc-700 dark:text-zinc-300">{@title}</div>
      <div :if={@description} class="text-xs text-zinc-500 mt-1 max-w-xs">{@description}</div>
      <div :if={@action != []} class="mt-4">
        {render_slot(@action)}
      </div>
    </div>
    """
  end

  # --- form_field ------------------------------------------------------------

  @doc """
  Wrapped form input with label + help + error slot.

      <.form_field name="email" type="text" label="Email" required>
        <:help>We never share your email.</:help>
      </.form_field>
  """
  attr(:name, :string, required: true)
  attr(:type, :string, default: "text")
  attr(:label, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:placeholder, :string, default: nil)
  attr(:required, :boolean, default: false)
  attr(:error, :string, default: nil)
  attr(:class, :string, default: "")
  attr(:rest, :global, include: ~w(autocomplete pattern))
  slot(:help)

  def form_field(assigns) do
    ~H"""
    <div class={["flex flex-col gap-1", @class]}>
      <label class="text-xs font-medium text-zinc-700 dark:text-zinc-300">
        {@label}
        <span :if={@required} class="text-rose-600 dark:text-rose-400">*</span>
      </label>
      <input
        type={@type}
        name={@name}
        value={@value}
        placeholder={@placeholder}
        required={@required}
        class={[
          "px-2 py-1.5 text-xs border rounded-md font-mono",
          (@error && "border-rose-400 dark:border-rose-600") || "border-zinc-300 dark:border-zinc-700"
        ]}
        {@rest}
      />
      <div :if={@help != []} class="text-[11px] text-zinc-500">{render_slot(@help)}</div>
      <div :if={@error} class="text-[11px] text-rose-600 dark:text-rose-400">{@error}</div>
    </div>
    """
  end

  # --- uri_chip --------------------------------------------------------------

  @doc """
  Monospaced pill displaying a URI.

      <.uri_chip uri={@current_entity_uri} />
      <.uri_chip uri="entity://user/system/admin" copyable />
  """
  attr(:uri, :any, required: true)
  attr(:copyable, :boolean, default: false)
  attr(:class, :string, default: "")

  def uri_chip(assigns) do
    str = uri_to_string(assigns.uri)
    assigns = assign(assigns, :str, str)

    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1 px-2 py-0.5 rounded-md text-[11px] font-mono",
        "bg-zinc-100 dark:bg-zinc-900 text-zinc-700 dark:text-zinc-300 border border-zinc-200 dark:border-zinc-800",
        @class
      ]}
      title={if @copyable, do: "Click to copy"}
    >
      {@str}
    </span>
    """
  end

  # --- toolbar ---------------------------------------------------------------

  @doc """
  Small button cluster for editor-tab actions.

      <.toolbar>
        <.button size="sm" variant="ghost">↻</.button>
        <.button size="sm" variant="ghost">⚙</.button>
      </.toolbar>
  """
  attr(:class, :string, default: "")
  slot(:inner_block, required: true)

  def toolbar(assigns) do
    ~H"""
    <div class={["inline-flex items-center gap-px", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # --- tooltip ---------------------------------------------------------------

  @doc """
  Hover tooltip wrapper.

      <.tooltip text="Open Sessions">
        <.icon name="message-square" />
      </.tooltip>
  """
  attr(:text, :string, required: true)
  attr(:class, :string, default: "")
  slot(:inner_block, required: true)

  def tooltip(assigns) do
    ~H"""
    <span class={["group relative inline-flex", @class]}>
      {render_slot(@inner_block)}
      <span class="absolute left-full ml-2 top-1/2 -translate-y-1/2 px-2 py-1 bg-zinc-900 text-white text-[11px] rounded whitespace-nowrap opacity-0 group-hover:opacity-100 transition-opacity pointer-events-none z-50">
        {@text}
      </span>
    </span>
    """
  end

  # --- icon ------------------------------------------------------------------

  @doc """
  SVG icon using Heroicons (24/outline). Phase 9 — replaced the
  Phase 8 emoji fallback. Logical names like `message-square` are
  mapped to Heroicons canonical names (`chat-bubble-left-right`)
  via `heroicon_name/1`.

      <.icon name="message-square" />
      <.icon name="settings" size="md" />

  Reads SVG from `deps/heroicons/optimized/24/outline/<name>.svg`
  at compile time (via `__heroicon__/1` macro-ish function lookup).
  Unknown names fall back to the small text glyph.
  """
  attr(:name, :string, required: true)
  attr(:size, :string, default: "sm", values: ~w(xs sm md lg))
  attr(:class, :string, default: "")

  def icon(assigns) do
    {svg_path, fallback} = resolve_icon(assigns.name)
    svg = if svg_path, do: load_svg(svg_path), else: nil
    assigns = assigns |> assign(:svg, svg) |> assign(:fallback, fallback)

    ~H"""
    <span
      class={[
        "inline-flex items-center justify-center leading-none select-none",
        @size == "xs" && "w-3 h-3",
        @size == "sm" && "w-4 h-4",
        @size == "md" && "w-5 h-5",
        @size == "lg" && "w-6 h-6",
        @class
      ]}
      aria-label={@name}
    >
      <%= if @svg do %>
        {Phoenix.HTML.raw(@svg)}
      <% else %>
        {@fallback}
      <% end %>
    </span>
    """
  end

  # Map our logical icon names → Heroicons (24/outline) basenames.
  defp resolve_icon(name) do
    case heroicon_for(name) do
      nil -> {nil, text_fallback(name)}
      hname -> {heroicons_path(hname), text_fallback(name)}
    end
  end

  defp heroicon_for("message-square"), do: "chat-bubble-left-right"
  defp heroicon_for("folder"), do: "folder"
  defp heroicon_for("users"), do: "users"
  defp heroicon_for("route"), do: "arrows-right-left"
  defp heroicon_for("puzzle"), do: "puzzle-piece"
  defp heroicon_for("activity"), do: "chart-bar"
  defp heroicon_for("settings"), do: "cog-6-tooth"
  defp heroicon_for("search"), do: "magnifying-glass"
  defp heroicon_for("bell"), do: "bell"
  defp heroicon_for("help"), do: "question-mark-circle"
  defp heroicon_for("terminal"), do: "command-line"
  defp heroicon_for("chevron-right"), do: "chevron-right"
  defp heroicon_for("chevron-left"), do: "chevron-left"
  defp heroicon_for("chevron-down"), do: "chevron-down"
  defp heroicon_for("x"), do: "x-mark"
  defp heroicon_for("plus"), do: "plus"
  defp heroicon_for("bug"), do: "bug-ant"
  defp heroicon_for("dashboard"), do: "rectangle-group"
  defp heroicon_for("sun"), do: "sun"
  defp heroicon_for("moon"), do: "moon"
  # Phase 8c PR-O (Username & Auth UI) — pencil/check for inline edit affordances.
  defp heroicon_for("pencil"), do: "pencil"
  defp heroicon_for("check"), do: "check"
  defp heroicon_for("envelope"), do: "envelope"
  defp heroicon_for("paper-airplane"), do: "paper-airplane"
  defp heroicon_for(_), do: nil

  defp text_fallback("dot"), do: "•"
  defp text_fallback("chevron-right"), do: "›"
  defp text_fallback("chevron-left"), do: "‹"
  defp text_fallback("chevron-down"), do: "⌄"
  defp text_fallback("x"), do: "✕"
  defp text_fallback("plus"), do: "+"
  defp text_fallback(_), do: "◇"

  # Heroicons SVG source path. The :heroicons dep is checked out under
  # the umbrella root's deps/. Use Application.app_dir for stability —
  # works whether ezagent_domain_ui has a priv dir or not (deps/heroicons
  # is co-located with the umbrella's _build, not with any individual app).
  defp heroicons_path(basename) do
    umbrella_root = File.cwd!()

    # Try umbrella root first (works from `mix phx.server` at root)
    candidate1 =
      Path.join([
        umbrella_root,
        "deps",
        "heroicons",
        "optimized",
        "24",
        "outline",
        "#{basename}.svg"
      ])

    if File.exists?(candidate1) do
      candidate1
    else
      # Fallback: walk from any app's :code.lib_dir to umbrella deps
      candidate2 =
        :code.lib_dir(:ezagent_domain_ui)
        |> to_string()
        |> Path.join([
          "..",
          "..",
          "..",
          "deps",
          "heroicons",
          "optimized",
          "24",
          "outline",
          "#{basename}.svg"
        ])
        |> Path.expand()

      candidate2
    end
  end

  # File reads happen at runtime; cached by the BEAM filesystem cache.
  # For higher perf, Phase 9+ can compile-time inline via @external_resource.
  defp load_svg(path) do
    case File.read(path) do
      {:ok, content} ->
        # Strip leading XML/comment + inject default classes for sizing
        # parent span already constrains w/h, so we just remove any
        # width/height attrs on the <svg> root to let parent control size.
        content
        |> String.replace(~r/width="[^"]*"/, "")
        |> String.replace(~r/height="[^"]*"/, "")
        |> String.replace("<svg", ~s(<svg class="w-full h-full" stroke-width="1.5"))

      {:error, _} ->
        nil
    end
  end

  # --- uri_picker ------------------------------------------------------------

  @doc """
  URI selector component — combobox (`:single`) or tag-input
  (`:multi`). V1 UI PR-1 (SPEC §1.2).

  Replaces the raw URI text inputs across the routing + workspace
  forms. A **stateless** `Phoenix.Component` — it does NOT query
  registries. The host LiveView (Tier-3) computes `options` via
  `Ezagent.UI.UriOptions.*` and passes them in; this keeps the atom
  registry-dependency-free (3-layer architecture invariant).

      <.uri_picker name="rule[matcher_arg]" mode={:single} options={@entity_options} />
      <.uri_picker name="rule[receivers]" mode={:multi} options={@receiver_options} />

  ## Behaviour

  - `:single` → a combobox: a text input with a filtered dropdown of
    matching options. A hidden `<input type="hidden" name={@name}>`
    carries the chosen URI.
  - `:multi` → a tag-input with autocomplete: chosen URIs render as
    removable chips; picking from the filtered list adds a chip. Each
    chip emits `<input type="hidden" name={@name <> "[]"}>` so the form
    submit yields the list.

  ## JS hook + diff protection

  The component root `<div>` carries `phx-hook="UriPicker"`. The
  mutable subtree (dropdown, chip list, hidden inputs) is wrapped in
  `phx-update="ignore"` so a LiveView re-render does not wipe the
  hook-mutated DOM. The immutable `options` list rides in a
  `data-options` JSON attribute on the root, which the hook reads on
  `mounted()` and re-reads on `updated()` (workspace switch /
  reconnect — the hook prunes selections no longer present, SPEC §1.6).

  Client-side filtering is UX only — the server revalidates every
  submitted URI (`Ezagent.UI.UriOptions.valid_for?/4`).
  """
  attr(:name, :string, required: true)
  attr(:mode, :atom, default: :single, values: [:single, :multi])
  attr(:options, :list, required: true)
  attr(:kinds, :list, default: [:entity, :session])
  attr(:value, :any, default: nil)
  attr(:placeholder, :string, default: nil)
  attr(:allow_freetext, :boolean, default: false)
  attr(:label, :string, default: nil)
  attr(:required, :boolean, default: false)
  attr(:id, :string, default: nil)
  attr(:class, :string, default: nil)

  def uri_picker(assigns) do
    assigns =
      assigns
      |> assign(:id, assigns.id || "uri-picker-" <> uri_picker_slug(assigns.name))
      |> assign(:options_json, Jason.encode!(uri_picker_options(assigns.options)))
      |> assign(:selected, uri_picker_selected(assigns.value, assigns.mode))
      |> assign(:freetext_value, uri_picker_freetext_value(assigns.value, assigns.mode))

    ~H"""
    <div
      id={@id}
      phx-hook="UriPicker"
      data-options={@options_json}
      data-mode={Atom.to_string(@mode)}
      data-name={@name}
      data-allow-freetext={to_string(@allow_freetext)}
      class={["flex flex-col gap-1", @class]}
    >
      <label :if={@label} class="text-xs font-medium text-zinc-700 dark:text-zinc-300">
        {@label}
        <span :if={@required} class="text-rose-600 dark:text-rose-400">*</span>
      </label>

      <%!--
        Mutable subtree — JS-owned. phx-update="ignore" so a LiveView
        re-render never wipes hook-mutated chips / dropdown / hidden
        inputs. Pre-seeded server-side so a no-JS dead-render still
        submits sensibly; the hook re-hydrates from data-options.
      --%>
      <div data-uri-picker-body phx-update="ignore" id={@id <> "-body"}>
        <div :if={@mode == :multi} data-uri-picker-chips class="flex flex-wrap gap-1 mb-1">
          <span
            :for={uri <- @selected}
            data-uri-picker-chip
            class="inline-flex items-center gap-1 px-2 py-0.5 rounded-md text-[11px] font-mono bg-zinc-100 dark:bg-zinc-900 text-zinc-700 dark:text-zinc-300 border border-zinc-200 dark:border-zinc-800"
          >
            <span data-uri-picker-chip-label>{uri}</span>
            <button
              type="button"
              data-uri-picker-chip-remove
              data-uri={uri}
              class="text-zinc-400 hover:text-rose-600 dark:hover:text-rose-400"
              aria-label="Remove"
            >
              ✕
            </button>
            <input type="hidden" name={@name <> "[]"} value={uri} data-uri-picker-hidden />
          </span>
        </div>

        <input
          :if={@mode == :single}
          type="hidden"
          name={@name}
          value={List.first(@selected)}
          data-uri-picker-hidden
        />

        <div class="relative">
          <input
            type="text"
            data-uri-picker-filter
            value={uri_picker_filter_seed(@selected, @mode)}
            placeholder={@placeholder || uri_picker_default_placeholder(@kinds)}
            autocomplete="off"
            class="w-full px-2 py-1.5 text-xs border rounded-md font-mono border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
          />
          <ul
            data-uri-picker-dropdown
            class="hidden absolute z-20 mt-1 w-full max-h-56 overflow-auto rounded-md border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 shadow-lg text-xs"
          >
          </ul>
          <p
            data-uri-picker-empty
            class="hidden absolute z-20 mt-1 w-full rounded-md border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 shadow-lg text-[11px] text-zinc-500 dark:text-zinc-400 px-2 py-1.5"
          >
            No {uri_picker_kinds_phrase(@kinds)} match.
          </p>
        </div>
      </div>

      <details :if={@allow_freetext} data-uri-picker-freetext class="mt-1">
        <summary class="cursor-pointer text-[11px] text-zinc-500 dark:text-zinc-400">
          or enter a URI manually
        </summary>
        <input
          type="text"
          data-uri-picker-freetext-input
          name={uri_picker_freetext_name(@name, @mode)}
          value={@freetext_value}
          disabled
          placeholder="entity://agent/default/cc_demo"
          class="mt-1 w-full px-2 py-1.5 text-xs border rounded-md font-mono border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
        />
      </details>
    </div>
    """
  end

  # The hook reads this — keep only the keys it needs (uri/label/
  # kind/flavor). Drop anything else a caller's option map carries.
  defp uri_picker_options(options) when is_list(options) do
    Enum.map(options, fn opt ->
      %{
        "uri" => Map.get(opt, :uri) || Map.get(opt, "uri"),
        "label" => Map.get(opt, :label) || Map.get(opt, "label"),
        "kind" => uri_picker_kind_str(Map.get(opt, :kind) || Map.get(opt, "kind")),
        "flavor" => Map.get(opt, :flavor) || Map.get(opt, "flavor")
      }
    end)
  end

  defp uri_picker_kind_str(k) when is_atom(k) and not is_nil(k), do: Atom.to_string(k)
  defp uri_picker_kind_str(k) when is_binary(k), do: k
  defp uri_picker_kind_str(_), do: nil

  defp uri_picker_selected(nil, :single), do: []
  defp uri_picker_selected("", :single), do: []
  defp uri_picker_selected(v, :single) when is_binary(v), do: [v]
  defp uri_picker_selected(v, :multi) when is_list(v), do: Enum.filter(v, &(&1 != ""))
  defp uri_picker_selected(_, _), do: []

  # When `allow_freetext` and the current value is NOT one of the
  # options, the value is treated as the free-text seed. The hook
  # decides at runtime which input is enabled; this seeds the markup.
  defp uri_picker_freetext_value(v, :single) when is_binary(v), do: v
  defp uri_picker_freetext_value(_, _), do: ""

  # For :single the filter input shows the current selection; for
  # :multi it stays empty (selections are chips above it).
  defp uri_picker_filter_seed([uri | _], :single), do: uri
  defp uri_picker_filter_seed(_, _), do: ""

  # Free-text shares the SAME submit param as the picker hidden field
  # (SPEC §1.4). The hook disables exactly one source so there is no
  # merge / precedence rule.
  defp uri_picker_freetext_name(name, :multi), do: name <> "[]"
  defp uri_picker_freetext_name(name, :single), do: name

  defp uri_picker_default_placeholder([:entity]), do: "Search entities…"
  defp uri_picker_default_placeholder([:session]), do: "Search sessions…"
  defp uri_picker_default_placeholder(_), do: "Search entities + sessions…"

  defp uri_picker_kinds_phrase([:entity]), do: "entities"
  defp uri_picker_kinds_phrase([:session]), do: "sessions"
  defp uri_picker_kinds_phrase(_), do: "entities or sessions"

  defp uri_picker_slug(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9]+/, "-")
    |> String.trim("-")
  end
end
