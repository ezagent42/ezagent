defmodule Ezagent.World.ConversationDataTest do
  @moduledoc """
  PR-2a — @mention parse is the load-bearing piece: the domain's recipient
  resolver consumes `msg.mentions`, so a wrong parse silently routes a mention
  nowhere (the exact divergence class this migration's ratchet is blind to).
  These pin world's parse to the same URIs the LiveView parser produced.
  """
  use ExUnit.Case, async: true

  alias Ezagent.World.ConversationData

  defp members do
    [
      %{"uri" => "entity://system/agent/codex-1", "display_name" => "Codex One"},
      %{
        "uri" => "entity://system/agent/9c0ed922-be7d-cab0-274e-930d08173e41",
        "display_name" => "Orchestrator Agent",
        "role_name" => "orchestrator"
      },
      %{"uri" => "entity://system/user/admin", "display_name" => "Admin"},
      %{"uri" => "entity://system/user/alice", "display_name" => "Alice"},
      %{"uri" => "entity://system/user/bob", "display_name" => "Alice"}
    ]
  end

  defp parsed(text),
    do: text |> ConversationData.parse_mentions(members()) |> Enum.map(&URI.to_string/1)

  test "explicit @entity:// URI mention resolves" do
    assert parsed("hey @entity://system/agent/codex-1 look") == ["entity://system/agent/codex-1"]
  end

  test "bare @name resolves by URI path segment" do
    assert parsed("ping @codex-1 now") == ["entity://system/agent/codex-1"]
  end

  test "bare @name resolves by unique display name" do
    assert parsed("hi @Admin") == ["entity://system/user/admin"]
  end

  test "bare @name resolves by unique role name" do
    assert parsed("ping @orchestrator") == [
             "entity://system/agent/9c0ed922-be7d-cab0-274e-930d08173e41"
           ]
  end

  test "ambiguous display name resolves to nothing (no guess)" do
    # Two members share display "Alice" and neither path segment is "Alice".
    assert parsed("yo @Alice") == []
  end

  test "unknown @name resolves to nothing" do
    assert parsed("@nobody here") == []
  end

  test "multiple + duplicate mentions dedupe, preserving distinct recipients" do
    assert parsed("@codex-1 @Admin @codex-1") == [
             "entity://system/agent/codex-1",
             "entity://system/user/admin"
           ]
  end

  test "no @ token yields no mentions" do
    assert parsed("plain message, email a@b.test is not a mention-at-start") == []
  end

  # NOTE: `build_message/3,4` and `message_row/1` tests live in
  # `EzagentWeb.WorldConversationTest` (a sandbox-backed `ConnCase`), NOT here:
  # they resolve entity display names / download tokens through the Repo, so they
  # need Ecto-sandbox ownership. This module stays `async: true` + DB-free
  # (pure `parse_mentions`), which is exactly why the parse tests are fast here.

  # Stage 1 — world reads Ezagent.UI.SessionViewRegistry to emit dynamic view
  # tabs. These pin: (a) enumeration + render-mode classification, (b) the
  # id-only whitelist source, (c) the cap gate — an uncapped/anon caller sees no
  # gated tab. All against a cold session URI so the read path stays DB-free.
  # (The `state_for/2` pin lives in `Ezagent.World.ConversationDataStateForTest`
  # below — it loads messages through the Repo, so it needs sandbox ownership.)
  describe "session_views/2 (registry-driven tabs)" do
    defmodule AlwaysView do
      @behaviour Ezagent.UI.SessionView
      use Phoenix.Component
      def id, do: :test_always
      def label, do: "Always"
      def icon, do: "sparkles"
      def applies_to?(%URI{}), do: true
      def applies_to?(_), do: false
      def view_behavior, do: nil
      def render(assigns), do: ~H""
    end

    defmodule ExternalView do
      @behaviour Ezagent.UI.SessionView
      use Phoenix.Component
      def id, do: :test_external
      def label, do: "Ext"
      def icon, do: "panel-top"
      def applies_to?(%URI{}), do: true
      def applies_to?(_), do: false
      def view_behavior, do: nil
      def external_render?, do: true
      def external_render(_uri), do: %{"type" => "text"}
      def render(assigns), do: ~H""
    end

    setup do
      :ok = Ezagent.UI.SessionViewRegistry.init()
      :ok = Ezagent.UI.SessionViewRegistry.register(Ezagent.World.ConversationView)
      :ok = Ezagent.UI.SessionViewRegistry.register(AlwaysView)
      :ok = Ezagent.UI.SessionViewRegistry.register(ExternalView)
      %{session: Ezagent.URI.session("acme", "default", "s1")}
    end

    test "enumerates applicable views with classified mode", %{session: s} do
      views = ConversationData.session_views(s, nil)
      by_id = Map.new(views, &{&1["id"], &1})

      assert by_id["conversation"]["mode"] == "chat"
      assert by_id["conversation"]["label"] == "Chat"
      assert by_id["conversation"]["icon"] == "message-square"
      assert by_id["test_always"]["mode"] == "unsupported"
      assert by_id["test_external"]["mode"] == "external"
    end

    test "session_view_ids/2 returns just the id strings", %{session: s} do
      ids = ConversationData.session_view_ids(s, nil)
      assert "conversation" in ids
      assert "test_external" in ids
    end
  end

  describe "cap-gated view filtering (migration safety)" do
    defmodule GatedRender do
      # A cap-only render ActionSet: `authorize_view/3` derives the render caps
      # from `actions/0`, so an uncapped/anon caller fails the gate.
      def actions, do: [:some_render]
    end

    defmodule GatedView do
      @behaviour Ezagent.UI.SessionView
      use Phoenix.Component
      def id, do: :test_gated
      def label, do: "Gated"
      def icon, do: "panel-top"
      def applies_to?(%URI{}), do: true
      def applies_to?(_), do: false
      def view_behavior, do: GatedRender
      def render(assigns), do: ~H""
    end

    setup do
      :ok = Ezagent.UI.SessionViewRegistry.init()
      :ok = Ezagent.UI.SessionViewRegistry.register(Ezagent.World.ConversationView)
      :ok = Ezagent.UI.SessionViewRegistry.register(GatedView)
      %{session: Ezagent.URI.session("acme", "default", "gated1")}
    end

    test "an uncapped caller does NOT see the gated view (but sees chat)", %{session: s} do
      ids = ConversationData.session_view_ids(s, Ezagent.URI.user("acme", "nobody"))
      assert "conversation" in ids
      refute "test_gated" in ids
    end

    test "a nil (anon) caller does NOT see the gated view", %{session: s} do
      ids = ConversationData.session_view_ids(s, nil)
      assert "conversation" in ids
      refute "test_gated" in ids
    end
  end
end

defmodule Ezagent.World.ConversationDataStateForTest do
  @moduledoc """
  Stage 1 — `state_for/2` emits the registry-driven "views" array and no longer
  emits the old `is_hello` probe.

  Lives in its OWN `DataCase` module (not the async DB-free module above):
  `state_for/2` loads recent messages through `EzagentCore.Repo`
  (`Ezagent.MessageStore`), so the test process needs Ecto-sandbox ownership.
  In a full-umbrella run an earlier app's test_helper flips the shared Repo to
  `:manual` sandbox mode, so a naked query here dies with
  `DBConnection.OwnershipError` (a per-app run stays in the default `:auto`
  mode, which masked this). `DataCase` checks out a connection either way.

  Assertions are containment-based ("conversation" is present / `is_hello` is
  absent), NOT set-equality — in a full-umbrella BEAM other plugins' boot
  registrations (hello page, pty, routing, external_mirror) share the same
  named ETS registry table.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.World.ConversationData

  setup do
    :ok = Ezagent.UI.SessionViewRegistry.init()
    :ok = Ezagent.UI.SessionViewRegistry.register(Ezagent.World.ConversationView)
    :ok
  end

  test "state_for/2 exposes registry views and no longer emits is_hello" do
    s = Ezagent.URI.session("acme", "default", "s2")

    state =
      ConversationData.state_for(s, %{
        caller_uri: nil,
        workspace_uri: Ezagent.URI.workspace("acme"),
        sessions: []
      })

    assert is_list(state["views"])
    assert Enum.any?(state["views"], &(&1["id"] == "conversation"))
    refute Map.has_key?(state, "is_hello")
  end
end
