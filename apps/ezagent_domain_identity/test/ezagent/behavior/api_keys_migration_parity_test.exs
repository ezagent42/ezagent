defmodule Ezagent.ActionSet.ApiKeysMigrationParityTest do
  @moduledoc """
  P2-b migration parity test (SPEC #445 §7.3 Level 1 — dispatch
  parity).

  Validates that the migrated `Ezagent.ActionSet.ApiKeys` produces the
  same dispatch-visible outcome via the new-contract path
  (`Kind.Runtime.handle_dispatch/4` → `handle_<action>/2` →
  `apply_effects/2`) as the legacy `invoke/4` shape did pre-migration.

  Uses a stub Kind module (the real `Ezagent.Entity.Agent` lives in
  `ezagent_domain_session`, outside this app's dep graph; we don't need
  the real Kind to exercise the dispatch contract, only a module that
  declares `behaviors/0 == [ApiKeys]`).
  """

  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [signed_invocation!: 2, signed_required_cap!: 5]

  alias Ezagent.{BehaviorRegistry, Invocation}
  alias Ezagent.ActionSet.ApiKeys

  defmodule StubAgentKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :api_keys_parity_stub
    @impl true
    def behaviors, do: [Ezagent.ActionSet.ApiKeys]
    @impl true
    def persistence, do: :ephemeral
  end

  setup do
    :ok = BehaviorRegistry.register(StubAgentKind, :list_api_keys, ApiKeys)
    :ok = BehaviorRegistry.register(StubAgentKind, :put_api_key, ApiKeys)
    :ok = BehaviorRegistry.register(StubAgentKind, :delete_api_key, ApiKeys)
    :ok = BehaviorRegistry.register(StubAgentKind, :get_api_key, ApiKeys)

    agent_uri =
      Ezagent.URI.new!("entity://parity/agent/curl_agent-#{System.unique_integer([:positive])}")

    state = %{api_keys: ApiKeys.init_slice(%{})}

    {:ok, agent_uri: agent_uri, state: state}
  end

  defp build_invocation(agent_uri, action, args) do
    target = Ezagent.URI.new!("#{URI.to_string(agent_uri)}?action=api_keys.#{action}")

    admin = Ezagent.URI.user(:system, :admin)
    cap = signed_required_cap!(target, :api_keys_parity_stub, ApiKeys, action, admin)

    %Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: %{caller: admin, caps: MapSet.new([cap]), reply: :sync}
    }
    |> signed_invocation!(:api_keys_parity_stub)
  end

  describe "Level 1 — dispatch parity through Kind.Runtime" do
    test "put_api_key dispatch updates slice via :set effect",
         %{agent_uri: agent_uri, state: state} do
      inv =
        build_invocation(agent_uri, :put_api_key, %{
          provider: "deepseek",
          key: "sk-aaaabbbbccccdddd"
        })

      assert {:ok, new_state, %{ok: true, provider: "deepseek"}, slice_change_event, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubAgentKind, agent_uri)

      # Phase B: two-container slice — persistent fields live under `.state`.
      assert new_state.api_keys.state.keys == %{"deepseek" => "sk-aaaabbbbccccdddd"}
      assert is_map(slice_change_event)
      assert slice_change_event.slice_key == :api_keys
    end

    test "list_api_keys dispatch is read-only (slice unchanged, no event)",
         %{agent_uri: agent_uri} do
      state = %{api_keys: %{keys: %{"openai" => "sk-aaaabbbbccccdddd"}, creator_uri: nil}}

      inv = build_invocation(agent_uri, :list_api_keys, %{})

      assert {:ok, new_state, %{api_keys: [%{provider: "openai", masked: masked}]}, nil,
              _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubAgentKind, agent_uri)

      assert new_state == state
      assert masked == "sk-aaaa...dddd"
    end

    test "delete_api_key dispatch removes the key via :set effect",
         %{agent_uri: agent_uri} do
      state = %{api_keys: %{keys: %{"deepseek" => "sk-x", "openai" => "sk-y"}, creator_uri: nil}}

      inv = build_invocation(agent_uri, :delete_api_key, %{provider: "deepseek"})

      assert {:ok, new_state, %{ok: true, provider: "deepseek"}, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubAgentKind, agent_uri)

      assert new_state.api_keys.keys == %{"openai" => "sk-y"}
    end

    test "get_api_key dispatch returns the plaintext (read-only, no slice mutation)",
         %{agent_uri: agent_uri} do
      state = %{api_keys: %{keys: %{"deepseek" => "sk-secret-plain"}, creator_uri: nil}}

      inv = build_invocation(agent_uri, :get_api_key, %{provider: "deepseek"})

      assert {:ok, new_state, %{key: "sk-secret-plain", provider: "deepseek"}, nil, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubAgentKind, agent_uri)

      assert new_state == state
    end

    test "get_api_key on missing provider returns :no_api_key error",
         %{agent_uri: agent_uri, state: state} do
      inv = build_invocation(agent_uri, :get_api_key, %{provider: "ghost"})

      assert {:error, {:no_api_key, "ghost"}} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubAgentKind, agent_uri)
    end
  end
end
