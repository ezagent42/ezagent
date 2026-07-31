defmodule Ezagent.ActionSet.ApiKeysTest do
  @moduledoc """
  P2-b migration (2026-05-28): rewritten to exercise the new-contract
  `handle_<action>/2` handlers. Dispatch parity via Kind.Runtime lives
  in `api_keys_migration_parity_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.ApiKeys

  defp ctx_with_keys(keys) do
    %{
      caller: :vm_internal,
      caps: MapSet.new(),
      self_uri: Ezagent.URI.new!("entity://team-alpha/agent/curl_test"),
      reply: :sync,
      read: fn key, default ->
        case key do
          :keys -> keys
          _ -> default
        end
      end
    }
  end

  # Phase B: `init_slice/1` → `create/1` (builds the PERSISTENT state).
  describe "create/1" do
    test "starts with empty keys and nil creator_uri" do
      assert ApiKeys.create(%{}) == {:ok, %{keys: %{}, creator_uri: nil}}
    end

    test "captures creator_uri when provided" do
      creator = Ezagent.URI.new!("entity://system/user/admin")
      assert ApiKeys.create(%{creator_uri: creator}) == {:ok, %{keys: %{}, creator_uri: creator}}
    end
  end

  describe "handle_put_api_key/2" do
    test "adds a key + emits :set + :emit effects" do
      ctx = ctx_with_keys(%{})
      args = %{provider: "deepseek", key: "sk-1234567890abcdef"}

      assert {:ok, %{ok: true, provider: "deepseek"}, effects} =
               ApiKeys.handle_put_api_key(args, ctx)

      assert {:set, :keys, %{"deepseek" => "sk-1234567890abcdef"}} in effects
      assert Enum.any?(effects, &match?({:emit, :api_key_put, _}, &1))
    end

    test "overwrites existing key for the same provider (rotation)" do
      ctx = ctx_with_keys(%{"deepseek" => "sk-old-key-xxxx"})
      args = %{provider: "deepseek", key: "sk-new-key-yyyy"}

      assert {:ok, _result, effects} = ApiKeys.handle_put_api_key(args, ctx)
      assert {:set, :keys, %{"deepseek" => "sk-new-key-yyyy"}} in effects
    end
  end

  describe "handle_list_api_keys/2" do
    test "returns masked keys, sorted by provider (no effects)" do
      ctx =
        ctx_with_keys(%{
          "openai" => "sk-aaaabbbbccccdddd",
          "deepseek" => "sk-1234567890abcdef"
        })

      assert {:ok, %{api_keys: listing}, []} = ApiKeys.handle_list_api_keys(%{}, ctx)

      providers = Enum.map(listing, & &1.provider)
      assert providers == ["deepseek", "openai"]

      [first, _second] = listing
      assert first.provider == "deepseek"
      assert first.masked == "sk-1234...cdef"
      refute String.contains?(first.masked, "567890abc")
    end

    test "empty slice returns empty list" do
      ctx = ctx_with_keys(%{})
      assert {:ok, %{api_keys: []}, []} = ApiKeys.handle_list_api_keys(%{}, ctx)
    end
  end

  describe "handle_delete_api_key/2" do
    test "removes the provider entry via :set effect" do
      ctx = ctx_with_keys(%{"deepseek" => "sk-x", "openai" => "sk-y"})

      assert {:ok, %{ok: true, provider: "deepseek"}, effects} =
               ApiKeys.handle_delete_api_key(%{provider: "deepseek"}, ctx)

      assert {:set, :keys, %{"openai" => "sk-y"}} in effects
      assert Enum.any?(effects, &match?({:emit, :api_key_deleted, _}, &1))
    end

    test "deleting a non-existent provider produces an empty-result :set effect" do
      ctx = ctx_with_keys(%{})

      assert {:ok, %{ok: true}, effects} =
               ApiKeys.handle_delete_api_key(%{provider: "ghost"}, ctx)

      assert {:set, :keys, %{}} in effects
    end
  end

  describe "handle_get_api_key/2" do
    test "returns the plaintext for a registered provider (no effects)" do
      ctx = ctx_with_keys(%{"deepseek" => "sk-1234567890abcdef"})

      assert {:ok, %{key: "sk-1234567890abcdef", provider: "deepseek"}, []} =
               ApiKeys.handle_get_api_key(%{provider: "deepseek"}, ctx)
    end

    test "errors for an unknown provider" do
      ctx = ctx_with_keys(%{})

      assert {:error, {:no_api_key, "missing"}} =
               ApiKeys.handle_get_api_key(%{provider: "missing"}, ctx)
    end
  end

  describe "mask/1" do
    test "sk-prefixed key shows first 4 + last 4" do
      assert ApiKeys.mask("sk-1234567890abcdef") == "sk-1234...cdef"
    end

    test "non-sk key still gets first 4 + last 4" do
      assert ApiKeys.mask("abcdefghij1234567890") == "abcd...7890"
    end

    test "short keys collapse to ***" do
      assert ApiKeys.mask("short") == "***"
    end
  end

  describe "required_caps/0 (Allen 2026-05-26 — kind axis is :any post Agent-flip)" do
    test "every action's cap uses :any kind axis" do
      for {_action, %Ezagent.Capability{} = cap} <- ApiKeys.required_caps() do
        assert cap.kind == :any,
               "ApiKeys is registered against multiple agent-flavor Kinds " <>
                 "(Agent / CurlAgent / Echo) — required_caps/0 MUST use :any " <>
                 "so a granted cap on any flavor matches. Got: #{inspect(cap)}"

        assert cap.behavior == Ezagent.ActionSet.ApiKeys
      end
    end
  end

  describe "data_owner/1 (Allen 2026-05-26)" do
    test "non-agent URI → :no_owner" do
      assert ApiKeys.data_owner(Ezagent.URI.new!("entity://system/user/admin")) == :no_owner
    end

    test ":any sentinel passes through" do
      assert ApiKeys.data_owner(:any) == :any
    end

    test "agent URI whose Kind isn't live → :no_owner" do
      assert ApiKeys.data_owner(
               URI.parse(
                 "entity://team-alpha/agent/curl_no-such-#{System.unique_integer([:positive])}"
               )
             ) == :no_owner
    end
  end

  describe "handle_put_api_key_if_absent/2 (CAS)" do
    test "empty slot: stores the key + emits :set + :emit, set: true" do
      ctx = ctx_with_keys(%{})
      args = %{provider: "deepseek", key: "sk-cas-new-key-0001"}

      assert {:ok, %{ok: true, provider: "deepseek", set: true}, effects} =
               ApiKeys.handle_put_api_key_if_absent(args, ctx)

      assert {:set, :keys, %{"deepseek" => "sk-cas-new-key-0001"}} in effects
      assert Enum.any?(effects, &match?({:emit, :api_key_put, _}, &1))
    end

    test "occupied slot: NEVER overwrites — set: false with NO effects" do
      ctx = ctx_with_keys(%{"deepseek" => "sk-operator-rotated-key"})
      args = %{provider: "deepseek", key: "sk-stale-seed-key"}

      assert {:ok, %{ok: true, provider: "deepseek", set: false}, []} =
               ApiKeys.handle_put_api_key_if_absent(args, ctx)
    end

    test "empty-string slot counts as absent (refills)" do
      ctx = ctx_with_keys(%{"deepseek" => ""})
      args = %{provider: "deepseek", key: "sk-cas-refill-key"}

      assert {:ok, %{ok: true, set: true}, effects} =
               ApiKeys.handle_put_api_key_if_absent(args, ctx)

      assert {:set, :keys, %{"deepseek" => "sk-cas-refill-key"}} in effects
    end

    test "bad args: error reason NEVER echoes the key" do
      ctx = ctx_with_keys(%{})

      assert {:error, {:bad_args, message}} =
               ApiKeys.handle_put_api_key_if_absent(%{provider: "", key: "sk-secret-xyz"}, ctx)

      refute message =~ "sk-secret-xyz"
    end

    test "authorized by the :put_api_key cap subject (CAS is strictly weaker)" do
      assert ApiKeys.required_caps()[:put_api_key_if_absent] ==
               Ezagent.Capability.cap(:any, ApiKeys, :put_api_key)
    end
  end

  describe "P2-b new-contract markers" do
    test "__behavior__?/0 is true" do
      assert ApiKeys.__behavior__?() == true
    end

    test "__action_names__/0 lists all five actions" do
      assert Enum.sort(ApiKeys.__action_names__()) ==
               [
                 :delete_api_key,
                 :get_api_key,
                 :list_api_keys,
                 :put_api_key,
                 :put_api_key_if_absent
               ]
    end
  end
end
