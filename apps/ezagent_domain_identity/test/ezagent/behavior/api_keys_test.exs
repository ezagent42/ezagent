defmodule Ezagent.Behavior.ApiKeysTest do
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.ApiKeys

  describe "init_slice/1" do
    test "starts with empty keys and nil creator_uri" do
      assert ApiKeys.init_slice(%{}) == %{keys: %{}, creator_uri: nil}
    end

    test "captures creator_uri when provided" do
      creator = URI.parse("entity://user/system/admin")
      assert ApiKeys.init_slice(%{creator_uri: creator}) == %{keys: %{}, creator_uri: creator}
    end
  end

  describe "invoke(:put_api_key, ...)" do
    test "adds a key" do
      slice = ApiKeys.init_slice(%{})
      args = %{provider: "deepseek", key: "sk-1234567890abcdef"}

      assert {:ok, new_slice, %{ok: true, provider: "deepseek"}} =
               ApiKeys.invoke(:put_api_key, slice, args, %{})

      assert new_slice.keys == %{"deepseek" => "sk-1234567890abcdef"}
    end

    test "overwrites existing key for the same provider (rotation)" do
      slice = %{keys: %{"deepseek" => "sk-old-key-xxxx"}, creator_uri: nil}
      args = %{provider: "deepseek", key: "sk-new-key-yyyy"}

      assert {:ok, new_slice, _} = ApiKeys.invoke(:put_api_key, slice, args, %{})
      assert new_slice.keys["deepseek"] == "sk-new-key-yyyy"
    end

    test "preserves creator_uri on put" do
      creator = URI.parse("entity://user/team-alpha/alice")
      slice = %{keys: %{}, creator_uri: creator}

      assert {:ok, new_slice, _} =
               ApiKeys.invoke(:put_api_key, slice, %{provider: "deepseek", key: "sk-aaaabbbbccccdddd"}, %{})

      assert new_slice.creator_uri == creator
    end
  end

  describe "invoke(:list_api_keys, ...)" do
    test "returns masked keys, sorted by provider" do
      slice = %{
        keys: %{
          "openai" => "sk-aaaabbbbccccdddd",
          "deepseek" => "sk-1234567890abcdef"
        },
        creator_uri: nil
      }

      assert {:ok, _slice, %{api_keys: listing}} = ApiKeys.invoke(:list_api_keys, slice, %{}, %{})
      providers = Enum.map(listing, & &1.provider)
      assert providers == ["deepseek", "openai"]

      [first, _second] = listing
      assert first.provider == "deepseek"
      assert first.masked == "sk-1234...cdef"
      refute String.contains?(first.masked, "567890abc")
    end

    test "empty slice returns empty list" do
      assert {:ok, _, %{api_keys: []}} =
               ApiKeys.invoke(:list_api_keys, ApiKeys.init_slice(%{}), %{}, %{})
    end
  end

  describe "invoke(:delete_api_key, ...)" do
    test "removes the provider entry" do
      slice = %{keys: %{"deepseek" => "sk-x"}, creator_uri: nil}

      assert {:ok, new_slice, %{ok: true}} =
               ApiKeys.invoke(:delete_api_key, slice, %{provider: "deepseek"}, %{})

      assert new_slice.keys == %{}
    end

    test "deleting a non-existent provider is a no-op" do
      slice = %{keys: %{}, creator_uri: nil}

      assert {:ok, ^slice, %{ok: true}} =
               ApiKeys.invoke(:delete_api_key, slice, %{provider: "ghost"}, %{})
    end
  end

  describe "invoke(:get_api_key, ...)" do
    test "returns the plaintext for a registered provider" do
      slice = %{keys: %{"deepseek" => "sk-1234567890abcdef"}, creator_uri: nil}

      assert {:ok, _slice, %{key: "sk-1234567890abcdef", provider: "deepseek"}} =
               ApiKeys.invoke(:get_api_key, slice, %{provider: "deepseek"}, %{})
    end

    test "errors for an unknown provider" do
      slice = ApiKeys.init_slice(%{})

      assert {:error, {:no_api_key, "missing"}} =
               ApiKeys.invoke(:get_api_key, slice, %{provider: "missing"}, %{})
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

        assert cap.behavior == Ezagent.Behavior.ApiKeys
      end
    end
  end

  describe "data_owner/1 (Allen 2026-05-26)" do
    test "non-agent URI → :no_owner" do
      assert ApiKeys.data_owner(URI.parse("entity://user/system/admin")) == :no_owner
    end

    test ":any sentinel passes through" do
      assert ApiKeys.data_owner(:any) == :any
    end

    test "agent URI whose Kind isn't live → :no_owner" do
      # No KindRegistry entry for this URI → get_slice returns :error.
      assert ApiKeys.data_owner(
               URI.parse(
                 "entity://agent/team-alpha/curl_no-such-#{System.unique_integer([:positive])}"
               )
             ) == :no_owner
    end
  end
end
