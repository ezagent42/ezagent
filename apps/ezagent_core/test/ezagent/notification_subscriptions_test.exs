defmodule Ezagent.NotificationSubscriptionsTest do
  @moduledoc """
  PR-N1 skeleton tests for the subscription registry (Allen
  2026-05-24 amendment).

  Wider integration (LV mount consults registry) lands PR-N2.
  """

  use ExUnit.Case, async: false

  alias Ezagent.NotificationSubscriptions, as: Subs

  defp uniq, do: System.unique_integer([:positive])

  defp admin_cap do
    %Ezagent.Capability{
      kind: :user,
      behavior: Ezagent.Behavior.Notifications,
      instance: :any,
      workspace_uri: :any,
      granted_by: URI.parse("entity://user/system/test"),
      granted_at: DateTime.utc_now()
    }
  end

  test "register + list + unregister flow" do
    entity = URI.parse("entity://user/acme/alice-#{uniq()}")
    stream = URI.parse("entity://user/acme/bob-#{uniq()}")

    assert Subs.list_subscriptions(entity) == []

    assert :ok = Subs.register_subscription(entity, stream, %{caps: :system})

    subs = Subs.list_subscriptions(entity)
    assert length(subs) == 1
    assert [{stream_str, meta}] = subs
    assert stream_str == URI.to_string(stream)
    assert %DateTime{} = meta.registered_at

    assert :ok = Subs.unregister_subscription(entity, stream)
    assert Subs.list_subscriptions(entity) == []
  end

  test "list_subscribers reverse lookup" do
    stream = URI.parse("entity://user/acme/popular-#{uniq()}")
    alice = URI.parse("entity://user/acme/alice-#{uniq()}")
    bob = URI.parse("entity://user/acme/bob-#{uniq()}")

    Subs.register_subscription(alice, stream, %{caps: :system})
    Subs.register_subscription(bob, stream, %{caps: :system})

    subscribers = Subs.list_subscribers(stream) |> Enum.sort()
    assert URI.to_string(alice) in subscribers
    assert URI.to_string(bob) in subscribers
  end

  test "subscriptions are scoped per entity" do
    a = URI.parse("entity://user/acme/a-#{uniq()}")
    b = URI.parse("entity://user/acme/b-#{uniq()}")
    s1 = URI.parse("entity://user/acme/s1-#{uniq()}")
    s2 = URI.parse("entity://user/acme/s2-#{uniq()}")

    Subs.register_subscription(a, s1, %{caps: :system})
    Subs.register_subscription(b, s2, %{caps: :system})

    a_subs = Subs.list_subscriptions(a) |> Enum.map(fn {s, _} -> s end)
    b_subs = Subs.list_subscriptions(b) |> Enum.map(fn {s, _} -> s end)

    assert URI.to_string(s1) in a_subs
    refute URI.to_string(s2) in a_subs
    assert URI.to_string(s2) in b_subs
    refute URI.to_string(s1) in b_subs
  end

  test "unregister is idempotent on missing row" do
    entity = URI.parse("entity://user/acme/never-#{uniq()}")
    stream = URI.parse("entity://user/acme/none-#{uniq()}")
    assert :ok = Subs.unregister_subscription(entity, stream)
  end

  test "string-form entity URI works" do
    entity_str = "entity://user/acme/string-#{uniq()}"
    stream = URI.parse("entity://user/acme/s-#{uniq()}")

    assert :ok = Subs.register_subscription(URI.parse(entity_str), stream, %{caps: :system})
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
                 caps: MapSet.new([admin_cap()]),
                 caller: entity
               })

      assert [{_, _}] = Subs.list_subscriptions(entity)
    end
  end

  describe "unregister authorization (codex PR-N1 round-1 HIGH-3 fix)" do
    test "owner can unregister their own subscription" do
      entity = URI.parse("entity://user/acme/owner-#{uniq()}")
      stream = URI.parse("entity://user/acme/stream-#{uniq()}")

      Subs.register_subscription(entity, stream, %{caps: :system})

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

      Subs.register_subscription(owner, stream, %{caps: :system})

      assert {:error, :unauthorized} =
               Subs.unregister_subscription(owner, stream, %{
                 caller: stranger,
                 caps: MapSet.new()
               })

      # Subscription survives the attempted hijack.
      assert [{_, _}] = Subs.list_subscriptions(owner)
    end

    test "admin (workspace_uri: :any cap) can unregister anyone" do
      owner = URI.parse("entity://user/acme/owner-#{uniq()}")
      admin = URI.parse("entity://user/system/admin-#{uniq()}")
      stream = URI.parse("entity://user/acme/stream-#{uniq()}")

      Subs.register_subscription(owner, stream, %{caps: :system})

      assert :ok =
               Subs.unregister_subscription(owner, stream, %{
                 caller: admin,
                 caps: MapSet.new([admin_cap()])
               })

      assert Subs.list_subscriptions(owner) == []
    end

    test "ctx without :caller is rejected" do
      entity = URI.parse("entity://user/acme/alice-#{uniq()}")
      stream = URI.parse("entity://user/acme/stream-#{uniq()}")

      Subs.register_subscription(entity, stream, %{caps: :system})

      assert {:error, :unauthorized} =
               Subs.unregister_subscription(entity, stream, %{caps: MapSet.new()})
    end
  end
end
