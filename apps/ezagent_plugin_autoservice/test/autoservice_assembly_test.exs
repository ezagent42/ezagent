defmodule EzagentPluginAutoservice.AutoserviceAssemblyTest do
  use ExUnit.Case

  alias EzagentPluginAutoservice.AutoserviceAssembly

  describe "provision_agent/2" do
    test "returns work_dir and agent configs" do
      result = AutoserviceAssembly.provision_agent("test-tid", "slow")
      assert {:ok, %{work_dir: work_dir, fast_cfg: fast_cfg, slow_cfg: slow_cfg}} = result
      assert is_binary(work_dir)
      assert is_map(fast_cfg)
      assert is_map(slow_cfg)
    end
  end

  describe "preview_provision/3" do
    test "returns session_uri and work_dir for sandbox data" do
      admin_uri = Ezagent.URI.new!("entity://user/test/padmin")
      result = AutoserviceAssembly.preview_provision("test-tid", "slow", admin_uri)
      assert {:ok, %{session_uri: session_uri, work_dir: work_dir}} = result
      assert %URI{scheme: "session"} = session_uri
      assert is_binary(work_dir)
    end
  end

  describe "write_slot/5" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
      tid = "test-slot-#{System.unique_integer([:positive])}"
      {:ok, tid: tid}
    end

    test "writes slot value and ensures active CR", %{tid: tid} do
      result =
        AutoserviceAssembly.write_slot(tid, "slow", "greeting", "welcome_msg", "Hello")

      assert result == :ok
    end
  end
end
