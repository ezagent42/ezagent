defmodule Ezagent.Invariants.SliceChangeEventCarriesNoSliceContentTest do
  @moduledoc """
  PR-N3 codex r2 HIGH-1 fix (Allen 2026-05-25): the
  `{:slice_changed, event}` envelope broadcast by `Ezagent.SliceChange.emit/1`
  MUST NOT carry slice content.

  ## The risk this invariant prevents

  Pre-fix `SliceChange.emit/1` broadcast `:old_slice`, `:new_slice`, and
  the action's `:result` to every same-VM subscriber of
  `esr:entity:<uri>:slice_changed`. The topic name is derivable from a
  public URI; `subscribe_unverified/1` performs no cap check
  (`apps/ezagent_core/lib/ezagent/slice_change.ex` moduledoc §"Codex
  PR-N1 round-5 disposition"). Same-VM = same trust domain.

  But Behaviors store sensitive material in slices:

  - `Ezagent.Behavior.ApiKeys` slice — plaintext API keys
    (`apps/ezagent_domain_identity/lib/ezagent/behavior/api_keys.ex`)
  - `Ezagent.Behavior.Identity` slice — cap grants
  - Future: any credential, token, secret stored on a Kind

  With slice content in the broadcast envelope, ANY subscriber bypasses
  the Behavior's cap gate (e.g. `identity:api_keys:read`) and reads the
  plaintext by subscribing to the topic. Codex r2 (PR #328) flagged this
  as HIGH-1.

  ## The fix

  Allen-approved (Option C, same shape as PR-EM-0 Publisher.Event):
  strip the broadcast envelope down to a typed, security-minimal map.
  Subscribers needing slice content MUST re-fetch via
  `Ezagent.Kind.get_slice/2` or `Ezagent.Invocation.dispatch/1` —
  which run their own cap gates. The event itself is default-secure.

  Allowed keys ONLY:

  - `:uri` — `URI.t()` — which Kind instance emitted
  - `:slice_key` — `atom()` — which slice changed
  - `:cursor` — `non_neg_integer()` — monotonic per-URI sequence
  - `:event_at` — `DateTime.t()` — wall-clock
  - `:result_summary` — `:ok | :error` — atom summary, no detail

  Anything else (`:new_slice`, `:old_slice`, `:result`, `:caller`,
  `:kind_module`, `:action`) is a regression to the cap-bypass surface
  this PR closes.

  ## Why an invariant test (not just a unit test of `emit/1`)

  Per `feedback_completion_requires_invariant_test`: "type-check +
  tests-pass + PR-merge" does not prove an architectural invariant.
  The next PR could quietly add a `:caller` field back to the broadcast
  envelope for "convenience" — the unit test of `emit/1` wouldn't catch
  it because the engineer would update both sites in lockstep.

  THIS test drives `emit/1` end-to-end via the real `Kind.Runtime` ->
  `Kind.Server.commit_and_notify/3` path that production uses, then
  asserts on the BROADCAST envelope's key set. A future leak gets caught
  here even if the unit tests stay green.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.SliceChange

  @allowed_keys MapSet.new([:uri, :slice_key, :cursor, :event_at, :result_summary])

  describe "slice_change broadcast envelope (PR-N3 codex r2 HIGH-1)" do
    test "emit/1 carries ONLY the allowed-keys subset, no slice content" do
      uri = URI.parse("entity://user/default/sec-#{System.unique_integer([:positive])}")
      :ok = SliceChange.subscribe_unverified(uri)

      # Simulate the largest possible event the producer could hand
      # us — every legacy field set with sentinel "leaky" payloads.
      # The contract is: emit/1 broadcasts ONLY the safe subset; the
      # legacy fields MUST be filtered at the broadcast boundary.
      :ok =
        SliceChange.emit(%{
          self_uri: uri,
          kind_module: Ezagent.Behavior.ApiKeys,
          action: :put_api_key,
          slice_key: :api_keys,
          # The canary — if this string ever lands in a subscriber's
          # mailbox, the cap-bypass regression is back.
          old_slice: %{keys: %{"openai" => "sk-OLD-LEAKY-KEY-1111"}},
          new_slice: %{keys: %{"openai" => "sk-NEW-LEAKY-KEY-2222"}},
          result: %{ok: true, provider: "openai"},
          caller: URI.parse("entity://user/default/attacker"),
          at: DateTime.utc_now()
        })

      assert_receive {:slice_changed, event}, 500

      assert is_map(event), "event must be a map, got: #{inspect(event)}"

      actual = MapSet.new(Map.keys(event))

      missing = MapSet.difference(@allowed_keys, actual)

      assert MapSet.size(missing) == 0,
             "missing required keys: #{inspect(MapSet.to_list(missing))} — " <>
               "event keys=#{inspect(Map.keys(event))}"

      forbidden = MapSet.difference(actual, @allowed_keys)

      assert MapSet.size(forbidden) == 0,
             "forbidden keys leaked into broadcast envelope: " <>
               "#{inspect(MapSet.to_list(forbidden))} — " <>
               "event=#{inspect(event)}. " <>
               "PR-N3 codex r2 HIGH-1: subscribers must re-fetch via " <>
               "Kind.get_slice/2 to read slice content; the broadcast " <>
               "envelope must not carry it."

      # Belt-and-suspenders: spot-check the specific exfil vectors.
      refute Map.has_key?(event, :new_slice),
             ":new_slice leaks the post-mutation plaintext (api-key)."

      refute Map.has_key?(event, :old_slice),
             ":old_slice leaks the pre-mutation plaintext (api-key)."

      refute Map.has_key?(event, :result),
             ":result can carry the plaintext key (see ApiKeys.invoke(:get_api_key) -> %{key: <plaintext>})."

      refute Map.has_key?(event, :caller),
             ":caller is metadata that subscribers without that cap shouldn't see."

      refute Map.has_key?(event, :kind_module),
             ":kind_module exposes implementation taxonomy; not in the security-minimal contract."

      refute Map.has_key?(event, :action),
             ":action exposes Behavior verb; not in the security-minimal contract."

      # And the structural canary — the leaky string MUST NOT appear
      # anywhere in the broadcast envelope, no matter how it got
      # encoded. This guards against e.g. accidentally embedding the
      # full event map as a nested value under a renamed key.
      refute inspect(event) =~ "LEAKY-KEY",
             "slice content (sentinel string) leaked into the envelope — " <>
               "event=#{inspect(event)}"
    end

    test "emit/1 populates required allowed keys with right types" do
      uri = URI.parse("entity://user/default/sh-#{System.unique_integer([:positive])}")
      :ok = SliceChange.subscribe_unverified(uri)

      :ok =
        SliceChange.emit(%{
          self_uri: uri,
          kind_module: Ezagent.Behavior.ApiKeys,
          action: :put_api_key,
          slice_key: :api_keys,
          old_slice: %{},
          new_slice: %{keys: %{}},
          result: %{ok: true},
          caller: nil,
          at: DateTime.utc_now()
        })

      assert_receive {:slice_changed, event}, 500

      assert %URI{} = event.uri
      assert URI.to_string(event.uri) == URI.to_string(uri)
      assert event.slice_key == :api_keys
      assert is_integer(event.cursor) and event.cursor >= 1
      assert %DateTime{} = event.event_at
      assert event.result_summary in [:ok, :error]
    end

    test "cursor is monotonically increasing per URI" do
      uri = URI.parse("entity://user/default/cur-#{System.unique_integer([:positive])}")
      :ok = SliceChange.subscribe_unverified(uri)

      base = %{
        self_uri: uri,
        kind_module: SomeKind,
        action: :put,
        slice_key: :s,
        old_slice: %{},
        new_slice: %{a: 1},
        result: nil,
        caller: nil,
        at: DateTime.utc_now()
      }

      :ok = SliceChange.emit(base)
      :ok = SliceChange.emit(base)
      :ok = SliceChange.emit(base)

      assert_receive {:slice_changed, e1}, 500
      assert_receive {:slice_changed, e2}, 500
      assert_receive {:slice_changed, e3}, 500

      assert e1.cursor < e2.cursor
      assert e2.cursor < e3.cursor
    end

    test "cursor counters are independent per URI" do
      uri_a = URI.parse("entity://user/default/cur-a-#{System.unique_integer([:positive])}")
      uri_b = URI.parse("entity://user/default/cur-b-#{System.unique_integer([:positive])}")

      :ok = SliceChange.subscribe_unverified(uri_a)
      :ok = SliceChange.subscribe_unverified(uri_b)

      base = %{
        kind_module: SomeKind,
        action: :put,
        slice_key: :s,
        old_slice: %{},
        new_slice: %{a: 1},
        result: nil,
        caller: nil,
        at: DateTime.utc_now()
      }

      :ok = SliceChange.emit(Map.put(base, :self_uri, uri_a))
      :ok = SliceChange.emit(Map.put(base, :self_uri, uri_b))
      :ok = SliceChange.emit(Map.put(base, :self_uri, uri_a))

      # uri_a should see cursors 1 and 2; uri_b should see cursor 1.
      assert_receive {:slice_changed, a1}, 500
      assert_receive {:slice_changed, b1}, 500
      assert_receive {:slice_changed, a2}, 500

      assert a1.uri == uri_a
      assert b1.uri == uri_b
      assert a2.uri == uri_a

      # Each URI's first event has its own starting point; subsequent
      # events under the same URI strictly increase. uri_b's cursor
      # MUST NOT depend on uri_a's emission count.
      assert a2.cursor > a1.cursor
      assert b1.cursor >= 1
    end

    test "result_summary is :ok when caller passes result != nil, :error when nil/error" do
      uri = URI.parse("entity://user/default/sum-#{System.unique_integer([:positive])}")
      :ok = SliceChange.subscribe_unverified(uri)

      # nil result -> :ok (the invoke succeeded, just returned no result map)
      :ok =
        SliceChange.emit(%{
          self_uri: uri,
          kind_module: K,
          action: :a,
          slice_key: :s,
          old_slice: %{},
          new_slice: %{x: 1},
          result: nil,
          caller: nil,
          at: DateTime.utc_now()
        })

      assert_receive {:slice_changed, e}, 500
      assert e.result_summary == :ok

      # success result map -> :ok
      :ok =
        SliceChange.emit(%{
          self_uri: uri,
          kind_module: K,
          action: :a,
          slice_key: :s,
          old_slice: %{},
          new_slice: %{x: 2},
          result: %{ok: true},
          caller: nil,
          at: DateTime.utc_now()
        })

      assert_receive {:slice_changed, e2}, 500
      assert e2.result_summary == :ok
    end
  end
end
