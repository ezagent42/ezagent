defmodule EzagentPluginEmail.PluginWiringTest do
  @moduledoc """
  #88 PR-1 (MED 7 / §4.7) — the plugin declares the email external-mirror
  adapter + the per-adapter cap marker so the bind facade's Check 2 and the
  `AdapterCapSubjectRegisteredTest` invariant are satisfied.
  """
  use ExUnit.Case, async: true

  alias EzagentPluginEmail.Application, as: App

  test "adapters/0 declares the {Adapter, Binding} :push pair" do
    assert App.adapters() == [{Ezagent.Email.Adapter, Ezagent.Email.Binding}]
  end

  test "behaviors/0 registers the allow_email cap marker on the Session Kind" do
    assert {Ezagent.Entity.Session, :allow_email,
            EzagentPluginEmail.Behavior.ExternalAdapter.Email.Allow} in App.behaviors()
  end

  test "the adapter's cap_subject points at the SAME registered marker module" do
    %{behavior_module: mod} = Ezagent.Email.Adapter.cap_subject()

    # The cap_subject module must be exactly the one behaviors/0 registers,
    # else AdapterCapSubjectRegisteredTest would have no matching triple.
    assert mod == EzagentPluginEmail.Behavior.ExternalAdapter.Email.Allow
    assert {Ezagent.Entity.Session, :allow_email, mod} in App.behaviors()
  end

  test "Grill-5: the adapter and binding name each other, distinct modules" do
    assert Ezagent.Email.Adapter.binding_module() == Ezagent.Email.Binding
    assert Ezagent.Email.Binding.adapter_module() == Ezagent.Email.Adapter
    refute Ezagent.Email.Adapter == Ezagent.Email.Binding
  end
end
