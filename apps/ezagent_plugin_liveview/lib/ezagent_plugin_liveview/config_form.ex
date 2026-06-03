defmodule EzagentPluginLiveview.ConfigForm do
  @moduledoc """
  Per-flavor config form surface — "config_surface :form" V2 (#18).

  Layer-2 plugin composition (`ui-contract.md`): a stateless
  `Phoenix.Component` that renders the operator-facing config fields a
  Template Class self-describes via `Ezagent.UI.Form.form_fields/0`. The
  component knows NOTHING about any specific flavor — it consumes the
  generic field schema, so cc / codex / curl / np / echo (and any future
  flavor implementing the behaviour) get a config form for free.

  This extracts the field-rendering that was inlined in
  `WorkspaceDetailLive`'s "Add template" flow into a reusable surface so
  the add-template form AND future per-flavor config-edit surfaces render
  flavor config identically, without re-inlining the markup. North Star:
  plugin isolation — a flavor author touches only their own `form_fields/0`,
  never this file or any LV.

  ## Field schema (from `Ezagent.UI.Form`)

      %{
        name: String.t(),                # form param key + storage key
        type: :text | :path | :uri | :select,
        label: String.t(),
        required: boolean(),             # optional
        placeholder: String.t() | nil,   # optional
        options: [String.t()] | nil,     # :select only
        default: String.t() | nil        # optional
      }

  ## Usage

      # From a list of fields (e.g. the add-template flow already has them):
      <ConfigForm.config_fields fields={@fields} name_prefix="add_template" />

      # From a flavor — resolves the class' fields via Ezagent.UI.Form:
      <ConfigForm.flavor_config_fields flavor="codex" name_prefix="agent_config" />

  Inputs are namespaced `name="<name_prefix>[<field.name>]"` so the parent
  `<.form>` receives a nested params map keyed by `name_prefix`. In edit
  mode, pass `values` (a `%{field_name => current_value}` map) to pre-fill.
  """

  use Phoenix.Component
  use Gettext, backend: EzagentPluginLiveview.Gettext

  alias Ezagent.AgentFlavorRegistry
  alias Ezagent.UI.Form

  @doc """
  Render the config fields described by `fields`.

  - `fields` — the `Ezagent.UI.Form.form_fields/0` list.
  - `name_prefix` — form-param namespace (inputs become
    `name="<name_prefix>[<field.name>]"`).
  - `values` — optional `%{field_name => value}` for edit mode (pre-fills
    inputs). Falls back to each field's `:default` then `""`.
  """
  attr :fields, :list, required: true
  attr :name_prefix, :string, required: true
  attr :values, :map, default: %{}

  def config_fields(assigns) do
    ~H"""
    <div
      :for={field <- @fields}
      class="grid grid-cols-[200px_1fr] gap-1.5 mb-2"
      data-config-field={field.name}
    >
      <label class="text-xs text-zinc-500 self-center">
        {field.label}{if Map.get(field, :required, false), do: " *", else: ""}
      </label>
      <%= case field.type do %>
        <% :select -> %>
          <select
            name={input_name(@name_prefix, field.name)}
            class="px-2 py-1 border border-zinc-300 dark:border-zinc-700 rounded text-xs font-mono bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
          >
            <option
              :for={opt <- Map.get(field, :options, [])}
              value={opt}
              selected={opt == field_value(@values, field)}
            >
              {opt}
            </option>
          </select>
        <% :path -> %>
          <div class="flex flex-col gap-0.5">
            <input
              type="text"
              name={input_name(@name_prefix, field.name)}
              value={field_value(@values, field)}
              placeholder={Map.get(field, :placeholder, "/path/to/dir")}
              class={input_class_for(field.type)}
            />
            <span class="text-[10px] text-zinc-500">
              📁 {gettext("Filesystem path (server-side)")}
            </span>
          </div>
        <% _ -> %>
          <input
            type="text"
            name={input_name(@name_prefix, field.name)}
            value={field_value(@values, field)}
            placeholder={Map.get(field, :placeholder, "")}
            class={input_class_for(field.type)}
          />
      <% end %>
    </div>
    """
  end

  @doc """
  Render the config fields for a `flavor` by resolving its Template Class
  and reading `Ezagent.UI.Form.form_fields/0`.

  This is the "config_surface :form" entry point: given a flavor string,
  render the right config fields for that flavor. If the flavor is unknown
  or its Class does not implement the form behaviour, renders an explicit
  empty/JSON-escape-hatch hint rather than guessing fields (the JSON path
  is the existing real escape branch, not a degrade shim).
  """
  attr :flavor, :string, required: true
  attr :name_prefix, :string, required: true
  attr :values, :map, default: %{}

  def flavor_config_fields(assigns) do
    assigns = assign(assigns, :resolved, resolve_flavor_fields(assigns.flavor))

    ~H"""
    <%= case @resolved do %>
      <% {:ok, fields} -> %>
        <.config_fields fields={fields} name_prefix={@name_prefix} values={@values} />
      <% {:error, reason} -> %>
        <p class="text-[11px] text-zinc-500" data-config-form-unavailable={to_string(reason)}>
          {flavor_unavailable_text(reason, @flavor)}
        </p>
    <% end %>
    """
  end

  # Resolve flavor → template class → form_fields/0. Returns
  # `{:ok, fields}` or `{:error, :unknown_flavor | :no_form_behaviour}`.
  defp resolve_flavor_fields(flavor) when is_binary(flavor) do
    case AgentFlavorRegistry.lookup(flavor) do
      {:ok, %{template_class: tc}} ->
        if Form.implements?(tc) do
          {:ok, tc.form_fields()}
        else
          {:error, :no_form_behaviour}
        end

      _ ->
        {:error, :unknown_flavor}
    end
  end

  defp flavor_unavailable_text(:unknown_flavor, flavor),
    do: gettext("Unknown flavor %{flavor} — no config form available.", flavor: flavor)

  defp flavor_unavailable_text(:no_form_behaviour, flavor),
    do:
      gettext(
        "Flavor %{flavor} does not self-describe a config form — use the JSON escape hatch.",
        flavor: flavor
      )

  defp input_name(prefix, name), do: prefix <> "[" <> name <> "]"

  # Edit-mode value resolution: explicit value wins, then the field's
  # declared default, then "".
  defp field_value(values, field) do
    case Map.get(values, field.name) do
      nil -> Map.get(field, :default) || ""
      v -> v
    end
  end

  defp input_class_for(:path),
    do:
      "px-2 py-1 border border-zinc-300 dark:border-zinc-700 rounded text-xs font-mono bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"

  defp input_class_for(:uri),
    do:
      "px-2 py-1 border border-zinc-300 dark:border-zinc-700 rounded text-xs font-mono bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"

  defp input_class_for(_),
    do:
      "px-2 py-1 border border-zinc-300 dark:border-zinc-700 rounded text-xs bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100"
end
