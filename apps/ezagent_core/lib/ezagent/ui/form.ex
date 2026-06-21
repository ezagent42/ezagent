defmodule Ezagent.UI.Form do
  @moduledoc """
  Form schema self-description behaviour — Phase 5 PR 2.

  Any module (Template Class, Behavior action, Synthetic Kind) implements
  this to declare its operator-facing form fields. UI surfaces (LV
  add-template form, future UsersLive cap form, etc.) read the schema
  via `form_fields/0` and render generically — no LV file needs to know
  what the module does.

  This is the meta-enabler that lets future plugin authors ship operator UI
  without touching the host web app.

  ## Callback

      @callback form_fields() :: [field()]

      @type field :: %{
              name: String.t(),           # form param key + storage key
              type: :text | :path | :uri | :select,
              label: String.t(),          # human-facing label
              required: boolean(),
              placeholder: String.t() | nil,
              options: [String.t()] | nil # only for :select
            }

  ## Field types (v1 — frozen at 4 per SPEC_REVIEW R6)

  - `:text` — free string
  - `:path` — filesystem path; UI hint = monospace input
  - `:uri` — `URI.parse`-able; UI hint = monospace input + scheme validation
  - `:select` — one of `options`; UI hint = dropdown

  ## Translation back to template data

  The LV form submits a flat params map keyed by field `name`. The
  UI consumer turns it into the Template Class's `template_data` map
  by:

      data = Enum.into(params, %{"class" => template_class.template_name()})

  Template Classes that need richer translation override `form_to_args/1`.
  """

  @type field_type :: :text | :path | :uri | :select

  @type field :: %{
          required(:name) => String.t(),
          required(:type) => field_type(),
          required(:label) => String.t(),
          optional(:required) => boolean(),
          optional(:placeholder) => String.t() | nil,
          optional(:options) => [String.t()] | nil,
          optional(:default) => String.t() | nil
        }

  @callback form_fields() :: [field()]
  @callback form_to_args(params :: map()) :: map()

  @optional_callbacks [form_to_args: 1]

  @doc """
  Default form_to_args/1 — pass-through with the implementing module's
  template_name added under `"class"`.

  Template Classes get this for free unless they need custom mapping
  (e.g. coercing CSV → list, merging defaults).
  """
  def default_form_to_args(module, params) do
    template_name =
      if function_exported?(module, :template_name, 0) do
        module.template_name()
      else
        nil
      end

    base = if template_name, do: %{"class" => template_name}, else: %{}
    Enum.into(params, base)
  end

  @doc """
  True iff `module` implements `Ezagent.UI.Form` (i.e. exports
  `form_fields/0`). Used by UI consumers to decide whether to render
  the schema-driven form or fall back to JSON paste.
  """
  def implements?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :form_fields, 0)
  end

  @doc """
  Render-friendly enumeration of registered Template Classes that
  implement `Ezagent.UI.Form`. Returns `[{template_name, module, fields}]`
  sorted by name.
  """
  def list_form_classes do
    Ezagent.TemplateRegistry.registered_template_names()
    |> Enum.map(fn name ->
      with {:ok, module} <- Ezagent.TemplateRegistry.lookup(name),
           true <- implements?(module) do
        {name, module, module.form_fields()}
      else
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {n, _, _} -> n end)
  end
end
