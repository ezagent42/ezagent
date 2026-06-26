defmodule EzagentPluginAdvisor.Template.AdvisorSessionDirectlyCreatableTest do
  @moduledoc """
  F3 finding-specific guard — `session.advisor` must NOT be offered by the
  generic "New session" picker. Its `instantiate/3` requires an `operator_uri`
  the generic picker does not supply, so before the fix advisor sorted ahead of
  "default" and became the dropdown default → every default create failed closed
  with `{:invalid_template, …}` (silently). Declaring `directly_creatable? =>
  false` keeps it out of the generic picker.
  """
  use ExUnit.Case, async: true

  alias EzagentPluginAdvisor.Template.AdvisorSession

  test "advisor declares itself NOT directly creatable from the generic picker" do
    refute AdvisorSession.directly_creatable?()
  end

  test "the core resolver agrees advisor is not directly creatable" do
    refute Ezagent.Kind.Template.directly_creatable?(AdvisorSession)
  end
end
