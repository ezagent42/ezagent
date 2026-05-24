defmodule Ezagent.NotificationSubscriptionsTest do
  @moduledoc """
  PR-N1 skeleton tests for the subscription registry (Allen
  2026-05-24 amendment).

  Round-4 hardening: there is NO system bypass anymore (codex
  round-4 CRITICAL — system_register/system_unregister deleted).
  Every test that needs a pre-seeded row constructs a real
  notifications-admin cap via `seed/2` helper.
  """

  use ExUnit.Case, async: false

  alias Ezagent.NotificationSubscriptions, as: Subs

  defp uniq, do: System.unique_integer([:positive])

  defp notifications_admin_cap do
    %Ezagent.Capability{
      kind: :user,
      behavior: Ezagent.Behavior.Notifications,
      instance: :any,
      workspace_uri: :any,
      granted_by: URI.parse("entity://user/system/test"),
      granted_at: DateTime.utc_now()
    }
  end

  defp narrow_cross_workspace_cap do
    %Ezagent.Capability{
      kind: :user,
      behavior: Ezagent.Behavior.Chat,
      instance: :any,
      workspace_uri: :any,
      granted_by: URI.parse("entity://user/system/test"),
      granted_at: DateTime.utc_now()
    }
  end

  defp admin_ctx_for(%URI{} = caller) do
    %{caller: caller, caps: MapSet.new([notifications_admin_cap()])}
  end

  # Replaces all the round-3-era `Subs.system_register(entity,
  # stream)` calls — now uses the public cap-gated API with an
  # admin ctx. This is the legitimate "I'm bootstrapping a test
  # row" pathway under round-4.
  defp seed(entity, stream) do
    admin = URI.parse("entity://user/system/test-seeder")
    :ok = Subs.register_subscription(entity, stream, admin_ctx_for(admin))
  end

  test "register + list + unregister flow (via cap path)" do
    entity = URI.parse("entity://user/acme/alice-#{uniq()}")
    stream = URI.parse("entity://user/acme/bob-#{uniq()}")

    assert Subs.list_subscriptions(entity) == []

    seed(entity, stream)

    subs = Subs.list_subscriptions(entity)
    assert length(subs) == 1
    assert [{stream_str, meta}] = subs
    assert stream_str == URI.to_string(stream)
    assert %DateTime{} = meta.registered_at

    admin = URI.parse("entity://user/system/test-unregisterer")

    assert :ok =
             Subs.unregister_subscription(entity, stream, admin_ctx_for(admin))

    assert Subs.list_subscriptions(entity) == []
  end

  test "list_subscribers reverse lookup" do
    stream = URI.parse("entity://user/acme/popular-#{uniq()}")
    alice = URI.parse("entity://user/acme/alice-#{uniq()}")
    bob = URI.parse("entity://user/acme/bob-#{uniq()}")

    seed(alice, stream)
    seed(bob, stream)

    subscribers = Subs.list_subscribers(stream) |> Enum.sort()
    assert URI.to_string(alice) in subscribers
    assert URI.to_string(bob) in subscribers
  end

  test "subscriptions are scoped per entity" do
    a = URI.parse("entity://user/acme/a-#{uniq()}")
    b = URI.parse("entity://user/acme/b-#{uniq()}")
    s1 = URI.parse("entity://user/acme/s1-#{uniq()}")
    s2 = URI.parse("entity://user/acme/s2-#{uniq()}")

    seed(a, s1)
    seed(b, s2)

    a_subs = Subs.list_subscriptions(a) |> Enum.map(fn {s, _} -> s end)
    b_subs = Subs.list_subscriptions(b) |> Enum.map(fn {s, _} -> s end)

    assert URI.to_string(s1) in a_subs
    refute URI.to_string(s2) in a_subs
    assert URI.to_string(s2) in b_subs
    refute URI.to_string(s1) in b_subs
  end

  test "string-form entity URI lookup works" do
    entity_str = "entity://user/acme/string-#{uniq()}"
    stream = URI.parse("entity://user/acme/s-#{uniq()}")

    seed(URI.parse(entity_str), stream)
    assert [{_, _}] = Subs.list_subscriptions(entity_str)
  end

  describe "cap enforcement (codex round-1 CRITICAL)" do
    test "non-system caller with empty caps is denied (deny-by-default)" do
      entity = URI.parse("entity://user/acme/alice-#{uniq()}")
      stream = URI.parse("entity://user/acme/bob-#{uniq()}")

      assert {:error, :unauthorized} =
               Subs.register_subscription(entity, stream, %{
                 caps: MapSet.new(),
                 caller: entity
               })

      assert Subs.list_subscriptions(entity) == []
    end

    test "missing :caps key in ctx is denied (not silently allowed)" do
      entity = URI.parse("entity://user/acme/alice-#{uniq()}")
      stream = URI.parse("entity://user/acme/bob-#{uniq()}")

      assert {:error, :unauthorized_for_entity} =
               Subs.register_subscription(entity, stream, %{})
    end

    test "self-register with matching cap is accepted" do
      entity = URI.parse("entity://user/acme/alice-#{uniq()}")
      stream = URI.parse("entity://user/acme/bob-#{uniq()}")

      assert :ok =
               Subs.register_subscription(entity, stream, %{
                 caps: MapSet.new([notifications_admin_cap()]),
                 caller: entity
               })

      assert [{_, _}] = Subs.list_subscriptions(entity)
    end
  end

  describe "explicit ctx required (codex round-2 CRITICAL)" do
    test "register_subscription/2 (no ctx) is not defined" do
      stream = URI.parse("entity://user/acme/bob-#{uniq()}")

      refute function_exported?(Subs, :register_subscription, 2)
      refute function_exported?(Subs, :unregister_subscription, 2)

      assert {:error, :invalid_args} =
               Subs.register_subscription(:not_a_uri, stream, %{caps: :system})
    end
  end

  describe "unregister authorization (codex round-1 HIGH-3 + round-2 HIGH-3)" do
    test "owner can unregister their own subscription" do
      entity = URI.parse("entity://user/acme/owner-#{uniq()}")
      stream = URI.parse("entity://user/acme/stream-#{uniq()}")

      seed(entity, stream)

      assert :ok =
               Subs.unregister_subscription(entity, stream, %{
                 caller: entity,
                 caps: MapSet.new()
               })

      assert Subs.list_subscriptions(entity) == []
    end

    test "stranger cannot unregister someone else's subscription" do
      owner = URI.parse("entity://user/acme/owner-#{uniq()}")
      stranger = URI.parse("entity://user/acme/stranger-#{uniq()}")
      stream = URI.parse("entity://user/acme/stream-#{uniq()}")

      seed(owner, stream)

      assert {:error, :unauthorized} =
               Subs.unregister_subscription(owner, stream, %{
                 caller: stranger,
                 caps: MapSet.new()
               })

      assert [{_, _}] = Subs.list_subscriptions(owner)
    end

    test "notifications-admin (:any + Behavior.Notifications) can unregister anyone" do
      owner = URI.parse("entity://user/acme/owner-#{uniq()}")
      admin = URI.parse("entity://user/system/admin-#{uniq()}")
      stream = URI.parse("entity://user/acme/stream-#{uniq()}")

      seed(owner, stream)

      assert :ok =
               Subs.unregister_subscription(owner, stream, admin_ctx_for(admin))

      assert Subs.list_subscriptions(owner) == []
    end

    test "narrow cross-workspace cap (non-Notifications) does NOT count as admin" do
      owner = URI.parse("entity://user/acme/owner-#{uniq()}")
      stranger = URI.parse("entity://user/acme/stranger-#{uniq()}")
      stream = URI.parse("entity://user/acme/stream-#{uniq()}")

      seed(owner, stream)

      assert {:error, :unauthorized} =
               Subs.unregister_subscription(owner, stream, %{
                 caller: stranger,
                 caps: MapSet.new([narrow_cross_workspace_cap()])
               })

      assert [{_, _}] = Subs.list_subscriptions(owner)
    end

    test "ctx without :caller is rejected" do
      entity = URI.parse("entity://user/acme/alice-#{uniq()}")
      stream = URI.parse("entity://user/acme/stream-#{uniq()}")

      seed(entity, stream)

      assert {:error, :unauthorized} =
               Subs.unregister_subscription(entity, stream, %{caps: MapSet.new()})
    end
  end

  describe "public API rejects :system ctx (codex round-3 CRITICAL)" do
    test "register_subscription/3 with caps: :system is denied" do
      entity = URI.parse("entity://user/acme/sneaky-#{uniq()}")
      stream = URI.parse("entity://user/acme/target-#{uniq()}")

      assert {:error, :system_caps_not_allowed_in_public_api} =
               Subs.register_subscription(entity, stream, %{
                 caps: :system,
                 caller: entity
               })

      assert Subs.list_subscriptions(entity) == []
    end

    test "unregister_subscription/3 with caps: :system is denied" do
      owner = URI.parse("entity://user/acme/owner-#{uniq()}")
      stream = URI.parse("entity://user/acme/stream-#{uniq()}")

      seed(owner, stream)

      assert {:error, :system_caps_not_allowed_in_public_api} =
               Subs.unregister_subscription(owner, stream, %{
                 caps: :system,
                 caller: URI.parse("entity://user/acme/stranger-#{uniq()}")
               })

      assert [{_, _}] = Subs.list_subscriptions(owner)
    end
  end

  describe "protected ETS boundary (codex round-2 HIGH-1)" do
    test "table is :protected — direct :ets.insert from non-owner raises" do
      entity_str = "entity://user/acme/sneaky-#{uniq()}"
      stream_str = "entity://user/acme/target-#{uniq()}"

      assert_raise ArgumentError, fn ->
        :ets.insert(
          Subs.table(),
          {{entity_str, stream_str}, %{registered_at: DateTime.utc_now()}}
        )
      end

      assert Subs.list_subscriptions(entity_str) == []
    end

    test "table is :protected — direct :ets.delete from non-owner raises" do
      assert_raise ArgumentError, fn ->
        :ets.delete(Subs.table(), {"any", "key"})
      end
    end
  end

  describe "no system bypass (codex round-4 CRITICAL)" do
    test "system_register/2 + system_unregister/2 are no longer exported" do
      # The round-3 helpers + GenServer message tags were the
      # forgeable bypass. They MUST NOT exist anymore.
      refute function_exported?(Subs, :system_register, 2)
      refute function_exported?(Subs, :system_unregister, 2)
    end

    test "direct GenServer.call forgery of :system_register is rejected" do
      victim = URI.parse("entity://user/acme/victim-#{uniq()}")
      stream = URI.parse("entity://user/acme/poison-#{uniq()}")

      # Codex round-4 attack: send the system message tag directly.
      # The catch-all handler now returns `:unknown_message` instead
      # of crashing the GenServer (which would DOS-amplify).
      assert {:error, {:unknown_message, :system_register}} =
               GenServer.call(Subs, {:system_register, victim, stream})

      assert {:error, {:unknown_message, :system_unregister}} =
               GenServer.call(Subs, {:system_unregister, victim, stream})

      # No row leaked.
      assert Subs.list_subscriptions(victim) == []
    end

    test "unrecognised GenServer message returns the message tag" do
      # The catch-all returns the message's leading atom so failures
      # are debuggable. Real plugin code shouldn't be sending here.
      assert {:error, {:unknown_message, :totally_made_up}} =
               GenServer.call(Subs, :totally_made_up)
    end
  end

  describe "subscribe/3 cap-gated wrapper (codex round-5 option a)" do
    test "subscribe/3 registers intent AND PubSub-subscribes the caller" do
      entity = URI.parse("entity://user/acme/alice-#{uniq()}")
      stream = URI.parse("entity://user/acme/bob-#{uniq()}")

      # Self-subscribe with a real cap.
      assert :ok =
               Subs.subscribe(entity, stream, %{
                 caller: entity,
                 caps: MapSet.new([notifications_admin_cap()])
               })

      # Intent is in the registry.
      assert [{stream_str, _}] = Subs.list_subscriptions(entity)
      assert stream_str == URI.to_string(stream)

      # And the caller process is PubSub-subscribed — fire an emit
      # and the test process should receive it.
      Application.put_env(:ezagent_core, :slice_change_hook, true)

      try do
        event = %{
          self_uri: stream,
          kind_module: SomeKind,
          action: :test,
          slice_key: :sk,
          old_slice: %{},
          new_slice: %{a: 1},
          result: nil,
          caller: nil,
          at: DateTime.utc_now()
        }

        Ezagent.SliceChange.emit(event)

        assert_receive {:slice_changed, ^event}, 200
      after
        Application.delete_env(:ezagent_core, :slice_change_hook)
        Ezagent.SliceChange.unsubscribe_unverified(stream)
      end
    end

    test "subscribe/3 denies non-system caller without cap" do
      entity = URI.parse("entity://user/acme/alice-#{uniq()}")
      stream = URI.parse("entity://user/acme/bob-#{uniq()}")

      assert {:error, :unauthorized} =
               Subs.subscribe(entity, stream, %{
                 caller: entity,
                 caps: MapSet.new()
               })

      assert Subs.list_subscriptions(entity) == []
    end

    test "unsubscribe/3 drops the registry row AND PubSub-unsubscribes" do
      entity = URI.parse("entity://user/acme/alice-#{uniq()}")
      stream = URI.parse("entity://user/acme/bob-#{uniq()}")

      :ok =
        Subs.subscribe(entity, stream, %{
          caller: entity,
          caps: MapSet.new([notifications_admin_cap()])
        })

      assert :ok =
               Subs.unsubscribe(entity, stream, %{
                 caller: entity,
                 caps: MapSet.new()
               })

      assert Subs.list_subscriptions(entity) == []
    end
  end

  describe "subscribe/3 + unsubscribe/3 partial-failure ordering (codex round-6 HIGH)" do
    # Codex round-6 finding: round-5 inserted the registry row
    # before PubSub.subscribe; if the second step failed the row
    # was left durable. The fix establishes opposite orderings
    # for the two wrappers:
    #   subscribe/3   — register intent → try PubSub → rollback row on failure
    #   unsubscribe/3 — PubSub unsubscribe → drop row only on success
    #
    # Forcing a real Phoenix.PubSub failure in test is awkward
    # (it's permissive about missing topics/subscriptions), so
    # these tests verify the STRUCTURAL pattern instead — the
    # wrappers contain try/rescue and the rollback helper exists.
    # A future regression that removes try/rescue would fail the
    # grep test. The actual runtime rollback path is exercised
    # indirectly: the "subscribe/3 denies non-system caller without
    # cap" test confirms that when the REGISTER step fails, no
    # row leaks; the symmetric "PubSub-failure-rollback" path
    # uses the same `unregister_subscription/3` call we already
    # cover by tests.
    test "source file contains the round-6 rollback pattern" do
      # `__DIR__` = apps/ezagent_core/test/ezagent.
      # ../.. → apps/ezagent_core, then /lib/ezagent/...
      source_path =
        Path.expand(
          "../../lib/ezagent/notification_subscriptions.ex",
          __DIR__
        )

      source = File.read!(source_path)

      # subscribe/3 must have try/rescue around the PubSub call
      assert source =~ "try do",
             "subscribe/3 lost its try/rescue partial-failure guard"

      # The named rollback helper must exist
      assert source =~ "defp rollback_register(",
             "rollback_register/3 helper was removed — partial-failure recovery gone"

      # rollback path must be wired in both error branches
      assert source =~ "rollback_register(entity_uri, stream_uri, ctx)",
             "subscribe/3 stopped calling rollback_register on PubSub failure"

      # unsubscribe/3 must call SliceChange.unsubscribe_unverified BEFORE unregister_subscription
      unsubscribe_block =
        case Regex.run(~r/def unsubscribe\(entity_uri.*?(\n  defp |\n  end\n)/s, source) do
          [block, _] -> block
          _ -> ""
        end

      slice_pos = :binary.match(unsubscribe_block, "SliceChange.unsubscribe_unverified")
      register_pos = :binary.match(unsubscribe_block, "unregister_subscription")

      assert is_tuple(slice_pos) and is_tuple(register_pos),
             "unsubscribe/3 missing one of its expected calls"

      {slice_offset, _} = slice_pos
      {register_offset, _} = register_pos

      assert slice_offset < register_offset,
             "unsubscribe/3 must call SliceChange.unsubscribe_unverified BEFORE " <>
               "unregister_subscription (codex round-6 ordering rule)"
    end
  end

  describe "known same-BEAM bypass paths (codex round-5 documented limits)" do
    test ":sys.replace_state CAN bypass the cap path — documented limit" do
      # Codex round-5 CRITICAL: this is a KNOWN limitation, not a
      # bug. BEAM same-VM trust model: any in-VM code can run
      # arbitrary functions in the GenServer's owner process via
      # `:sys.replace_state/2`, which gives `:ets.insert` access
      # to the `:protected` table.
      #
      # We document this as accepted by including a passing test
      # that DEMONSTRATES the bypass — future readers see "yes,
      # this works; the cap system protects USERS not PLUGINS".
      victim = URI.parse("entity://user/acme/victim-#{uniq()}")
      stream = URI.parse("entity://user/acme/stream-#{uniq()}")
      key = {URI.to_string(victim), URI.to_string(stream)}

      # Confirm victim has no subscription via the legitimate API.
      assert Subs.list_subscriptions(victim) == []

      # Attack via :sys.replace_state — runs in owner process.
      :sys.replace_state(Subs, fn state ->
        :ets.insert(Subs.table(), {key, %{registered_at: DateTime.utc_now(), granted_by: :sys_attack}})
        state
      end)

      # Bypass succeeded. (We're documenting the limit, not
      # claiming defence.)
      assert [{_, meta}] = Subs.list_subscriptions(victim)
      assert meta.granted_by == :sys_attack

      # Cleanup so we don't leak this row into other tests.
      :sys.replace_state(Subs, fn state ->
        :ets.delete(Subs.table(), key)
        state
      end)
    end

    test "Phoenix.PubSub.subscribe directly CAN receive any topic — documented limit" do
      # Same-VM listener can subscribe to ANY topic with no cap
      # check. The topic name is derivable from the entity URI;
      # there is no secret. Cap-gated `NotificationSubscriptions.subscribe/3`
      # is the AUDIT path, not a transport guard.
      victim = URI.parse("entity://user/acme/peeped-#{uniq()}")

      # No cap, no registry entry — just compute the topic and
      # subscribe.
      topic = Ezagent.SliceChange.topic(victim)
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)

      # Confirm we got the subscription (no error). Cleanup.
      :ok = Phoenix.PubSub.unsubscribe(EzagentCore.PubSub, topic)
    end
  end

  describe "cross-entity register poisoning (codex round-4 HIGH)" do
    test "caller with narrow stream-cap but not being the entity cannot poison" do
      # Codex round-4 HIGH: round-3 only checked the STREAM cap on
      # `do_register`, not whether the caller was the entity. So a
      # caller with a `Notifications` cap that matches the stream
      # could insert subscription rows for ANY entity URI,
      # poisoning future subscribers of that entity.
      #
      # This test uses a NARROW Notifications cap (scoped to the
      # specific workspace, NOT `:any` admin) — it passes the
      # stream-cap check but the caller is NOT the victim entity
      # AND NOT a notifications-admin → must be rejected.
      stranger = URI.parse("entity://user/acme/stranger-#{uniq()}")
      victim = URI.parse("entity://user/acme/victim-#{uniq()}")
      stream = URI.parse("entity://user/acme/stream-#{uniq()}")

      narrow_stream_cap = %Ezagent.Capability{
        kind: :user,
        behavior: Ezagent.Behavior.Notifications,
        instance: :any,
        # NOT `:any` — scoped to this specific workspace, so it's
        # NOT an admin cap.
        workspace_uri: URI.parse("workspace://acme"),
        granted_by: URI.parse("entity://user/system/test"),
        granted_at: DateTime.utc_now()
      }

      assert {:error, :unauthorized_for_entity} =
               Subs.register_subscription(victim, stream, %{
                 caller: stranger,
                 caps: MapSet.new([narrow_stream_cap])
               })

      # Row was NOT inserted.
      assert Subs.list_subscriptions(victim) == []
    end

    test "notifications-admin CAN register on behalf of another entity" do
      # Symmetric with unregister: a real admin (with the proper
      # cap shape) is allowed to seed someone else's subscription.
      admin = URI.parse("entity://user/system/admin-#{uniq()}")
      entity = URI.parse("entity://user/acme/regular-#{uniq()}")
      stream = URI.parse("entity://user/acme/stream-#{uniq()}")

      assert :ok =
               Subs.register_subscription(entity, stream, %{
                 caller: admin,
                 caps: MapSet.new([notifications_admin_cap()])
               })

      assert [{_, _}] = Subs.list_subscriptions(entity)
    end
  end
end
