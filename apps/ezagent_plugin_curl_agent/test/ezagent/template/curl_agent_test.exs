defmodule Ezagent.PluginCurlAgent.TemplateTest do
  use ExUnit.Case, async: true

  alias Ezagent.PluginCurlAgent.Template

  test "instantiate/4 accepts only launch_context and instantiate/3 remains available" do
    assert function_exported?(Template, :instantiate, 3)
    assert function_exported?(Template, :instantiate, 4)

    assert {:error, :invalid_launch_options} =
             Template.instantiate("test", %{}, URI.new!("workspace://test"),
               launch_context_typo: make_ref()
             )
  end

  describe "validate/1 — PR #141 strict entity://team-alpha/agent/curl_<name> shape" do
    test "happy path" do
      assert :ok =
               Template.validate(%{
                 "class" => "curl.agent",
                 "agent_uri" => "entity://team-alpha/agent/curl_my-deepseek",
                 "provider" => "deepseek",
                 "api_url" => "https://api.deepseek.com/chat/completions",
                 "model" => "deepseek-chat"
               })
    end

    test "rejects wrong class" do
      assert {:error, {:wrong_class, "cc.pty"}} =
               Template.validate(%{
                 "class" => "cc.pty",
                 "agent_uri" => "entity://team-alpha/agent/curl_x",
                 "provider" => "deepseek",
                 "api_url" => "https://x.test/chat",
                 "model" => "x"
               })
    end

    test "accepts entity://agent/<name> without flavor prefix" do
      assert :ok =
               Template.validate(%{
                 "class" => "curl.agent",
                 "agent_uri" => "entity://team-alpha/agent/just-a-name",
                 "provider" => "deepseek",
                 "api_url" => "https://x.test/chat",
                 "model" => "x"
               })
    end

    test "rejects legacy curl-agent:// scheme (PR #141 clean rebuild)" do
      assert {:error, {:bad_agent_uri, _}} =
               Template.validate(%{
                 "class" => "curl.agent",
                 "agent_uri" => "curl-agent://legacy",
                 "provider" => "deepseek",
                 "api_url" => "https://x.test/chat",
                 "model" => "x"
               })
    end

    test "ignores legacy name prefix when validating stored flavor" do
      assert :ok =
               Template.validate(%{
                 "class" => "curl.agent",
                 "agent_uri" => "entity://team-alpha/agent/cc_wrong-flavor",
                 "provider" => "deepseek",
                 "api_url" => "https://x.test/chat",
                 "model" => "x"
               })
    end

    test "rejects non-http(s) api_url" do
      assert {:error, {:bad_api_url, "ftp://nope"}} =
               Template.validate(%{
                 "class" => "curl.agent",
                 "agent_uri" => "entity://team-alpha/agent/curl_x",
                 "provider" => "deepseek",
                 "api_url" => "ftp://nope",
                 "model" => "x"
               })
    end

    test "rejects missing model" do
      assert {:error, :missing_model} =
               Template.validate(%{
                 "class" => "curl.agent",
                 "agent_uri" => "entity://team-alpha/agent/curl_x",
                 "provider" => "deepseek",
                 "api_url" => "https://x.test/chat"
               })
    end
  end

  describe "form_fields/0 — auto-derived UI surface" do
    test "all required fields present + ordered for sensible left-to-right reading" do
      # Allen 2026-05-26 — `owner_uri` removed post ApiKeys-to-Agent flip.
      # Keys live on the agent itself.
      names = Template.form_fields() |> Enum.map(& &1.name)

      assert names == [
               "agent_uri",
               "provider",
               "api_url",
               "model",
               "system_prompt",
               "max_history"
             ]

      refute "owner_uri" in names,
             "owner_uri form field was removed by the ApiKeys-to-Agent flip"
    end

    test "required fields marked correctly" do
      required =
        Template.form_fields()
        |> Enum.filter(& &1.required)
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert required == ["agent_uri", "api_url", "model", "provider"]
    end
  end

  describe "template_name/0" do
    test "is curl.agent" do
      assert Template.template_name() == "curl.agent"
    end
  end

  describe "compile/2" do
    test "purely compiles resolved manifest instructions into curl template data" do
      resolved = %{
        instructions: "Acknowledge the customer briefly.",
        skills: ["triage"]
      }

      params = %{
        "provider" => "deepseek",
        "api_url" => "https://api.deepseek.com/chat/completions",
        "model" => "deepseek-chat",
        "max_history" => 4
      }

      assert {:ok, data} = Template.compile(resolved, params)

      assert data == %{
               "provider" => "deepseek",
               "api_url" => "https://api.deepseek.com/chat/completions",
               "model" => "deepseek-chat",
               "system_prompt" => "Acknowledge the customer briefly.",
               "max_history" => 4
             }
    end

    test "fails loud for non-optional manifest tools because curl has no MCP transport" do
      resolved = %{
        instructions: "Acknowledge the customer briefly.",
        tools: [
          %{
            name: "notify_owner",
            type: :action,
            action: "entity://system/user/admin?action=notifications.notify",
            caps: [%{"kind" => "user"}],
            optional: false
          }
        ]
      }

      params = %{
        "provider" => "deepseek",
        "api_url" => "https://api.deepseek.com/chat/completions",
        "model" => "deepseek-chat"
      }

      assert {:error, {:tools_unsupported, "curl", ["notify_owner"]}} =
               Template.compile(resolved, params)
    end
  end
end
