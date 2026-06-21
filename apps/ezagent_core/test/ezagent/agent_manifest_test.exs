defmodule Ezagent.AgentManifestTest do
  use ExUnit.Case, async: true

  alias Ezagent.AgentManifest

  describe "load/1" do
    test "loads a valid map manifest with canonical executor flavor strings" do
      input = %{
        "name" => "doorman",
        "soul" => "soul.md",
        "skills" => ["greeting"],
        "tools" => [],
        "caps" => [],
        "lifecycle" => "persistent",
        "executor" => %{"flavor" => ["cc", :codex], "params" => %{"model" => "opus"}}
      }

      assert {:ok, manifest} = AgentManifest.load(input)
      assert manifest.name == "doorman"
      assert manifest.soul == "soul.md"
      assert manifest.skills == ["greeting"]
      assert manifest.lifecycle == :persistent
      assert manifest.executor.flavor == ["cc", "codex"]
      assert manifest.executor.params == %{"model" => "opus"}
      assert manifest.executor.on_exhausted == :notify_orchestrator
    end

    test "loads YAML manifests" do
      yaml = """
      name: fast
      soul: soul.md
      skills: []
      tools: []
      caps: []
      lifecycle: persistent
      executor:
        flavor: curl
        params:
          provider: deepseek
          model: deepseek-chat
      """

      assert {:ok, manifest} = AgentManifest.load(yaml)
      assert manifest.name == "fast"
      assert manifest.executor.flavor == ["curl"]
      assert manifest.executor.params == %{"provider" => "deepseek", "model" => "deepseek-chat"}
    end

    test "rejects flavor in author fields" do
      input = %{
        name: "bad",
        soul: "soul.md",
        skills: [],
        tools: [],
        caps: [],
        lifecycle: :persistent,
        flavor: "cc",
        executor: %{flavor: ["cc"], params: %{}}
      }

      assert {:error, {:author_field_forbidden, :flavor}} = AgentManifest.load(input)
    end

    test "rejects empty executor flavor list" do
      input = %{
        name: "bad",
        soul: "soul.md",
        skills: [],
        tools: [],
        caps: [],
        lifecycle: :persistent,
        executor: %{flavor: [], params: %{}}
      }

      assert {:error, :empty_executor_flavor} = AgentManifest.load(input)
    end
  end

  describe "render/2" do
    test "substitutes slot values in a soul template" do
      soul = "You sell {{brand_name}} with a {{tone}} tone. {{brand_name}} matters."
      slots = %{"brand_name" => "Acme", tone: "warm"}

      assert {:ok, rendered} = AgentManifest.render(soul, slots)
      assert rendered == "You sell Acme with a warm tone. Acme matters."
    end

    test "fails loud when a slot is missing" do
      assert {:error, {:missing_slot, "brand_name"}} =
               AgentManifest.render("You sell {{brand_name}}.", %{})
    end

    test "fails loud when a slot value is not renderable" do
      assert {:error, {:invalid_slot_value, "brand_name", %{}}} =
               AgentManifest.render("You sell {{brand_name}}.", %{"brand_name" => %{}})
    end
  end

  describe "to_template_content/4" do
    test "builds transient AgentTemplate content for a flavor candidate" do
      assert {:ok, manifest} =
               AgentManifest.load(%{
                 name: "fast",
                 soul: "Hello {{brand_name}}.",
                 skills: ["kb_search"],
                 caps: [%{"kind" => "chat"}],
                 executor: %{
                   flavor: ["curl"],
                   params: %{
                     "project_cwd" => "/tmp/project",
                     "provider" => "deepseek",
                     "api_url" => "https://api.deepseek.com/chat/completions",
                     "model" => "deepseek-chat"
                   }
                 }
               })

      assert {:ok, content} =
               AgentManifest.to_template_content(manifest, "curl", %{"brand_name" => "CINNOX"})

      assert content.flavor == "curl"
      assert content.project_cwd == "/tmp/project"
      assert content.desired_skills == ["kb_search"]
      assert content.desired_caps == [%{"kind" => "chat"}]
      assert content.agent_manifest_resolved.instructions == "Hello CINNOX."
      assert content.agent_manifest_params["provider"] == "deepseek"
      refute Map.has_key?(content, :derived_config)
    end
  end
end
