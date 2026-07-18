defmodule Ezagent.UI.AuthorizeViewTest do
  @moduledoc """
  T2-2b — `SessionView.authorize_view/3`, the UNIFIED per-view cap gate: a
  cap-gated view (one declaring `view_behavior/0`) is visible only to a caller
  holding its `<sw>_render` cap; a view with no backing behavior is not gated.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.UI.SessionView

  # A cap-only render ActionSet (the HelloRender shape).
  defmodule TestRender do
    @moduledoc false
    use Ezagent.Lifecycle
    @impl Ezagent.ActionSet
    def actions, do: [:test_render]
    @impl Ezagent.ActionSet
    def cap_subjects, do: [{:test_render, "test render"}]
    @impl Ezagent.ActionSet
    def dispatchable?, do: false
    @impl Ezagent.ActionSet
    def interface, do: %{}
    @impl Ezagent.ActionSet
    def required_caps,
      do: %{test_render: Ezagent.Capability.cap(:session, __MODULE__, :test_render)}

    @impl Ezagent.ActionSet
    def data_owner(_), do: :any
  end

  # A gated SessionView backed by TestRender.
  defmodule GatedView do
    @moduledoc false
    @behaviour Ezagent.UI.SessionView
    def id, do: :gated
    def label, do: "Gated"
    def icon, do: "eye"
    def applies_to?(_), do: true
    def render(_), do: nil
    def view_behavior, do: TestRender
  end

  # A non-gated SessionView (no view_behavior/0).
  defmodule OpenView do
    @moduledoc false
    @behaviour Ezagent.UI.SessionView
    def id, do: :open
    def label, do: "Open"
    def icon, do: "eye"
    def applies_to?(_), do: true
    def render(_), do: nil
  end

  @session_uri Ezagent.URI.new!("session://system/generic/t2-authz")

  defp uniq, do: System.unique_integer([:positive])

  defp render_cap(grantee) do
    Ezagent.Test.CapHelper.signed_fixture_cap!(
      @session_uri,
      :session,
      TestRender,
      :test_render,
      grantee
    )
  end

  defp live_user(caps_or_builder) do
    uri = Ezagent.URI.new!("entity://system/user/authz-#{uniq()}")
    caps = if is_function(caps_or_builder, 1), do: caps_or_builder.(uri), else: caps_or_builder
    {:ok, _} = Ezagent.Users.create_read_only(uri, caps)
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  test "grants a gated view to a caller holding the render cap" do
    caller = live_user(fn grantee -> [render_cap(grantee)] end)
    assert SessionView.authorize_view(GatedView, caller, @session_uri)
  end

  test "denies a gated view to a caller lacking the render cap" do
    caller = live_user([])
    refute SessionView.authorize_view(GatedView, caller, @session_uri)
  end

  test "denies a gated view to a nil caller" do
    refute SessionView.authorize_view(GatedView, nil, @session_uri)
  end

  test "a non-gated view (no view_behavior) is always authorized" do
    caller = live_user([])
    assert SessionView.authorize_view(OpenView, caller, @session_uri)
    assert SessionView.authorize_view(OpenView, nil, @session_uri)
  end

  test "backing_behavior/1 reports the declared render ActionSet or nil" do
    assert SessionView.backing_behavior(GatedView) == TestRender
    assert SessionView.backing_behavior(OpenView) == nil
  end
end
