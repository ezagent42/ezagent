defmodule Ezagent.Kind.TemplateProvisionTest do
  @moduledoc """
  PR-3 — `Ezagent.Kind.Template.provision_and_instantiate/4` is the single
  contract-boundary chokepoint (every `instantiate/3` caller routes through it):
  it allocates the per-agent config_dir TARGET (when the template carries a
  `config_dir` reference), injects it as `"allocated_config_dir"` data, then
  delegates to the plugin's `instantiate/3`. Location-as-data ⇒ the plugin never
  computes the path (North-Star isolation).
  """
  use ExUnit.Case, async: false

  # The flavor-attribute cleanup assertion crosses into domain_agent; standalone
  # ezagent_core does not own that registry anymore.
  @moduletag :umbrella_only

  alias Ezagent.Kind.Template
  alias Ezagent.Sandbox.ConfigDir

  defmodule FakeClass do
    def template_name, do: "cc.agent"
    def config_dir_namespace, do: "cc"
    # echoes the data it received so the test can assert on the injected key
    def instantiate(_name, data, _ws), do: {:ok, [data["agent_uri"]], %{received: data}}
  end

  defmodule FakeKind do
  end

  defmodule FailingClass do
    def template_name, do: "failing.agent"
    def instantiate(_name, _data, _ws), do: {:error, :boom}
  end

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "ezagent-provision-test-#{System.unique_integer([:positive])}")

    prev = System.get_env("EZAGENT_HOME")
    System.put_env("EZAGENT_HOME", tmp)

    on_exit(fn ->
      if prev, do: System.put_env("EZAGENT_HOME", prev), else: System.delete_env("EZAGENT_HOME")
      File.rm_rf(tmp)
    end)

    :ok
  end

  defp ws, do: Ezagent.URI.new!("entity://workspace/system/myws")

  test "allocates + injects allocated_config_dir when a config_dir reference is present, then delegates" do
    uri_str = "entity://myws/agent/cc_foo"
    data = %{"agent_uri" => uri_str, "config_dir" => "/some/reference/dir", "cwd" => "/tmp"}

    assert {:ok, [^uri_str], %{received: received}} =
             Template.provision_and_instantiate(FakeClass, "cc.agent", data, ws())

    expected = ConfigDir.path(Ezagent.URI.new!(uri_str), "cc")
    assert received["allocated_config_dir"] == expected
    # the wrapper actually created the dir (allocation, not just path computation)
    assert File.dir?(expected)
  end

  test "no config_dir reference → no allocation, no injected key (curl/echo footprint-free)" do
    data = %{"agent_uri" => "entity://myws/agent/curl_bar", "cwd" => "/tmp"}

    assert {:ok, _uris, %{received: received}} =
             Template.provision_and_instantiate(FakeClass, "cc.agent", data, ws())

    refute Map.has_key?(received, "allocated_config_dir")
  end

  # #201 PR-2 — the pre-instantiate speculative flavor store (and its hook
  # machinery) was DELETED. The only flavor write is the spawn winner's
  # post-ownership store in TemplateSpawn; instantiate-time flavor reads come
  # from the data map. These tests pin the absence of the old write.
  test "no speculative flavor store on the success path" do
    uri = Ezagent.URI.new!("entity://myws/agent/cc_nostore")
    :ok = Ezagent.AgentFlavorAttributes.delete(uri)

    data = %{"agent_uri" => URI.to_string(uri), "cwd" => "/tmp"}

    assert {:ok, _uris, _meta} =
             Template.provision_and_instantiate(FakeClass, "cc.agent", data, ws())

    assert :none = Ezagent.AgentFlavorAttributes.get(uri)
  end

  test "a config_dir reference without an agent_uri fails loud (no silent skip)" do
    data = %{"config_dir" => "/some/reference/dir", "cwd" => "/tmp"}

    assert {:error, :config_dir_allocate_missing_agent_uri} =
             Template.provision_and_instantiate(FakeClass, "cc.agent", data, ws())
  end

  test "does not leave a flavor attribute when instantiate fails" do
    flavor = "failing-#{System.unique_integer([:positive])}"
    uri = Ezagent.URI.new!("entity://myws/agent/failing-one")

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: FakeKind,
        template_class: FailingClass
      })

    :ok = Ezagent.AgentFlavorAttributes.delete(uri)

    data = %{"agent_uri" => URI.to_string(uri), "cwd" => "/tmp"}

    assert {:error, :boom} =
             Template.provision_and_instantiate(FailingClass, "failing.agent", data, ws())

    assert :none = Ezagent.AgentFlavorAttributes.get(uri)
  end
end
