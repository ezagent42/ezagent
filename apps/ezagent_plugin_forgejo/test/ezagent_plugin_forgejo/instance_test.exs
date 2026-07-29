defmodule EzagentPluginForgejo.InstanceTest do
  use ExUnit.Case, async: true

  alias EzagentPluginForgejo.Instance

  describe "api_base/1" do
    test "builds the v1 API base from a bare provider host" do
      assert {:ok, "https://code.hyprial.com/api/v1"} = Instance.api_base("code.hyprial.com")
    end

    test "accepts a host carrying an explicit port" do
      assert {:ok, "https://git.internal:3000/api/v1"} = Instance.api_base("git.internal:3000")
    end

    # A malformed provider_host must not silently build a URL pointing somewhere
    # else -- this function decides which host a Forgejo PAT is sent to.
    test "rejects an empty host" do
      assert {:error, :invalid_provider_host} = Instance.api_base("")
    end

    test "rejects a host that already carries a scheme" do
      assert {:error, :invalid_provider_host} = Instance.api_base("https://code.hyprial.com")
    end

    test "rejects a host that carries a path segment" do
      assert {:error, :invalid_provider_host} = Instance.api_base("code.hyprial.com/evil")
    end

    test "rejects a host carrying userinfo" do
      assert {:error, :invalid_provider_host} = Instance.api_base("user@evil.example")
    end

    test "rejects a non-binary host" do
      assert {:error, :invalid_provider_host} = Instance.api_base(nil)
    end
  end
end
