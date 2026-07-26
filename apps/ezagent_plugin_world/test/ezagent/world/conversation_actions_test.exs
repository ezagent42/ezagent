defmodule Ezagent.World.ConversationActionsTest do
  # Was `use ExUnit.Case, async: true` — an outlier among this app's DB-touching
  # tests. `switch_view/3 → AdminData.external_mirror_bindings_for/1` runs a
  # synchronous `EzagentCore.Repo.all` in the test process. With no sandbox
  # ownership that read only worked when this file ran ALONE (plugin_world's
  # bare `test_helper.exs` never sets `:manual` mode, so the pool checks out
  # normally). In the full umbrella shard another app sets the Repo sandbox to
  # `:manual` globally, so this unowned read hit `DBConnection.OwnershipError`,
  # which `external_mirror_bindings_for/1`'s prod `rescue` folded into
  # `bindings` — flunking `assert bindings == []` non-deterministically by seed.
  # Route through DataCase (the pattern every DB-touching sibling here uses,
  # incl. `admin_data_test.exs` for the SAME module) so the test owns a sandbox
  # connection. Test-harness only; no production change.
  use EzagentCore.DataCase, async: false

  alias Ezagent.World.ConversationActions

  test "Session-Config UI actions project through the domain execute boundary" do
    source =
      File.read!(Path.expand("../../../lib/ezagent/world/conversation_actions.ex", __DIR__))

    assert source =~ "Ezagent.Session.Config.execute("
    refute source =~ "Ezagent.Orchestrator.Tools.Templates.save_template_as"
  end

  alias Ezagent.World.ConversationRoutingForm

  test "create_session_result converts create_session exits into errors" do
    workspace_uri = Ezagent.URI.workspace(:system)
    caller = Ezagent.Entity.User.admin_uri()

    assert {:error, {:create_session_exit, {:timeout, _}}} =
             ConversationActions.create_session_result(
               workspace_uri,
               caller,
               "world-pr4-timeout",
               "default",
               fn _workspace_uri, _params, _ctx -> exit({:timeout, self()}) end
             )
  end

  test "create_session_result passes the baseline workspace create context" do
    workspace_uri = Ezagent.URI.workspace(:system)
    caller = Ezagent.Entity.User.admin_uri()
    session_uri = Ezagent.URI.session("system", "default", "world-create-baseline")

    assert {:ok, ^session_uri} =
             ConversationActions.create_session_result(
               workspace_uri,
               caller,
               "world-create-baseline",
               "default",
               fn got_workspace_uri, got_params, got_ctx ->
                 assert got_workspace_uri == workspace_uri

                 assert got_params == %{
                          short_name: "world-create-baseline",
                          template_name: "default"
                        }

                 assert got_ctx == %{
                          caller: caller,
                          authenticated_principal: caller,
                          caps: MapSet.new()
                        }

                 {:ok, %{session_uri: session_uri}}
               end
             )
  end

  test "session creation acknowledges completion but keeps session selection route-driven" do
    source =
      File.read!(Path.expand("../../../lib/ezagent/world/conversation_actions.ex", __DIR__))

    assert source =~ "push_event(\"world:session_created\""
    assert source =~ "push_patch(to: \"/sessions?session="
    refute source =~ "ConversationSessionState.switch_session(socket, session_uri)"
  end

  describe "routing receiver form parsing" do
    test "normalizes role receivers to tagged resolver receivers" do
      assert [
               "entity://system/user/admin",
               {:role, "builder"}
             ] =
               ConversationRoutingForm.parse_receivers([
                 "entity://system/user/admin",
                 "role:builder"
               ])
    end

    test "keeps magic receivers and rejects empty role receivers" do
      assert ["$session_members"] =
               ConversationRoutingForm.parse_receivers(["$session_members", "role:"])
    end
  end

  # F3: every session-create failure must map to a non-empty operator-facing
  # message (so the sessions table shows a banner instead of silently dropping).
  describe "session_create_error_message/1 (F3 no-silent-drop)" do
    test "named reasons get friendly messages" do
      for reason <- [:short_name_required, :template_required, :invalid_workspace, :unauthorized] do
        msg = ConversationActions.session_create_error_message(reason)
        assert is_binary(msg) and msg != ""
      end
    end

    test "the F3 wrong-template default failure ({:invalid_template, _}) is explained" do
      msg = ConversationActions.session_create_error_message({:invalid_template, %{}})
      assert is_binary(msg) and msg != ""
      refute msg =~ "invalid_template"
    end

    test "an unknown reason still produces a non-empty message (never a silent drop)" do
      msg = ConversationActions.session_create_error_message(:some_unmapped_reason)
      assert is_binary(msg) and msg != ""
    end

    test "unsupported Claude dev-channel errors get a concise operator message" do
      msg =
        ConversationActions.session_create_error_message(
          {:agent_grant_recipe_caps_failed,
           {:grant_failed, {:unsupported_claude_dev_channels, "/usr/bin/claude"}}}
        )

      assert msg =~ "Claude Code"
      assert msg =~ "不支持"
      refute msg =~ "agent_grant_recipe_caps_failed"
    end
  end

  # Regression: a session name with a space used to crash session URI parsing
  # ("URI parse failed at \":\": \"session://ezagent/hello/hello world\"").
  describe "session name sanitization (URI path-segment safety)" do
    test "collapses whitespace to '-' so a spaced name builds a valid session URI" do
      assert ConversationActions.sanitize_short_name("hello world") == "hello-world"
      assert ConversationActions.sanitize_short_name("  multi   space  ") == "multi-space"

      uri =
        Ezagent.URI.session(
          "ezagent",
          "hello",
          ConversationActions.sanitize_short_name("hello world")
        )

      assert %URI{} = uri
      assert URI.to_string(uri) == "session://ezagent/hello/hello-world"
    end

    test "CJK / reserved names are rejected cleanly (Ezagent.URI parses strictly)" do
      # Ezagent.URI.new! rejects raw CJK in a segment, so a CJK name must be caught
      # by uri_safe_short_name?/1 (→ :invalid_short_name) rather than crash the build.
      refute ConversationActions.uri_safe_short_name?("客服-会话")
      assert_raise ArgumentError, fn -> Ezagent.URI.session("ezagent", "hello", "客服-会话") end
    end

    test "uri_safe_short_name?/1 allows the URI unreserved set, rejects the rest" do
      for ok <- ["hello-world", "multi-space", "abc_123", "a.b~c", "Session1"] do
        assert ConversationActions.uri_safe_short_name?(ok), "expected #{ok} allowed"
      end

      for bad <- ["a/b", "a:b", "a?b", "a#b", "a@b", "a[b", "a b", "客服", ""] do
        refute ConversationActions.uri_safe_short_name?(bad), "expected #{inspect(bad)} rejected"
      end
    end

    test ":invalid_short_name maps to a friendly, non-empty message" do
      msg = ConversationActions.session_create_error_message(:invalid_short_name)
      assert is_binary(msg) and msg != ""
    end
  end

  # Stage 1 — switch_view whitelist is the caller-aware registry set, not the old
  # hard-coded ["chat","pty","page"]. A visible (enumerated) view id is accepted;
  # anything else is rejected `error:bad_view`, same-source as the tab visibility.
  describe "switch_view/3 (dynamic registry whitelist)" do
    setup do
      :ok = Ezagent.UI.SessionViewRegistry.init()
      :ok = Ezagent.UI.SessionViewRegistry.register(Ezagent.World.ConversationView)
      %{session: Ezagent.URI.session("acme", "default", "sw1")}
    end

    test "accepts an enumerated view id and rejects an unknown one", %{session: session} do
      socket = build_socket(current_entity_uri: Ezagent.URI.user("acme", "admin"))

      assert {:noreply, ok_socket} =
               ConversationActions.switch_view(socket, session, "conversation")

      assert ok_socket.assigns.world_state["active_view"] == "conversation"

      assert {:noreply, bad_socket} =
               ConversationActions.switch_view(socket, session, "does_not_exist")

      assert bad_socket.assigns.last_dispatch_status == "error:bad_view"
    end

    test "loads bindings when switching to the external mirror view", %{session: session} do
      :ok = Ezagent.UI.SessionViewRegistry.register(EzagentDomainUi.ExternalMirror.View)
      socket = build_socket(current_entity_uri: Ezagent.URI.user("acme", "admin"))

      assert {:noreply, switched_socket} =
               ConversationActions.switch_view(socket, session, "external_mirror")

      assert switched_socket.assigns.world_state["active_view"] == "external_mirror"
      assert switched_socket.assigns.world_state["bindings"] == []
    end
  end

  # Minimal LiveView socket stub: enough assigns for switch_view + push_world_state
  # (which merges "active_view" into :world_state and pushes a "world:state" event).
  defp build_socket(assigns) do
    base =
      Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, :world_state, %{})

    Enum.reduce(assigns, base, fn {k, v}, acc -> Phoenix.Component.assign(acc, k, v) end)
  end
end
