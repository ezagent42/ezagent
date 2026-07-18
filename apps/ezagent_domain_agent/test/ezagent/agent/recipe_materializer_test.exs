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

  setup do
    # UNIQUE per test (never the real "cc-custom"): at umbrella root plugin_cc
    # boots first and owns "cc-custom" → CcCustomAgent, and
    # `AgentFlavorRegistry.register/1` raises on a divergent re-registration.
    flavor = "cc-custom-fake-#{System.unique_integer([:positive])}"

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: FakeCcCustomTemplate,
        template_class: FakeCcCustomTemplate
      })

    # plugin_cc owns the "cc-agents" resource type at boot. At app scope it is
    # NOT started here — register the type test-only so `config_dir_ref/2`
    # resolves (and unregister on exit). At umbrella root plugin_cc IS started
    # and already owns the type: keep its registration and do NOT unregister it
    # on exit (that would strip the real type for later tests in the root VM).
    case Ezagent.Resource.FsResolver.register_type("cc-agents", %{
           backend_component: "cc-agents",
           authority: &Ezagent.Resource.FsResolver.config_dir_authority/2
         }) do
      :ok ->
        on_exit(fn -> Ezagent.Resource.FsResolver.unregister_type("cc-agents") end)

      {:error, {:already_registered, "cc-agents"}} ->
        :ok
    end

    %{flavor: flavor}
  end

  defp recipe, do: %{name: "orchestrator"}

  defp opts(flavor, extra) do
    Map.merge(
      %{
        flavor: flavor,
        role_name: "orchestrator",
        agent_uri: Ezagent.URI.new!("entity://team-alpha/agent/cc_x")
      },
      Map.new(extra)
    )
  end

  describe "template_content/2 provider threading" do
    test "threads opts[:provider] into content", %{flavor: flavor} do
      {:ok, content} =
        RecipeMaterializer.template_content(recipe(), opts(flavor, provider: "deepseek"))

      assert content[:provider] == "deepseek" or content["provider"] == "deepseek"
    end

    test "absent provider leaves the key OUT (plain-cc / legacy byte-unchanged)", %{
      flavor: flavor
    } do
      {:ok, content} = RecipeMaterializer.template_content(recipe(), opts(flavor, []))

      refute Map.has_key?(content, :provider)
      refute Map.has_key?(content, "provider")
    end

    test "a nil provider is treated as absent (never written into content)", %{flavor: flavor} do
      {:ok, content} =
        RecipeMaterializer.template_content(recipe(), opts(flavor, provider: nil))

      refute Map.has_key?(content, :provider)
      refute Map.has_key?(content, "provider")
    end
  end
end
