defmodule Ezagent.Kind.TemplateDirectlyCreatableTest do
  @moduledoc """
  F3 declared-capability seam — `Ezagent.Kind.Template.directly_creatable?/1`
  resolves whether a Template Class can be instantiated from the generic
  "New session" picker (which supplies only the universal create args). A Class
  whose `instantiate/3` needs extra, picker-unknown args (e.g. advisor's
  `operator_uri`) overrides `directly_creatable?/0 => false` so the picker never
  offers it (and never fails closed with `{:invalid_template, …}`).
  """
  use ExUnit.Case, async: true

  alias Ezagent.Kind.Template

  defmodule Creatable do
    def template_name, do: "session.creatable"
    def directly_creatable?, do: true
  end

  defmodule NotCreatable do
    def template_name, do: "session.advisor_like"
    def directly_creatable?, do: false
  end

  defmodule NoCallback do
    def template_name, do: "session.generic"
  end

  test "honors an explicit directly_creatable?/0 => true" do
    assert Template.directly_creatable?(Creatable) == true
  end

  test "honors an explicit directly_creatable?/0 => false" do
    refute Template.directly_creatable?(NotCreatable)
  end

  test "defaults to true when the Class omits the callback" do
    assert Template.directly_creatable?(NoCallback) == true
  end
end
