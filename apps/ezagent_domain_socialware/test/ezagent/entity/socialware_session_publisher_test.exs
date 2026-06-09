defmodule Ezagent.Entity.SocialwareSessionPublisherTest do
  use ExUnit.Case, async: false

  alias Ezagent.Entity.SocialwareSession

  # `Ezagent.Kind.behaviors_of/1` gates on `function_exported?/3`, which under
  # Elixir 1.19 does NOT auto-load the target module. Force it loaded so the
  # introspection sees the `behaviors/0` callback (test-harness bind-point).
  setup_all do
    Code.ensure_loaded!(SocialwareSession)
    :ok
  end

  test "SocialwareSession composes Publisher.SessionImpl (owns the :publisher slice)" do
    behaviors = Ezagent.Kind.behaviors_of(SocialwareSession)
    assert Ezagent.Behavior.Publisher.SessionImpl in behaviors

    slice_keys = Enum.map(behaviors, & &1.state_slice())
    assert :publisher in slice_keys
  end

  test "SocialwareSession declares the Publisher behaviour contract" do
    # Each `@behaviour` is a separate attribute entry, so a single keyword
    # lookup only yields the first (`Ezagent.Kind`). Aggregate all of them.
    declared_behaviours =
      SocialwareSession.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert Ezagent.Behavior.Publisher in declared_behaviours
    assert function_exported?(SocialwareSession, :subscribe_from, 4)
    assert function_exported?(SocialwareSession, :snapshot, 2)
    assert function_exported?(SocialwareSession, :history, 4)
    assert SocialwareSession.history_retention() == 100
  end
end
