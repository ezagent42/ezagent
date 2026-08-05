defmodule EzagentWeb.HelloManifestDriftTest do
  use ExUnit.Case, async: true

  alias Ezagent.Socialware.{Demo, ManifestYaml}

  @reference %{
    "name" => "hello",
    "version" => "0.1.0",
    "title" => "Hello website builder",
    "description" => "Build and publish a website with a reusable LLM agent.",
    "uses" => ["hello"],
    "bases" => [Ezagent.ActionSet.Session, Ezagent.ActionSet.Publisher.SessionImpl],
    "shape" => [
      Ezagent.ActionSet.Turn,
      Ezagent.ActionSet.Surface,
      Ezagent.ActionSet.HelloSessionActions
    ],
    "views" => ["hello_render"],
    "roles" => [
      %{
        "role_name" => "llm",
        "fill" => "agent",
        "recipe" => "hello.llm",
        "flavor" => "curl",
        "credential_admission" => "before_session_join",
        "config" => %{
          "provider" => "deepseek",
          "api_url" => "https://api.deepseek.com/chat/completions",
          "model" => "deepseek-v4-flash"
        }
      }
    ],
    "routing_rules" => [],
    "visibility_policy" => %{
      "scope" => "public",
      "publish_policy" => "auto",
      "web_anon_access" => true
    },
    "prompt_templates" => %{},
    "legends" => %{},
    "ingress" => %{
      "behavior" => "Ezagent.ActionSet.HelloSessionActions",
      "action" => "route_inbound",
      "protected_roles" => ["llm"]
    }
  }

  test "the shipped hello manifest exists in the deploy-seed lane" do
    path = Demo.Hello.manifest_path()
    assert is_binary(path)
    assert File.exists?(path)
  end

  test "the shipped manifest declares Session ingress and only a gated LLM role" do
    assert {:ok, parsed} = ManifestYaml.parse(File.read!(Demo.Hello.manifest_path()))
    assert parsed == @reference
    assert Enum.count(parsed["roles"], &(&1["flavor"] == "curl")) == 1

    assert %{
             "flavor" => "curl",
             "credential_admission" => "before_session_join"
           } = Enum.find(parsed["roles"], &(&1["role_name"] == "llm"))

    assert Enum.map(parsed["roles"], & &1["role_name"]) == ["llm"]
    assert parsed["routing_rules"] == []

    assert parsed["ingress"] == %{
             "behavior" => "Ezagent.ActionSet.HelloSessionActions",
             "action" => "route_inbound",
             "protected_roles" => ["llm"]
           }
  end

  test "Demo.Hello loads the shipped manifest and supports only a name override" do
    assert Demo.Hello.manifest_attrs() == @reference
    renamed = Demo.Hello.manifest_attrs(name: "hello-run-1")
    assert Map.put(renamed, "name", "hello") == @reference
  end
end
