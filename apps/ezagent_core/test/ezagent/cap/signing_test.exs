defmodule Ezagent.Cap.SigningTest do
  use ExUnit.Case, async: false

  alias Ezagent.{Cap, Capability}
  alias Ezagent.Cap.Signing

  @seed "0123456789abcdef0123456789abcdef"
  @workspace Ezagent.URI.new!("workspace://team-alpha")
  @issuer Ezagent.URI.new!("entity://team-alpha/user/issuer")
  @instance Ezagent.URI.new!("session://team-alpha/default/chat")

  setup do
    previous = Application.get_env(:ezagent_core, Cap, [])

    put_signing_config(previous, fn
      1 -> {:ok, @seed}
      _version -> {:error, :missing_test_seed}
    end)

    on_exit(fn -> Application.put_env(:ezagent_core, Cap, previous) end)
  end

  describe "derive_keypair/3 and sign/2" do
    test "deterministically derives the same ed25519 keypair and signs its JCS payload" do
      trust_domain = Signing.trust_domain(@workspace)
      assert {public_key, private_key} = Signing.derive_keypair(@issuer, trust_domain, 1)
      assert {^public_key, ^private_key} = Signing.derive_keypair(@issuer, trust_domain, 1)

      cap = golden_cap()
      signature = Signing.sign(cap, private_key)

      assert Signing.verify(cap, signature, public_key)
      refute Signing.verify(%{cap | action: :receive}, signature, public_key)
    end
  end

  describe "signing_payload/1" do
    test "canonicalizes atom, module, URI, NFC, and millisecond timestamp values" do
      cap = %Capability{
        kind: :any,
        behavior: Ezagent.ActionSet.Session,
        action: :any,
        instance: @instance,
        workspace_uri: :any,
        granted_by: @issuer,
        granted_at: ~U[2026-07-14 12:34:56.789123Z],
        key_id: "v1|cafe\u{0301}"
      }

      payload = Signing.signing_payload(cap)

      assert payload =~ "\"behavior\":\"Ezagent.ActionSet.Session\""
      assert payload =~ "\"instance\":\"#{Ezagent.URI.stable_key(@instance)}\""
      assert payload =~ "\"workspace_uri\":\"any\""
      assert payload =~ "\"kind\":\"any\""
      assert payload =~ "\"action\":\"any\""
      assert payload =~ "\"granted_at\":\"2026-07-14T12:34:56.789Z\""
      assert payload =~ "\"key_id\":\"v1|caf\u{00E9}\""
      refute payload =~ "cafe\u{0301}"
    end

    test "renders the existing single scope tuple as its ordered JCS scope array" do
      cap = %Capability{
        kind: :session,
        behavior: Ezagent.ActionSet.Session,
        action: :send,
        instance: {:within_workspace, @workspace},
        workspace_uri: @workspace,
        granted_by: @issuer,
        granted_at: ~U[2026-07-14 12:34:56.789123Z],
        key_id: Signing.key_id(1, Signing.trust_domain(@workspace))
      }

      assert Signing.signing_payload(cap) =~
               "\"instance\":[\"within_workspace\",\"workspace://team-alpha\"]"
    end

    test "uses JCS short escapes and lowercase unicode escapes for control characters" do
      cap = %{golden_cap() | key_id: "v1|\"\\\b\t\n\f\r\u{0001}"}

      assert Signing.signing_payload(cap) =~
               "\"key_id\":\"v1|\\\"\\\\\\b\\t\\n\\f\\r\\u0001\""
    end

    test "pins the cross-language JCS and ed25519 golden vector" do
      cap = golden_cap()
      trust_domain = Signing.trust_domain(cap.workspace_uri)
      {_public_key, private_key} = Signing.derive_keypair(cap.granted_by, trust_domain, 1)

      assert Signing.signing_payload(cap) ==
               ~s({"action":"send","behavior":"Ezagent.ActionSet.Session","granted_at":"2026-07-14T12:34:56.789Z","granted_by":"entity://team-alpha/user/issuer","instance":"session://team-alpha/default/chat","key_id":"v1|dzp3b3Jrc3BhY2U6Ly90ZWFtLWFscGhh","kind":"session","v":1,"workspace_uri":"workspace://team-alpha"})

      assert Signing.sign(cap, private_key) |> Base.encode16(case: :lower) ==
               "2b7e291598966fc248f39b4fe28e06eb6df21bdb1933ec709933943fa4718f8ee8ee327314fea909bb7e768bfd8fc3b50e7d97c8a22821f9fc25c96c71e70508"
    end
  end

  describe "trust_domain/1" do
    test "is total and structurally separates concrete and any workspaces" do
      concrete_domain = Signing.trust_domain(@workspace)

      assert concrete_domain == "w:" <> Ezagent.URI.stable_key(@workspace)
      assert Signing.trust_domain(:any) == "a:*"
      assert Signing.trust_domain(Capability.admin_genesis_cap().workspace_uri) == "a:*"
      refute concrete_domain == "a:*"

      assert_raise ArgumentError, fn -> Signing.trust_domain(nil) end
      assert_raise ArgumentError, fn -> Signing.trust_domain(:not_a_workspace) end
    end
  end

  describe "key_id/2 and parse_key_id/2" do
    test "builds and parses the bounded base64url trust-domain selector" do
      key_id = Signing.key_id(17, Signing.trust_domain(@workspace))

      assert key_id == "v17|dzp3b3Jrc3BhY2U6Ly90ZWFtLWFscGhh"
      assert :error = Signing.parse_key_id(key_id, @workspace)

      assert_raise ArgumentError, fn ->
        Signing.parse_key_id(key_id, nil)
      end

      current_key_id = Signing.key_id(1, Signing.trust_domain(@workspace))

      assert {:ok, 1} = Signing.parse_key_id(current_key_id, @workspace)
      assert :error = Signing.parse_key_id(current_key_id, :any)
      assert :error = Signing.parse_key_id(key_id, :any)
      assert :error = Signing.parse_key_id("v17|not+base64url", @workspace)
      assert :error = Signing.parse_key_id("v17|", @workspace)
      assert :error = Signing.parse_key_id("v17|dzp3b3Jrc3BhY2U6Ly90ZWFtLWFscGhh!", @workspace)
      assert :error = Signing.parse_key_id("v17|" <> String.duplicate("a", 509), @workspace)

      assert_raise ArgumentError, ~r/exceeds the protocol limit/, fn ->
        Signing.key_id(1, String.duplicate("x", 384))
      end
    end

    test "keeps a pipe in a helper-level trust domain unambiguous through base64url" do
      key_id = Signing.key_id(2, "w:tenant|alpha")

      assert ["v2", encoded_domain] = String.split(key_id, "|")
      refute encoded_domain =~ "|"
      assert {:ok, 2, "w:tenant|alpha"} = Signing.parse_key_id(key_id)
    end
  end

  describe "seed failure behavior" do
    test "raises when the configured active signing seed is unavailable" do
      replace_seed_provider(fn _version -> {:error, :missing_seed} end)

      assert_raise RuntimeError, ~r/signing seed unavailable/, fn ->
        Signing.derive_keypair(@issuer, Signing.trust_domain(@workspace), 1)
      end
    end

    test "raises when the configured seed provider reports crypto material failure" do
      replace_seed_provider(fn _version -> {:error, :crypto_material_unavailable} end)

      assert_raise RuntimeError, ~r/signing seed unavailable/, fn ->
        Signing.derive_keypair(@issuer, Signing.trust_domain(@workspace), 1)
      end
    end

    test "raises when the configured seed material is too short for HKDF" do
      replace_seed_provider(fn _version -> {:ok, "short"} end)

      assert_raise RuntimeError, ~r/signing seed unavailable/, fn ->
        Signing.derive_keypair(@issuer, Signing.trust_domain(@workspace), 1)
      end
    end
  end

  test "the signing implementation does not source signed bytes from storage encoders" do
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
      key_id: "v1|dzp3b3Jrc3BhY2U6Ly90ZWFtLWFscGhh"
    }
  end

  defp replace_seed_provider(seed_provider) do
    config = Application.get_env(:ezagent_core, Cap, [])
    signing = Keyword.fetch!(config, :signing)

    Application.put_env(
      :ezagent_core,
      Cap,
      Keyword.put(config, :signing, Keyword.put(signing, :seed_provider, seed_provider))
    )
  end

  defp put_signing_config(previous, seed_provider) do
    signing = [seed_provider: seed_provider, active_key_version: 1, require_signature: false]
    Application.put_env(:ezagent_core, Cap, Keyword.put(previous, :signing, signing))
  end
end
