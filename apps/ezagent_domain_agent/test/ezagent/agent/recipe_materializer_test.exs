defmodule Ezagent.Agent.RecipeMaterializerTest do
  @moduledoc """
  `RecipeMaterializer.template_content/2` content assembly — the recipe stays
  flavor-free; the materializer folds flavor + role into AgentTemplate content.

  Pins the cc-custom backend-profile seam: an optional `provider` opt (the
  role slot's selected backend profile) threads into content, where the
  flavor's `template_data_extra/1` content seam picks it up. Absent `provider`
  leaves the key OUT (plain-cc / legacy recipes byte-unchanged).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.FakeCcCustomTemplate
  alias Ezagent.Agent.RecipeMaterializer

  @flavor "cc-custom"

  setup do
    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: @flavor,
        kind: FakeCcCustomTemplate,
        template_class: FakeCcCustomTemplate
      })

    # plugin_cc owns the "cc-agents" resource type at boot and is NOT started
    # here — register it test-only so `config_dir_ref/2` resolves.
    :ok =
      Ezagent.Resource.FsResolver.register_type("cc-agents", %{
        backend_component: "cc-agents",
        authority: &Ezagent.Resource.FsResolver.config_dir_authority/2
      })

    on_exit(fn -> Ezagent.Resource.FsResolver.unregister_type("cc-agents") end)

    :ok
  end

  defp recipe, do: %{name: "orchestrator"}

  defp opts(extra) do
    Map.merge(
      %{
        flavor: @flavor,
        role_name: "orchestrator",
        agent_uri: Ezagent.URI.new!("entity://team-alpha/agent/cc_x")
      },
      Map.new(extra)
    )
  end

  describe "template_content/2 provider threading" do
    test "threads opts[:provider] into content" do
      {:ok, content} = RecipeMaterializer.template_content(recipe(), opts(provider: "deepseek"))

      assert content[:provider] == "deepseek" or content["provider"] == "deepseek"
    end

    test "absent provider leaves the key OUT (plain-cc / legacy byte-unchanged)" do
      {:ok, content} = RecipeMaterializer.template_content(recipe(), opts([]))

      refute Map.has_key?(content, :provider)
      refute Map.has_key?(content, "provider")
    end

    test "a nil provider is treated as absent (never written into content)" do
      {:ok, content} = RecipeMaterializer.template_content(recipe(), opts(provider: nil))

      refute Map.has_key?(content, :provider)
      refute Map.has_key?(content, "provider")
    end
  end
end
