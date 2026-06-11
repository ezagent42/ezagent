defmodule EzagentPluginContent.Soul.SoulStoreTest do
  use ExUnit.Case
  alias EzagentPluginContent.Soul.SoulStore

  @test_tid "test-tenant"
  @test_role "customer"
  @tmp_dir Path.join(System.tmp_dir!(), "soul_store_test_#{System.unique_integer()}")

  setup do
    sandbox = Path.join(@tmp_dir, "sandbox/slots")
    release = Path.join(@tmp_dir, "release/v1/slots")
    File.mkdir_p!(sandbox)
    File.mkdir_p!(release)
    # ln -sf release/v1 release/_current
    current = Path.join(@tmp_dir, "release/_current")
    File.rm_rf!(current)
    File.ln_s(Path.join(@tmp_dir, "release/v1"), current)
    # Override base path for tests
    {:ok, sandbox: sandbox, release: release}
  end

  test "write_slots and read_slots sandbox" do
    values = %{"identity" => %{"bot_full_name" => "TestBot"}}
    :ok = SoulStore.write_slots(@tmp_dir, @test_tid, @test_role, values, :sandbox)

    {:ok, read} = SoulStore.read_slots(@tmp_dir, @test_tid, @test_role, :sandbox)
    assert get_in(read, ["identity", "bot_full_name"]) == "TestBot"
  end

  test "write_slots merge — preserves existing keys" do
    SoulStore.write_slots(@tmp_dir, @test_tid, @test_role, %{"a" => %{"k1" => "v1"}}, :sandbox)
    SoulStore.write_slots(@tmp_dir, @test_tid, @test_role, %{"a" => %{"k2" => "v2"}}, :sandbox)
    {:ok, read} = SoulStore.read_slots(@tmp_dir, @test_tid, @test_role, :sandbox)
    assert get_in(read, ["a", "k1"]) == "v1"
    assert get_in(read, ["a", "k2"]) == "v2"
  end

  test "read_slots sandbox vs release" do
    SoulStore.write_slots(@tmp_dir, @test_tid, @test_role, %{"v" => "sandbox"}, :sandbox)
    SoulStore.write_slots(@tmp_dir, @test_tid, @test_role, %{"v" => "release"}, :release)
    {:ok, sb} = SoulStore.read_slots(@tmp_dir, @test_tid, @test_role, :sandbox)
    {:ok, rel} = SoulStore.read_slots(@tmp_dir, @test_tid, @test_role, :release)
    assert sb["v"] == "sandbox"
    assert rel["v"] == "release"
  end
end
