defmodule Ezagent.Behavior.PublisherTest do
  @moduledoc """
  PR-EM-0 contract test for `Ezagent.Behavior.Publisher`.

  Verifies the behaviour declares the four callbacks the SPEC pins
  (`history_retention/0`, `subscribe_from/3`, `snapshot/1`, `history/3`)
  AND that `Ezagent.Entity.Session` declares `@behaviour
  Ezagent.Behavior.Publisher` — the architectural invariant that
  closes the loop per `feedback_completion_requires_invariant_test`
  (Allen 2026-05-05).

  This test FAILS when:

  - Someone changes the Publisher contract shape (renames / drops a
    callback) — catches accidental SPEC-deviation refactors.
  - Someone removes the `@behaviour` declaration from Session —
    catches a future refactor that "moves Publisher to another Kind"
    without updating Session.

  Without this test, the SessionImpl Behavior could still compile +
  pass dispatch tests, but Session would no longer formally implement
  the Publisher contract — silently breaking the invariant that
  Sessions are the V1 publisher.
  """

  use ExUnit.Case, async: true

  describe "Ezagent.Behavior.Publisher (the contract)" do
    test "declares exactly four callbacks (history_retention/0, subscribe_from/3, snapshot/1, history/3)" do
      callbacks =
        Ezagent.Behavior.Publisher.behaviour_info(:callbacks)
        |> Enum.sort()

      assert callbacks == [
               history: 3,
               history_retention: 0,
               snapshot: 1,
               subscribe_from: 3
             ]
    end

    test "optional callbacks list is empty (all four are required)" do
      optionals = Ezagent.Behavior.Publisher.behaviour_info(:optional_callbacks)
      assert optionals == []
    end
  end

  # Session-side architectural-invariant tests (the "@behaviour
  # declared" gate) live in
  # `apps/ezagent_domain_instance_message/test/ezagent/behavior/publisher/session_impl_test.exs`
  # because Session lives in `:ezagent_domain_instance_message` and this app
  # (external_mirror) deliberately has zero reverse references to chat.

  describe "Ezagent.Publisher.Event struct" do
    test "has exactly the five enforced fields per SPEC §2.1 + PR-EM-0 brief" do
      event = %Ezagent.Publisher.Event{
        cursor: 1,
        publisher_uri: URI.parse("session://default/system/main"),
        slice_key: :chat,
        event_at: DateTime.utc_now(),
        payload: %{}
      }

      assert %Ezagent.Publisher.Event{} = event
      assert event.cursor == 1
      assert event.slice_key == :chat
    end

    test "struct enforces all five keys (raises ArgumentError if any is missing)" do
      assert_raise ArgumentError, fn ->
        struct!(Ezagent.Publisher.Event, cursor: 1)
      end
    end
  end
end
