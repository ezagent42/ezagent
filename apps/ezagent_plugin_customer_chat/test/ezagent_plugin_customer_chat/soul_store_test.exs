defmodule EzagentPluginCustomerChat.SoulStoreTest do
  # async: false — mutates global Application env (the two soul roots).
  use ExUnit.Case, async: false
  alias EzagentPluginCustomerChat.SoulStore

  setup do
    base = Path.join(System.tmp_dir!(), "soulstore_#{System.unique_integer([:positive])}")
    sandbox = Path.join(base, "sandbox")
    fixtures = Path.join(base, "fixtures")
    File.mkdir_p!(sandbox)
    File.mkdir_p!(fixtures)
    Application.put_env(:ezagent_plugin_customer_chat, :customer_chat_sandbox_root, sandbox)
    Application.put_env(:ezagent_plugin_customer_chat, :customer_chat_soul_root, fixtures)

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_customer_chat, :customer_chat_sandbox_root)
      Application.delete_env(:ezagent_plugin_customer_chat, :customer_chat_soul_root)
      File.rm_rf!(base)
    end)

    %{fixtures: fixtures}
  end

  defp write_fixture(fixtures, tenant, body) do
    p = Path.join([fixtures, tenant, "souls", "customer.md"])
    File.mkdir_p!(Path.dirname(p))
    File.write!(p, body)
  end

  test "effective_path falls back to fixture when no edited file", %{fixtures: f} do
    write_fixture(f, "acme", "FIXTURE")

    assert SoulStore.effective_path("acme", "customer") ==
             SoulStore.fixture_path("acme", "customer")

    assert {:ok, "FIXTURE", :fixture} = SoulStore.read_effective("acme", "customer")
  end

  test "effective_path prefers the edited file", %{fixtures: f} do
    write_fixture(f, "acme", "FIXTURE")
    :ok = SoulStore.write("acme", "customer", "EDITED")

    assert SoulStore.effective_path("acme", "customer") ==
             SoulStore.edited_path("acme", "customer")

    assert {:ok, "EDITED", :edited} = SoulStore.read_effective("acme", "customer")
  end

  test "effective_path is nil when neither edited nor fixture exists" do
    assert SoulStore.effective_path("ghost", "customer") == nil
    assert {:ok, "", :none} = SoulStore.read_effective("ghost", "customer")
  end

  test "write snapshots the prior edited file; revert_previous restores it", %{fixtures: f} do
    write_fixture(f, "acme", "FIXTURE")
    :ok = SoulStore.write("acme", "customer", "V1")
    refute SoulStore.has_previous?("acme", "customer")
    :ok = SoulStore.write("acme", "customer", "V2")
    assert SoulStore.has_previous?("acme", "customer")
    assert {:ok, "V2", :edited} = SoulStore.read_effective("acme", "customer")
    assert :ok = SoulStore.revert_previous("acme", "customer")
    assert {:ok, "V1", :edited} = SoulStore.read_effective("acme", "customer")
  end

  test "revert_previous errors with no snapshot" do
    assert {:error, :no_previous} = SoulStore.revert_previous("acme", "customer")
  end

  test "reset deletes edited + prev, falling back to fixture", %{fixtures: f} do
    write_fixture(f, "acme", "FIXTURE")
    :ok = SoulStore.write("acme", "customer", "V1")
    :ok = SoulStore.write("acme", "customer", "V2")
    assert :ok = SoulStore.reset("acme", "customer")
    refute SoulStore.edited?("acme", "customer")
    refute SoulStore.has_previous?("acme", "customer")
    assert {:ok, "FIXTURE", :fixture} = SoulStore.read_effective("acme", "customer")
  end
end
