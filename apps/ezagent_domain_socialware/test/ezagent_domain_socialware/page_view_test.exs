defmodule EzagentDomainSocialware.PageViewTest do
  use EzagentCore.DataCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.Session
  alias Ezagent.Invocation
  alias EzagentDomainSocialware.PageView

  defp owner, do: Ezagent.Socialware.TestCapHelper.owner(:team_alpha, "page-view-owner")
  defp stranger, do: Ezagent.Socialware.TestCapHelper.owner(:team_alpha, "page-view-stranger")

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

  describe "applies_to? — caller-authorizing (PR-2)" do
    test "an owner/member sees the view applies; a non-member / nil caller does not" do
      session_uri = session_uri()
      :ok = KindSnapshot.delete(URI.to_string(session_uri))

      {:ok, _pid} =
        Ezagent.Socialware.TestCapHelper.spawn_session(%{
          uri: session_uri,
          owner_uri: owner(),
          behaviors: Ezagent.Entity.Session.socialware_behaviors()
        })

      assert PageView.applies_to?(session_uri, owner())
      refute PageView.applies_to?(session_uri, stranger())
      # The behaviour's caller-less /1 form fails closed on a private session.
      refute PageView.applies_to?(session_uri)
      refute PageView.applies_to?(Ezagent.URI.entity(:team_alpha, :agent, "not-a-session"))
    end
  end

  describe "render/1 surface read routes through the chokepoint (PR-2)" do
    test "a caller-less render fails closed to the empty state even with an approved page; an authorized caller renders it" do
      session_uri = session_uri()
      :ok = KindSnapshot.delete(URI.to_string(session_uri))

      {:ok, _pid} =
        Ezagent.Socialware.TestCapHelper.spawn_session(%{
          uri: session_uri,
          owner_uri: owner(),
          behaviors: Ezagent.Entity.Session.socialware_behaviors()
        })

      :ok =
        Ezagent.WorkspaceRegistry.bind(session_uri, Ezagent.Capability.workspace_of(session_uri))

      approve_page(session_uri, %{type: "text", props: %{text: "chokepoint page"}})

      # No caller in assigns → the surface read is unauthorized → empty state
      # (before PR-2 this read the live :surface slice with NO authorization and
      # rendered "chokepoint page").
      callerless = render_component(&PageView.render/1, session_uri: session_uri)
      assert callerless =~ "No page version yet."
      refute callerless =~ "chokepoint page"

      # An authorized caller renders the page through the chokepoint.
      authorized =
        render_component(&PageView.render/1, session_uri: session_uri, caller_uri: owner())

      assert authorized =~ "chokepoint page"
    end
  end

  # Drive a full turn to APPROVE a page version (auto-approve on settle) — the
  # same seeding path the external-render integration test exercises.
  defp approve_page(session_uri, page_tree) do
    {:ok, %{turn_id: turn_id}} =
      dispatch(session_uri, :turn, :open, %{trigger: %{message_id: "m1"}, opened_at: 1})

    {:ok, _} =
      dispatch(session_uri, :turn, :dispatch, %{
        turn_id: turn_id,
        subtasks: [%{id: :page, mention: agent_uri("page"), prompt: "render"}]
      })

    {:ok, _} =
      dispatch(session_uri, :turn, :deliver, %{
        turn_id: turn_id,
        subtask_id: :page,
        card_ref: %{kind: :page, tree: page_tree}
      })

    {:ok, %{version: version}} =
      dispatch(session_uri, :turn, :compose, %{turn_id: turn_id, result_refs: []})

    {:ok, %{status: :settled}} = dispatch(session_uri, :turn, :settle, %{turn_id: turn_id})

    wait_until(fn ->
      {:ok, surface} = Ezagent.Kind.read(session_uri, :surface, spawn: :never)
      surface.approved == version
    end)

    version
  end

  defp agent_uri(name), do: Ezagent.URI.entity(:team_alpha, :agent, name)

  defp target(session_uri, behavior, action) do
    Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{behavior}.#{action}")
  end

  defp dispatch(session_uri, behavior, action, args) do
    target = target(session_uri, behavior, action)
    caller = owner()

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: caller,
        authenticated_principal: caller,
        caps: Ezagent.Socialware.TestCapHelper.lifecycle_caps(session_uri, caller, target),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end
end
