defmodule Ezagent.NotificationSubscriptionsTest do
  @moduledoc """
  PR-N1 skeleton tests for the subscription registry (Allen
  2026-05-24 amendment).

  Round-2 hardening: every call uses EXPLICIT ctx (codex round-2
  CRITICAL). Trusted internal call sites use the `system_*` helpers.
  Wider integration (LV mount consults registry) lands PR-N2.
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

  test "register + list + system-unregister flow" do
    entity = URI.parse("entity://user/acme/alice-#{uniq()}")
    stream = URI.parse("entity://user/acme/bob-#{uniq()}")

    assert Subs.list_subscriptions(entity) == []

    assert :ok = Subs.system_register(entity, stream)

    subs = Subs.list_subscriptions(entity)
    assert length(subs) == 1
    assert [{stream_str, meta}] = subs
    assert stream_str == URI.to_string(stream)
    assert %DateTime{} = meta.registered_at

    assert :ok = Subs.system_unregister(entity, stream)
    assert Subs.list_subscriptions(entity) == []
  end

  test "list_subscribers reverse lookup" do
    stream = URI.parse("entity://user/acme/popular-#{uniq()}")
    alice = URI.parse("entity://user/acme/alice-#{uniq()}")
    bob = URI.parse("entity://user/acme/bob-#{uniq()}")

    Subs.system_register(alice, stream)
    Subs.system_register(bob, stream)

    subscribers = Subs.list_subscribers(stream) |> Enum.sort()
    assert URI.to_string(alice) in subscribers
    assert URI.to_string(bob) in subscribers
  end

  test "subscriptions are scoped per entity" do
    a = URI.parse("entity://user/acme/a-#{uniq()}")
    b = URI.parse("entity://user/acme/b-#{uniq()}")
    s1 = URI.parse("entity://user/acme/s1-#{uniq()}")
    s2 = URI.parse("entity://user/acme/s2-#{uniq()}")

    Subs.system_register(a, s1)
    Subs.system_register(b, s2)

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

    assert :ok = Subs.system_register(URI.parse(entity_str), stream)
    assert [{_, _}] = Subs.list_subscriptions(entity_str)
  end

  describe "cap enforcement (codex PR-N1 round-1 CRITICAL fix)" do
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

      assert {:error, :missing_caps_in_ctx} =
               Subs.register_subscription(entity, stream, %{})
    end

    test "matching Behavior.Notifications cap is accepted" do
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

  describe "explicit ctx required (codex PR-N1 round-2 CRITICAL fix)" do
    test "register_subscription/2 (no ctx) is a function-clause error" do
      stream = URI.parse("entity://user/acme/bob-#{uniq()}")

      # Arity-2 form was the bypass; it no longer exists. Confirm
      # the function is undefined / arity-mismatch.
      refute function_exported?(Subs, :register_subscription, 2)
      refute function_exported?(Subs, :unregister_subscription, 2)

      # And the 3-arity with invalid args returns :invalid_args, not :ok.
      assert {:error, :invalid_args} =
               Subs.register_subscription(:not_a_uri, stream, %{caps: :system})
    end

    test "system_register/2 is the explicit trusted helper" do
      entity = URI.parse("entity://user/acme/system-#{uniq()}")
      stream = URI.parse("entity://user/acme/bob-#{uniq()}")

      # Grep target: `system_register` call sites should be rare +
      # auditable.
      assert :ok = Subs.system_register(entity, stream)
      assert [{_, _}] = Subs.list_subscriptions(entity)
    end
  end

  describe "unregister authorization (codex round-1 HIGH-3 + round-2 HIGH-3 fix)" do
    test "owner can unregister their own subscription" do
      entity = URI.parse("entity://user/acme/owner-#{uniq()}")
      stream = URI.parse("entity://user/acme/stream-#{uniq()}")

      Subs.system_register(entity, stream)

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

      Subs.system_register(owner, stream)

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

      Subs.system_register(owner, stream)

      assert :ok =
               Subs.unregister_subscription(owner, stream, %{
                 caller: admin,
                 caps: MapSet.new([notifications_admin_cap()])
               })

      assert Subs.list_subscriptions(owner) == []
    end

    test "narrow cross-workspace cap (non-Notifications) does NOT count as admin" do
      # Codex PR-N1 round-2 HIGH-3 regression test: round-1's
      # `has_admin_cap?` matched ANY `workspace_uri: :any` cap. This
      # asserts a cross-workspace Chat.send cap CANNOT unregister
      # someone else's notification subscription.
      owner = URI.parse("entity://user/acme/owner-#{uniq()}")
      stranger = URI.parse("entity://user/acme/stranger-#{uniq()}")
      stream = URI.parse("entity://user/acme/stream-#{uniq()}")

      Subs.system_register(owner, stream)

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

      Subs.system_register(entity, stream)

      assert {:error, :unauthorized} =
               Subs.unregister_subscription(entity, stream, %{caps: MapSet.new()})
    end
  end

  describe "public API rejects :system ctx (codex PR-N1 round-3 CRITICAL fix)" do
    test "register_subscription/3 with caps: :system returns :system_caps_not_allowed_in_public_api" do
      entity = URI.parse("entity://user/acme/sneaky-#{uniq()}")
      stream = URI.parse("entity://user/acme/target-#{uniq()}")

      # Round-2 trusted caller-supplied `%{caps: :system}` → bypass.
      # Round-3 explicitly rejects it. Public callers can NEVER get
      # system authority via the public API; bootstrap callers must
      # use `system_register/2` which uses a separate GenServer
      # message tag, not a ctx shape.
      assert {:error, :system_caps_not_allowed_in_public_api} =
               Subs.register_subscription(entity, stream, %{
                 caps: :system,
                 caller: entity
               })

      assert Subs.list_subscriptions(entity) == []
    end

    test "unregister_subscription/3 with caps: :system returns :system_caps_not_allowed_in_public_api" do
      owner = URI.parse("entity://user/acme/owner-#{uniq()}")
      stream = URI.parse("entity://user/acme/stream-#{uniq()}")

      Subs.system_register(owner, stream)

      assert {:error, :system_caps_not_allowed_in_public_api} =
               Subs.unregister_subscription(owner, stream, %{
                 caps: :system,
                 caller: URI.parse("entity://user/acme/stranger-#{uniq()}")
               })

      assert [{_, _}] = Subs.list_subscriptions(owner)
    end
  end

  describe "protected ETS boundary (codex PR-N1 round-2 HIGH-1 fix)" do
    test "table is :protected — direct :ets.insert from non-owner raises" do
      entity_str = "entity://user/acme/sneaky-#{uniq()}"
      stream_str = "entity://user/acme/target-#{uniq()}"

      # Attempting to bypass the cap gate via raw `:ets.insert/2`
      # MUST fail because the table is `:protected` and we are not
      # the owner GenServer.
      assert_raise ArgumentError, fn ->
        :ets.insert(
          Subs.table(),
          {{entity_str, stream_str}, %{registered_at: DateTime.utc_now()}}
        )
      end

      # And no row leaked in.
      assert Subs.list_subscriptions(entity_str) == []
    end

    test "table is :protected — direct :ets.delete from non-owner raises" do
      assert_raise ArgumentError, fn ->
        :ets.delete(Subs.table(), {"any", "key"})
      end
    end
  end
end
