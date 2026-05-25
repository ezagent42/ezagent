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
    test "emits security-minimal envelope on subscribed URI (PR-N3 codex r2)" do
      # PR-N3 codex r2 HIGH-1 (Allen 2026-05-25): the broadcast envelope
      # is security-minimal (5 fields only) — `:new_slice` / `:old_slice`
      # / `:result` / `:caller` / `:kind_module` / `:action` are STRIPPED
      # at the SliceChange boundary so subscribers can't read sensitive
      # slice content (e.g. ApiKeys plaintext) by subscribing to the
      # public-derivable topic. The invariant test
      # `slice_change_event_carries_no_slice_content_test.exs` is the
      # canonical gate; this test just sanity-checks that emit/1 still
      # broadcasts at all when given the fat producer-side input.
      uri = URI.parse("entity://user/x/y-#{System.unique_integer([:positive])}")
      SliceChange.subscribe_unverified(uri)

      producer_event = %{
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

      :ok = SliceChange.emit(producer_event)

      assert_receive {:slice_changed, broadcast_event}, 200

      # Security-minimal contract: only the 5 allowed keys.
      assert Map.keys(broadcast_event) |> Enum.sort() ==
               Enum.sort([:uri, :slice_key, :cursor, :event_at, :result_summary])

      assert broadcast_event.uri == uri
      assert broadcast_event.slice_key == :test_slice
      assert is_integer(broadcast_event.cursor) and broadcast_event.cursor >= 1
      assert %DateTime{} = broadcast_event.event_at
      assert broadcast_event.result_summary == :ok
    end

    test "returns :ok on malformed event without crashing" do
      # Defensive: emit/1 falls through to the catch-all do_emit/1
      # clause when the event map lacks :self_uri. Should not crash
      # the calling process (Kind.Server).
      assert :ok = SliceChange.emit(%{not_a_self_uri: :nope})
    end

    test "envelope construction failure stays non-fatal (codex r3 MED)" do
      # Codex r3 MEDIUM (Allen 2026-05-25): pre-fix `build_broadcast_event/2`
      # ran OUTSIDE the rescue. If `Cursors.next/1` failed (missing ETS
      # table during EtsOwner restart / boot skew) the `ArgumentError`
      # raised straight out of `emit/1`, crashing the Kind GenServer that
      # called `Kind.Server.commit_and_notify/3` AFTER the commit had
      # already persisted — exactly the non-fatal post-commit contract
      # this function exists to preserve.
      #
      # Fix: envelope construction (including cursor allocation) moved
      # INSIDE the try/rescue. We simulate the failure by passing a
      # `self_uri` whose `URI.to_string/1` raises — `Cursors.next/1`'s
      # first step is `URI.to_string(uri)`, which gets triggered inside
      # the now-guarded path. Whole-emit must still return :ok.
      bad_uri = %URI{scheme: "entity", host: {:not, :a, :string}}

      assert :ok =
               SliceChange.emit(%{
                 self_uri: bad_uri,
                 kind_module: SomeKind,
                 action: :test,
                 slice_key: :test_slice,
                 old_slice: %{},
                 new_slice: %{a: 1},
                 result: nil,
                 caller: nil,
                 at: DateTime.utc_now()
               })
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
