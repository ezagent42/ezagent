defmodule Ezagent.World.ConversationRoutingFormTest do
  @moduledoc """
  P2 test-supplement — `Ezagent.World.ConversationRoutingForm.build_matcher/1`
  and `wrap_in_session/2` had no direct test (only `parse_receivers/1` was
  covered, in `conversation_actions_test.exs`). Pure functions; pinned for
  both the happy path and malformed-form-input rejection (routing rule
  construction is part of the session governance surface — a malformed
  matcher form must be rejected, never silently build an unintended rule).
  """
  use ExUnit.Case, async: true

  alias Ezagent.World.ConversationRoutingForm

  describe "build_matcher/1" do
    test "mention matcher" do
      assert {:ok, matcher} =
               ConversationRoutingForm.build_matcher(%{
                 "matcher_type" => "mention",
                 "matcher_arg" => "front-desk"
               })

      assert matcher == Ezagent.Routing.Matcher.mention("front-desk")
    end

    test "from matcher" do
      assert {:ok, matcher} =
               ConversationRoutingForm.build_matcher(%{
                 "matcher_type" => "from",
                 "matcher_arg" => "entity://acme/user/alice"
               })

      assert matcher == Ezagent.Routing.Matcher.from("entity://acme/user/alice")
    end

    test "from_role matcher accepts a valid role name" do
      assert {:ok, matcher} =
               ConversationRoutingForm.build_matcher(%{
                 "matcher_type" => "from_role",
                 "matcher_arg" => "builder"
               })

      assert matcher == Ezagent.Routing.Matcher.from_role("builder")
    end

    test "from_role rejects a role name with disallowed characters" do
      assert {:error, :invalid_matcher_form} =
               ConversationRoutingForm.build_matcher(%{
                 "matcher_type" => "from_role",
                 "matcher_arg" => "not a valid role!"
               })
    end

    test "text_contains matcher" do
      assert {:ok, matcher} =
               ConversationRoutingForm.build_matcher(%{
                 "matcher_type" => "text_contains",
                 "matcher_arg" => "help"
               })

      assert matcher == Ezagent.Routing.Matcher.text_contains("help")
    end

    test "always matcher ignores the arg" do
      assert {:ok, matcher} =
               ConversationRoutingForm.build_matcher(%{
                 "matcher_type" => "always",
                 "matcher_arg" => nil
               })

      assert matcher == Ezagent.Routing.Matcher.always()
    end

    test "an unknown matcher_type is rejected" do
      assert {:error, :invalid_matcher_form} =
               ConversationRoutingForm.build_matcher(%{
                 "matcher_type" => "not_a_real_type",
                 "matcher_arg" => "x"
               })
    end

    test "an empty-string arg is rejected for mention/from/text_contains" do
      for type <- ["mention", "from", "text_contains"] do
        assert {:error, :invalid_matcher_form} =
                 ConversationRoutingForm.build_matcher(%{
                   "matcher_type" => type,
                   "matcher_arg" => ""
                 })
      end
    end

    test "a non-map form is rejected without crashing" do
      assert {:error, :invalid_matcher_form} = ConversationRoutingForm.build_matcher("garbage")
      assert {:error, :invalid_matcher_form} = ConversationRoutingForm.build_matcher(nil)
    end
  end

  describe "wrap_in_session/2" do
    test "wraps a leaf matcher in an in_session + all_of" do
      session_uri = URI.new!("session://acme/default/main")
      leaf = Ezagent.Routing.Matcher.mention("hi")

      wrapped = ConversationRoutingForm.wrap_in_session(leaf, session_uri)

      assert wrapped ==
               Ezagent.Routing.Matcher.all_of([
                 Ezagent.Routing.Matcher.in_session(session_uri),
                 leaf
               ])
    end

    test "an already-in_session matcher is left untouched (not double-wrapped)" do
      session_uri = URI.new!("session://acme/default/main")
      already_scoped = Ezagent.Routing.Matcher.in_session(session_uri)

      assert ConversationRoutingForm.wrap_in_session(already_scoped, session_uri) ==
               already_scoped
    end
  end
end
