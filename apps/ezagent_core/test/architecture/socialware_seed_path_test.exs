Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.SocialwareSeedPathTest do
  @moduledoc """
  Socialware deploy-seed gate (2026-07-07, deploy-seed SPEC §5).

  Non-framework socialware must live at the canonical deployment directory
  (`$EZAGENT_HOME/<profile>/socialware/`), seeded from
  `ezagent_web/priv/socialware_seed/<name>/` via `Ezagent.Home.SocialwareSeed`.
  Two shapes are forbidden:

    * `socialware_priv_manifest_files` — the DEPRECATED plugin/domain-priv
      `priv/socialware/<name>/manifest.yaml` authoring lane (TARGET-ZERO);
    * `socialware_self_publish_unsanctioned` — the `Demo.publish`
      self-publish-at-boot shape, i.e. any `publish_or_upgrade(` call outside the
      framework import lane (`manifest_yaml.ex`). RATCHET — burns down to 0 as
      each plugin (hello/kanban/dealscout) migrates onto the deploy-seed lane.
  """
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  alias Mix.Tasks.Ezagent.Arch.Scan

  test "no manifest under the deprecated priv/socialware authoring lane" do
    assert_zero(:socialware_priv_manifest_files)
  end

  test "no unsanctioned socialware self-publish beyond the ratchet" do
    assert_at_or_below(:socialware_self_publish_unsanctioned)
  end

  describe "self-publish fixtures" do
    test "POSITIVE: a parenthesized publish_or_upgrade call is flagged" do
      source = """
      defmodule Demo.Kanban do
        alias Ezagent.ConfigGovernance.Socialware, as: Governance

        def publish(definition, ctx) do
          Governance.publish_or_upgrade(definition, ctx)
        end
      end
      """

      assert Scan.count_socialware_self_publish_in_source(source) == 1
    end

    test "NEGATIVE: a function capture, @spec, and def head are not calls" do
      source = """
      defmodule Ezagent.ConfigGovernance.Socialware do
        @spec publish_or_upgrade(map(), map()) :: {:ok, atom()}
        def publish_or_upgrade(definition_or_attrs, ctx) do
          {:ok, :published}
        end

        def hook, do: &__MODULE__.publish_or_upgrade/2
      end
      """

      assert Scan.count_socialware_self_publish_in_source(source) == 0
    end

    test "`# arch-allow:` suppresses a justified call site" do
      source = """
      defmodule Demo.Legacy do
        alias Ezagent.ConfigGovernance.Socialware, as: Governance

        def publish(definition, ctx) do
          Governance.publish_or_upgrade(definition, ctx) # arch-allow: fixture
        end
      end
      """

      assert Scan.count_socialware_self_publish_in_source(source) == 0
    end
  end
end
