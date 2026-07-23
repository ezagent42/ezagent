defmodule EzagentPluginGithub.DeclarativeRegistrationTest do
  @moduledoc """
  Regression for the plugin-authoring contract (SPEC §3.2 / `:ezagent_plugin_check`):
  the GitHub plugin registers its DomainGit adapter DECLARATIVELY, via the
  `Ezagent.DomainGit.AdapterDeclarationOwner` it lists in `children/0`, WITHOUT
  calling `AdapterRegistry.register` from its own source.

  Guards two failure modes seen while fixing this:
    1. a plugin calling `*Registry.register` directly reddens the mac full-suite
       plugin-check gate (the reason this owner exists);
    2. registering the adapter from domain_git's config-driven BootRegistration
       fails `{:invalid_adapter_module, _}` because the registry validates
       `:code.is_loaded/1` and domain_git boots before the plugin — so the owner
       MUST run in the plugin lifecycle (this test starts it that way).
  """
  use ExUnit.Case, async: false

  alias Ezagent.DomainGit.AdapterRegistry

  test "AdapterDeclarationOwner (as declared in children/0) registers the github git adapter" do
    start_supervised!(
      {Ezagent.DomainGit.AdapterDeclarationOwner,
       owner: :github_declarative_registration_test,
       adapters: [{"github", EzagentPluginGithub.GitHubAdapter}]}
    )

    assert {:ok, EzagentPluginGithub.GitHubAdapter} =
             AdapterRegistry.lookup_for_action_set("github")
  end

  test "the plugin source contains NO direct *Registry.register / declare_table call (SPEC §3.2 grep gate)" do
    # Mirrors the `:ezagent_plugin_check` compiler grep so a re-introduced direct
    # registry call fails a fast unit test, not only the mac-only full-suite.
    pattern =
      ~r/\b(?:Ezagent\.)?(?:ExternalMirror\.)?(?:Adapter|Binding|Behavior|Spawn|Template|Plugin|AgentFlavor|Routing)Registry\.(?:register|register_module|declare_table)\b/

    lib_root = Path.join([__DIR__, "..", "..", "lib"]) |> Path.expand()

    offenders =
      Path.wildcard(Path.join(lib_root, "**/*.ex"))
      |> Enum.reject(&String.contains?(&1, "/mix/tasks/"))
      |> Enum.filter(fn file ->
        case File.read(file) do
          {:ok, content} -> Regex.match?(pattern, content)
          _ -> false
        end
      end)

    assert offenders == [],
           "plugin source must not call a *Registry API directly (SPEC §3.2); offenders: #{inspect(offenders)}"
  end
end
