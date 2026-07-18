defmodule Ezagent.Cap.SigningTest do
  use ExUnit.Case, async: false

  alias Ezagent.{Cap, Capability}
  alias Ezagent.Cap.Signing

  @workspace Ezagent.URI.new!("workspace://team-alpha")
  @issuer Ezagent.URI.new!("entity://team-alpha/user/issuer")
  @grantee Ezagent.URI.new!("entity://team-alpha/user/alice")
  @other_grantee Ezagent.URI.new!("entity://team-alpha/user/bob")
  @instance Ezagent.URI.new!("session://team-alpha/default/chat")

  setup do
    previous = Application.get_env(:ezagent_core, Cap, [])
    signing = previous |> Keyword.get(:signing, []) |> Keyword.put(:trusted_key_versions, [1])
    Application.put_env(:ezagent_core, Cap, Keyword.put(previous, :signing, signing))
    on_exit(fn -> Application.put_env(:ezagent_core, Cap, previous) end)
  end

  describe "signing_payload/1" do
    test "canonicalizes module, URI, NFC, wildcard, and millisecond timestamp values" do
      cap = %Capability{
        kind: :any,
        behavior: Ezagent.ActionSet.Session,
        action: :any,
        instance: @instance,
        workspace_uri: :any,
        granted_by: @issuer,
        granted_at: ~U[2026-07-14 12:34:56.789123Z],
        key_id: "kind-g1|cafe\u0301",
        grantee_uri: @grantee
      }

      payload = Signing.signing_payload(cap)

      assert payload =~ "\"behavior\":\"Ezagent.ActionSet.Session\""
      assert payload =~ "\"instance\":\"#{Ezagent.URI.stable_key(@instance)}\""
      assert payload =~ "\"workspace_uri\":\"any\""
      assert payload =~ "\"kind\":\"any\""
      assert payload =~ "\"action\":\"any\""
      assert payload =~ "\"granted_at\":\"2026-07-14T12:34:56.789Z\""
      assert payload =~ "\"key_id\":\"kind-g1|caf\u00E9\""
      assert payload =~ "\"grantee\":\"#{Ezagent.URI.stable_key(@grantee)}\""
      refute payload =~ "cafe\u0301"
    end

    test "binds the explicit payload form to the artifact grantee" do
      cap = golden_cap()

      assert Signing.signing_payload(cap) == Signing.signing_payload(cap, @grantee)

      assert_raise FunctionClauseError, fn ->
        Signing.signing_payload(cap, @other_grantee)
      end
    end

    test "requires a concrete URI grantee" do
      for invalid_grantee <- [nil, :any, :not_a_uri] do
        assert_raise ArgumentError, ~r/cap signing URI is not canonicalizable/, fn ->
          Signing.signing_payload(%{golden_cap() | grantee_uri: invalid_grantee})
        end
      end
    end

    test "renders a scope tuple as an ordered JCS array" do
      cap = %{golden_cap() | instance: {:within_workspace, @workspace}}

      assert Signing.signing_payload(cap) =~
               "\"instance\":[\"within_workspace\",\"workspace://team-alpha\"]"
    end

    test "uses JCS short escapes and lowercase unicode escapes" do
      cap = %{golden_cap() | key_id: "kind-g1|\"\\\b\t\n\f\r\u0001"}

      assert Signing.signing_payload(cap) =~
               "\"key_id\":\"kind-g1|\\\"\\\\\\b\\t\\n\\f\\r\\u0001\""
    end

    test "pins the cross-language canonical payload independently from storage encoders" do
      assert Signing.signing_payload(golden_cap()) ==
               ~s({"action":"send","behavior":"Ezagent.ActionSet.Session","granted_at":"2026-07-14T12:34:56.789Z","granted_by":"entity://team-alpha/user/issuer","grantee":"entity://team-alpha/user/alice","instance":"session://team-alpha/default/chat","key_id":"kind-g1:test-key","kind":"session","v":1,"workspace_uri":"workspace://team-alpha"})
    end
  end

  describe "trust_domain/1" do
    test "is total and separates concrete and any workspaces" do
      concrete_domain = Signing.trust_domain(@workspace)

      assert concrete_domain == "w:" <> Ezagent.URI.stable_key(@workspace)
      assert Signing.trust_domain(:any) == "a:*"
      refute concrete_domain == "a:*"

      assert_raise ArgumentError, fn -> Signing.trust_domain(nil) end
      assert_raise ArgumentError, fn -> Signing.trust_domain(:not_a_workspace) end
    end
  end

  describe "key_id/2 and parse_key_id/2" do
    test "builds and parses a bounded base64url selector" do
      current_key_id = Signing.key_id(1, Signing.trust_domain(@workspace))

      assert current_key_id == "v1|dzp3b3Jrc3BhY2U6Ly90ZWFtLWFscGhh"
      assert {:ok, 1} = Signing.parse_key_id(current_key_id, @workspace)
      assert :error = Signing.parse_key_id(current_key_id, :any)
      assert :error = Signing.parse_key_id("v1|not+base64url", @workspace)
      assert :error = Signing.parse_key_id("v1|", @workspace)
      assert :error = Signing.parse_key_id("v1|" <> String.duplicate("a", 509), @workspace)

      assert_raise ArgumentError, ~r/exceeds the protocol limit/, fn ->
        Signing.key_id(1, String.duplicate("x", 384))
      end
    end

    test "keeps a pipe in a helper-level trust domain unambiguous" do
      key_id = Signing.key_id(2, "w:tenant|alpha")

      assert ["v2", encoded_domain] = String.split(key_id, "|")
      refute encoded_domain =~ "|"
      assert {:ok, 2, "w:tenant|alpha"} = Signing.parse_key_id(key_id)
    end
  end

  test "signing bytes do not depend on storage encoders" do
    source = File.read!(Path.expand("../../../lib/ezagent/cap/signing.ex", __DIR__))

    refute source =~ "term" <> "_to_binary"
    refute source =~ "Jason." <> "encode"
    refute source =~ "URI." <> "to_string"
  end

  defp golden_cap do
    %Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: :send,
      instance: @instance,
      workspace_uri: @workspace,
      granted_by: @issuer,
      granted_at: ~U[2026-07-14 12:34:56.789123Z],
      key_id: "kind-g1:test-key",
      grantee_uri: @grantee
    }
  end
end
