defmodule Ezagent.World.MalformedSessionInputTest do
  @moduledoc """
  P2 test-supplement (priority #3) — hostile/malformed input on world's public
  surfaces must degrade cleanly, never crash (no 500s).

  Two entry points:

    * `EzagentPluginWorld.WorldLive.handle_event/3` for `"sessions.join"` — a
      garbage `session_uri` arg must short-circuit to `error:bad_session_uri`
      BEFORE any dispatch is attempted (drives the REAL public LV handler).
    * `Ezagent.World.ConversationData.state_for/2` for a syntactically valid
      `session://` URI that was NEVER created — the non-member deep-link
      disclosure fix (`conversation_data_visibility_test.exs`) proves this for
      an EXISTING session a caller isn't a member of; this proves the SAME
      fail-closed `access_denied` shape for a session that plain doesn't
      exist, so a probing/enumeration URI gets no distinguishing crash or
      content leak either.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.World.ConversationData
  alias EzagentPluginWorld.WorldLive

  defp uniq, do: System.unique_integer([:positive])

  describe "WorldLive.handle_event/3 \"sessions.join\" — malformed session_uri" do
    test "a non-URI string degrades to error:bad_session_uri, no crash" do
      socket = %Phoenix.LiveView.Socket{}

      assert {:noreply, out} =
               WorldLive.handle_event(
                 "world:dispatch",
                 %{"action" => "sessions.join", "args" => %{"session_uri" => "not a uri"}},
                 socket
               )

      assert out.assigns.last_dispatch_status == "error:bad_session_uri"
    end

    test "an empty string degrades to error:bad_session_uri, no crash" do
      socket = %Phoenix.LiveView.Socket{}

      assert {:noreply, out} =
               WorldLive.handle_event(
                 "world:dispatch",
                 %{"action" => "sessions.join", "args" => %{"session_uri" => ""}},
                 socket
               )

      assert out.assigns.last_dispatch_status == "error:bad_session_uri"
    end

    test "a well-formed but WRONG-scheme URI (entity://) is rejected, not misparsed as a session" do
      socket = %Phoenix.LiveView.Socket{}

      assert {:noreply, out} =
               WorldLive.handle_event(
                 "world:dispatch",
                 %{
                   "action" => "sessions.join",
                   "args" => %{"session_uri" => "entity://system/user/admin"}
                 },
                 socket
               )

      assert out.assigns.last_dispatch_status == "error:bad_session_uri"
    end
  end

  describe "ConversationData.state_for/2 — a session URI that was never created" do
    test "a caller probing a nonexistent session gets access_denied, no content, no crash" do
      never_created =
        URI.new!("session://team-alpha/default/never-created-#{uniq()}")

      caller = URI.new!("entity://team-alpha/user/prober-#{uniq()}")

      state =
        ConversationData.state_for(never_created, %{
          caller_uri: caller,
          caller_caps: MapSet.new(),
          workspace_uri: URI.new!("workspace://team-alpha"),
          sessions: []
        })

      assert state["access_denied"] == true
      assert state["messages"] == []
      assert state["members"] == []
      assert state["invite_candidates"] == []
      # The tab set is independently cap-gated and stays available even under
      # denial (same contract as the visibility-test suite) — it discloses no
      # session content.
      assert is_list(state["views"])
    end

    test "an anon (nil) caller probing a nonexistent session gets access_denied, no crash" do
      never_created =
        URI.new!("session://team-alpha/default/never-created-anon-#{uniq()}")

      state =
        ConversationData.state_for(never_created, %{
          caller_uri: nil,
          caller_caps: MapSet.new(),
          workspace_uri: URI.new!("workspace://team-alpha"),
          sessions: []
        })

      assert state["access_denied"] == true
      assert state["messages"] == []
    end
  end
end
