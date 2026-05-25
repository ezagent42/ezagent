defmodule Ezagent.SliceChangeTest do
  @moduledoc """
  PR-N1 (SPEC v2 notification architecture, Allen 2026-05-24) —
  basic contract for the SliceChange emit/subscribe primitive.

  PR-N3 (Allen 2026-05-25) hardened `enabled?/0` from a config-driven
  predicate to an unconditional `true` per
  `feedback_let_it_crash_no_workarounds`. The describe blocks below
  cover that contract (gate is always-on; legacy config knob is
  ignored).

  The hook in `Kind.Runtime.handle_dispatch/4` is integration-tested
  separately; here we just assert the topic shape + the gate behavior.
  """

  use ExUnit.Case, async: false

  alias Ezagent.SliceChange

  describe "topic/1" do
    test "shape: esr:entity:<uri>:slice_changed" do
      assert SliceChange.topic("entity://user/acme/alice") ==
               "esr:entity:entity://user/acme/alice:slice_changed"
    end

    test "accepts a %URI{} struct" do
      uri = URI.parse("entity://user/acme/alice")
      assert SliceChange.topic(uri) =~ "esr:entity:entity://user/acme/alice:slice_changed"
    end
  end

  describe "enabled?/0 — hard switch (PR-N3)" do
    test "always true (no config knob)" do
      assert SliceChange.enabled?()
    end

    test "legacy config knob is ignored (hard switch)" do
      # Regression guard for `feedback_let_it_crash_no_workarounds`:
      # PR-N1 used `Application.get_env(:ezagent_core,
      # :slice_change_hook, false)` as the gate; PR-N3 removed the
      # lookup entirely. Re-introducing a knob would let a future PR
      # silently disable the hook in production — this test fails
      # immediately if that regression lands.
      orig = Application.get_env(:ezagent_core, :slice_change_hook)

      on_exit(fn ->
        if is_nil(orig) do
          Application.delete_env(:ezagent_core, :slice_change_hook)
        else
          Application.put_env(:ezagent_core, :slice_change_hook, orig)
        end
      end)

      Application.put_env(:ezagent_core, :slice_change_hook, false)
      assert SliceChange.enabled?()
    end
  end

  describe "emit/1" do
    test "emits to PubSub on subscribed URI" do
      uri = URI.parse("entity://user/x/y-#{System.unique_integer([:positive])}")
      SliceChange.subscribe_unverified(uri)

      event = %{
        self_uri: uri,
        kind_module: SomeKind,
        action: :test,
        slice_key: :test_slice,
        old_slice: %{a: 1},
        new_slice: %{a: 2},
        result: nil,
        caller: nil,
        at: DateTime.utc_now()
      }

      :ok = SliceChange.emit(event)

      assert_receive {:slice_changed, ^event}, 200
    end

    test "returns :ok on malformed event without crashing" do
      # Defensive: emit/1 falls through to the catch-all do_emit/1
      # clause when the event map lacks :self_uri. Should not crash
      # the calling process (Kind.Server).
      assert :ok = SliceChange.emit(%{not_a_self_uri: :nope})
    end

    test "subscribe_unverified + unsubscribe_unverified contract" do
      uri = URI.parse("entity://user/x/sub-#{System.unique_integer([:positive])}")
      assert :ok = SliceChange.subscribe_unverified(uri)
      assert :ok = SliceChange.unsubscribe_unverified(uri)
    end

    test "subscribe/2 + subscribe_unverified/1 helper naming reflects trust shape" do
      # Codex PR-N1 round-5 option (a, Allen 2026-05-24): the
      # cap-gated subscribe lives on `NotificationSubscriptions`;
      # the raw transport subscribe is renamed `subscribe_unverified`
      # to make the trust shape obvious at every call site.
      refute function_exported?(SliceChange, :subscribe, 1)
      refute function_exported?(SliceChange, :unsubscribe, 1)
      assert function_exported?(SliceChange, :subscribe_unverified, 1)
      assert function_exported?(SliceChange, :unsubscribe_unverified, 1)
      assert function_exported?(Ezagent.NotificationSubscriptions, :subscribe, 3)
      assert function_exported?(Ezagent.NotificationSubscriptions, :unsubscribe, 3)
    end
  end
end
