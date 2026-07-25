defmodule EzagentWeb.HelloManifestDriftTest do
  use ExUnit.Case, async: true

  alias Ezagent.Socialware.{Demo, ManifestYaml}

  @reference %{
    "name" => "hello",
    "version" => "0.1.0",
    "title" => "Hello website builder",
    "description" => "Build and publish a website through a seven-role Hello team.",
    "uses" => ["hello"],
    "bases" => [Ezagent.ActionSet.Session, Ezagent.ActionSet.Publisher.SessionImpl],
    "shape" => [Ezagent.ActionSet.Turn, Ezagent.ActionSet.Surface],
    "views" => ["hello_render"],
    "roles" => [
      %{
        "role_name" => "front-desk",
        "fill" => "agent",
        "recipe" => "hello.front-desk",
        "flavor" => "hello"
      },
      %{
        "role_name" => "builder",
        "fill" => "agent",
        "recipe" => "hello.builder",
        "flavor" => "native"
      },
      %{
        "role_name" => "concierge",
        "fill" => "agent",
        "recipe" => "hello.concierge",
        "flavor" => "native"
      },
      %{"role_name" => "llm", "fill" => "agent", "recipe" => "hello.llm", "flavor" => "curl"},
      %{
        "role_name" => "sharer",
        "fill" => "agent",
        "recipe" => "hello.sharer",
        "flavor" => "native"
      },
      %{
        "role_name" => "publisher",
        "fill" => "agent",
        "recipe" => "hello.publisher",
        "flavor" => "native"
      },
      %{
        "role_name" => "dispatcher",
        "fill" => "agent",
        "recipe" => "hello.dispatcher",
        "flavor" => "native"
      }
    ],
    "routing_rules" => [
      %{
        "matcher" => %{"type" => "always"},
        "receivers" => ["front-desk"],
        "rule_set" => "default",
        "position" => 0
      }
    ],
    "visibility_policy" => %{
      "scope" => "public",
      "publish_policy" => "auto",
      "web_anon_access" => true
    },
    "prompt_templates" => %{},
    "legends" => %{}
  }

  test "the shipped hello manifest exists in the deploy-seed lane" do
    path = Demo.Hello.manifest_path()
    assert is_binary(path)
    assert File.exists?(path)
  end

  test "the shipped manifest is the seven-role curl-only Hello definition" do
    assert {:ok, parsed} = ManifestYaml.parse(File.read!(Demo.Hello.manifest_path()))
    assert parsed == @reference
    assert Enum.count(parsed["roles"], &(&1["flavor"] == "curl")) == 1
    assert Enum.find(parsed["roles"], &(&1["role_name"] == "llm"))["flavor"] == "curl"
  end

  test "Demo.Hello loads the shipped manifest and supports only a name override" do
    assert Demo.Hello.manifest_attrs() == @reference
    renamed = Demo.Hello.manifest_attrs(name: "hello-run-1")
    assert Map.put(renamed, "name", "hello") == @reference
  end
end
