defmodule Ezagent.World.PresenterCapsTest do
  use ExUnit.Case, async: true

  alias Ezagent.Capability
  alias Ezagent.World.PresenterCaps

  test "current artifacts replace mount-time artifacts with the same capability identity" do
    session = Ezagent.URI.session(:system, :generic, "presenter-caps")
    workspace = Capability.workspace_of(session)

    mounted =
      Capability.cap(:session, Ezagent.ActionSet.Session, :send, session, workspace)
      |> Map.merge(%{key_id: "old", signature: "old"})

    current = %{mounted | key_id: "current", signature: "current"}

    assert [^current] = PresenterCaps.merge([mounted], [current]) |> MapSet.to_list()
  end

  test "mount-only artifacts remain available for ephemeral bootstrap authority" do
    session = Ezagent.URI.session(:system, :generic, "presenter-bootstrap")

    mounted =
      Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :join,
        session,
        Capability.workspace_of(session)
      )

    assert MapSet.member?(PresenterCaps.merge([mounted], []), mounted)
  end
end
