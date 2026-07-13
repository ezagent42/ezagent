defmodule EzagentWeb.SessionConfigProjection do
  @moduledoc "Declared HTTP v1 safe subset of the canonical Session-Config contract."

  alias Ezagent.Session.Config
  alias Ezagent.Session.Config.Operation

  @safe_operations ~w(
    add_participant
    remove_member
    define_rule_set_rule
    define_prompt_template
    define_legend
    save_template_as
    list_templates
  )

  @spec names() :: [String.t()]
  @doc "Return the operation names exposed by HTTP v1."
  def names, do: @safe_operations

  @spec operation(String.t()) :: Operation.t() | nil
  @doc "Resolve an HTTP-exposed name to its canonical domain descriptor."
  def operation(name) when name in @safe_operations, do: Config.operation(name)
  def operation(_name), do: nil

  @spec schemas() :: [map()]
  @doc "Project the safe subset using the domain's exact canonical schemas."
  def schemas do
    Enum.map(@safe_operations, fn name ->
      name |> Config.operation() |> Operation.schema()
    end)
  end
end
