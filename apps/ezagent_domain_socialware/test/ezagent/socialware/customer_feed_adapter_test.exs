defmodule Ezagent.Socialware.CustomerFeedAdapterTest do
  @moduledoc """
  P3-2 — the customer feed is a registered `:pull` `ExternalAdapter`
  (`adapter_id: "customer_feed"`), declared as a BARE module (no binding).

  Mirrors the P3-1 pull-registration pattern: a `:pull` adapter registers with
  NO binding, spawns NO Worker, and its `allow_customer_feed` cap subject is
  registered on `Ezagent.Entity.Session`.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.ExternalMirror.{Adapter, AdapterRegistry, BindingRegistry}
  alias Ezagent.Socialware.CustomerFeedAdapter

  # The adapter render/2 + join protocol are exercised in
  # `customer_feed_join_protocol_test.exs`; this file is the :pull registration
  # contract (mirrors the P3-1 pull-registration pattern).

  test "declares adapter_kind :pull and the id/name/description trio" do
    assert CustomerFeedAdapter.adapter_kind() == :pull
    assert Adapter.kind_of(CustomerFeedAdapter) == :pull
    assert CustomerFeedAdapter.adapter_id() == "customer_feed"
    assert is_binary(CustomerFeedAdapter.display_name())
    assert is_binary(CustomerFeedAdapter.description())
  end

  test "is a bare pull declaration — NO binding_module/0, no transport callbacks" do
    refute function_exported?(CustomerFeedAdapter, :binding_module, 0)
    refute function_exported?(CustomerFeedAdapter, :target_ownership_check, 2)
    refute function_exported?(CustomerFeedAdapter, :event_to_payload, 1)
    assert function_exported?(CustomerFeedAdapter, :render, 2)
    assert function_exported?(CustomerFeedAdapter, :cap_subject, 0)
  end

  # The advisor plugin (the owning plugin) declares this adapter in adapters/0,
  # so it is already registered by boot in the test runtime — register/1 is
  # idempotent and returns {:ok, :already_present} on the same module.
  test "registers WITHOUT a binding and resolves via lookup" do
    assert AdapterRegistry.register(CustomerFeedAdapter) in [:ok, {:ok, :already_present}]
    assert {:ok, CustomerFeedAdapter} = AdapterRegistry.lookup("customer_feed")
    assert :error = BindingRegistry.lookup("customer_feed")
  end

  test "install hook registers the allow_customer_feed cap subject on Ezagent.Entity.Session" do
    assert AdapterRegistry.register(CustomerFeedAdapter) in [:ok, {:ok, :already_present}]

    assert {:ok, %{behavior: Ezagent.Socialware.CustomerFeedAdapter.Allow}} =
             Ezagent.CapabilityRegistry.lookup_subject(
               Ezagent.Entity.Session,
               :allow_customer_feed
             )
  end
end
