defmodule EzagentDomainSocialware.PageViewTest do
  use EzagentCore.DataCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.Session
  alias EzagentDomainSocialware.PageView

  defp session_uri do
    Ezagent.URI.session(
      :team_alpha,
      :socialware,
      "page-view-#{System.unique_integer([:positive])}"
    )
  end

  test "renders the latest internal page tree" do
    surface = %{
      versions: %{
        1 => %{tree: %{type: "text", props: %{text: "old approved"}}, by_turn: "turn-1"},
        2 => %{
          tree: %{
            type: "container",
            props: %{class: "stack"},
            children: [
              %{type: "text", props: %{text: "latest draft"}},
              %{
                type: "table",
                props: %{
                  headers: ["Metric", "Value"],
                  rows: [["Latency", "12ms"], ["Errors", "0"]]
                }
              }
            ]
          },
          by_turn: "turn-2"
        }
      },
      approved: 1,
      version_seq: 2
    }

    html = render_component(&PageView.render/1, surface: surface, session_uri: session_uri())

    assert html =~ "latest draft"
    assert html =~ "Latency"
    assert html =~ "12ms"
    refute html =~ "old approved"
  end

  test "applies_to? only returns true for a live session with a :surface slice" do
    session_uri = session_uri()
    :ok = KindSnapshot.delete(URI.to_string(session_uri))

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.socialware_behaviors()
      })

    assert PageView.applies_to?(session_uri)
    refute PageView.applies_to?(Ezagent.URI.entity(:team_alpha, :agent, "not-a-session"))
  end
end
