defmodule Ezagent.URI.SchemeRegistryTest do
  @moduledoc """
  PR #145 — runtime ETS scheme allowlist replaces hardcoded
  `@known_schemes` compile-time list. Plugins extend by calling
  `SpawnRegistry.register/2` which co-registers the scheme.

  This is the lockdown that prevents another `feishu://`-style
  documentation-drift bug where the allowlist gets out of sync with
  actual SpawnRegistry registrations.
  """
  use ExUnit.Case, async: false

  alias Ezagent.URI.SchemeRegistry

  describe "register/1 + registered?/1" do
    test "newly-registered scheme is registered" do
      scheme = "test-scheme-#{System.unique_integer([:positive])}"
      refute SchemeRegistry.registered?(scheme)

      :ok = SchemeRegistry.register(scheme)

      assert SchemeRegistry.registered?(scheme)
    end

    test "register is idempotent" do
      scheme = "idempotent-#{System.unique_integer([:positive])}"
      :ok = SchemeRegistry.register(scheme)
      :ok = SchemeRegistry.register(scheme)
      assert SchemeRegistry.registered?(scheme)
    end
  end

  describe "list_all/0" do
    test "returns sorted list of registered schemes" do
      all = SchemeRegistry.list_all()
      assert is_list(all)
      assert all == Enum.sort(all)
    end

    test "boot-seeded SPEC §5.6 schemes are present" do
      all = SchemeRegistry.list_all()

      for s <- ~w(entity workspace session template resource system) do
        assert s in all, "expected SPEC §5.6 scheme #{s} in allowlist; got #{inspect(all)}"
      end
    end
  end

  describe "Ezagent.URI.new!/1 — SchemeRegistry-backed" do
    test "accepts a registered scheme" do
      assert %URI{} = Ezagent.URI.new!("entity://system/user/admin")
    end

    test "rejects an unregistered scheme with clear error" do
      scheme = "neverregistered-#{System.unique_integer([:positive])}"

      assert_raise ArgumentError, ~r/not registered/, fn ->
        Ezagent.URI.new!("#{scheme}://x/y")
      end
    end

    test "newly-registered scheme is then accepted by parse!" do
      scheme = "newreg-#{System.unique_integer([:positive])}"
      :ok = SchemeRegistry.register(scheme)
      assert %URI{} = Ezagent.URI.new!("#{scheme}://default/x")
    end
  end

  describe "SpawnRegistry.register/2 co-registers scheme" do
    test "registering a scheme spawn fn also adds the scheme to the allowlist" do
      scheme = "spawncoreg-#{System.unique_integer([:positive])}"
      refute SchemeRegistry.registered?(scheme)

      :ok = Ezagent.SpawnRegistry.register(scheme, fn _uri -> {:ok, self()} end)

      assert SchemeRegistry.registered?(scheme)
    end
  end

  describe "lockdown — deleted schemes" do
    test "user:// (deleted in PR #141) is NOT registered" do
      refute SchemeRegistry.registered?("user"), "PR #141 deleted user:// — should be gone"
    end

    test "agent:// (deleted in PR #141) is NOT registered" do
      refute SchemeRegistry.registered?("agent")
    end

    test "feishu:// (deleted in PR #143) is NOT registered" do
      refute SchemeRegistry.registered?("feishu")
    end

    test "routing-admin:// (dissolved in PR #144) is NOT registered" do
      refute SchemeRegistry.registered?("routing-admin")
    end

    test "pty-input:// (dissolved in PR #144) is NOT registered" do
      refute SchemeRegistry.registered?("pty-input")
    end

    test "message:// (deleted in PR #147) is NOT registered" do
      refute SchemeRegistry.registered?("message")
    end
  end
end
