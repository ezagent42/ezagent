defmodule Ezagent.Socialware.AnonViewCapsTest do
  @moduledoc """
  T2-2b — `Installation.anon_view_caps/1` is the fine-grained half of the
  two-layer view gate: for a session with a MIXED install set (one public
  definition + one private), an anonymous visitor is minted the view read-caps of
  the PUBLIC definition's views ONLY. The private definition's view contributes no
  cap, so the anon cannot render it.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.{Definition, DefinitionRegistry, Installation}

  # Two minimal cap-only view read ActionSets (the HelloRender shape), each with a
  # UNIQUE render action — stand-ins for hello_render / kanban_render.
  defmodule PublicRender do
    @moduledoc false
    use Ezagent.Lifecycle
    @impl Ezagent.ActionSet
    def actions, do: [:pub_render]
    @impl Ezagent.ActionSet
    def cap_subjects, do: [{:pub_render, "public view render"}]
    @impl Ezagent.ActionSet
    def dispatchable?, do: false
    @impl Ezagent.ActionSet
    def interface, do: %{}
    @impl Ezagent.ActionSet
    def required_caps,
      do: %{pub_render: Ezagent.Capability.cap(:session, __MODULE__, :pub_render)}

    @impl Ezagent.ActionSet
    def data_owner(_), do: :any
  end

  defmodule PrivateRender do
    @moduledoc false
    use Ezagent.Lifecycle
    @impl Ezagent.ActionSet
    def actions, do: [:priv_render]
    @impl Ezagent.ActionSet
    def cap_subjects, do: [{:priv_render, "private view render"}]
    @impl Ezagent.ActionSet
    def dispatchable?, do: false
    @impl Ezagent.ActionSet
    def interface, do: %{}
    @impl Ezagent.ActionSet
    def required_caps,
      do: %{priv_render: Ezagent.Capability.cap(:session, __MODULE__, :priv_render)}

    @impl Ezagent.ActionSet
    def data_owner(_), do: :any
  end

  @workspace_uri Ezagent.URI.new!("workspace://system")
  @actor Ezagent.URI.new!("entity://system/user/admin")

  defp uniq, do: System.unique_integer([:positive])

  defp write_def(name, view_mod, anon_access?) do
    {:ok, definition} =
      Definition.new(%{
        name: name,
        views: [view_mod],
        visibility_policy: %{publish_policy: :auto, web_anon_access: anon_access?}
      })

    {:ok, _obj} =
      DefinitionRegistry.write_definition(definition,
        workspace_uri: @workspace_uri,
        caller_workspace_uri: @workspace_uri,
        actor_uri: @actor
      )

    name
  end

  test "mints the public definition's view cap, NOT the private one's" do
    n = uniq()
    session_uri = Ezagent.URI.session("system", "generic", "t2-anon-#{n}")

    pub = write_def("t2-pub-#{n}", PublicRender, true)
    priv = write_def("t2-priv-#{n}", PrivateRender, false)

    :ok =
      Installation.install_template_installs(
        session_uri,
        @workspace_uri,
        %{installs: [pub, priv]},
        @actor
      )

    caps = Installation.anon_view_caps(session_uri)
    behaviors = Enum.map(caps, & &1.behavior)

    assert PublicRender in behaviors
    refute PrivateRender in behaviors

    # the minted cap is the concrete-session render cap authorize_view checks
    pub_cap = Enum.find(caps, &(&1.behavior == PublicRender))
    assert pub_cap.kind == :session
    assert pub_cap.action == :pub_render
    assert pub_cap.instance == Ezagent.URI.instance(session_uri)
    assert %URI{} = pub_cap.granted_by
  end
end
