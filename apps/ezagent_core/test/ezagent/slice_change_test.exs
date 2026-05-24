defmodule Ezagent.SliceChangeTest do
  @moduledoc """
  PR-N1 (SPEC v2 notification architecture, Allen 2026-05-24) —
  basic contract for the SliceChange emit/subscribe primitive.

  The hook in `Kind.Runtime.handle_dispatch/4` is integration-tested
  separately; here we just assert the topic shape + the gate flag.
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

  describe "enabled?/0 — feature flag" do
    test "default is false (PR-N1 ships hook disabled)" do
      # Reset just in case
      Application.delete_env(:ezagent_core, :slice_change_hook)
      refute SliceChange.enabled?()
    end

    test "set to true enables the gate" do
      Application.put_env(:ezagent_core, :slice_change_hook, true)
      assert SliceChange.enabled?()
    after
      Application.delete_env(:ezagent_core, :slice_change_hook)
    end
  end

  describe "emit/1" do
    test "returns :ok when disabled (gate short-circuits)" do
      Application.delete_env(:ezagent_core, :slice_change_hook)
      assert :ok = SliceChange.emit(%{self_uri: URI.parse("entity://user/x/y")})
    end

    test "emits to PubSub when enabled" do
      Application.put_env(:ezagent_core, :slice_change_hook, true)
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
    after
      Application.delete_env(:ezagent_core, :slice_change_hook)
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
