defmodule Ezagent.World.ResourceTypeSlugPrefixTest do
  @moduledoc """
  Non-vacuous slug-prefix lint (codex HIGH-6 / D7) exercised in a suite where the
  world plugin IS loaded.

  PR-1's core-suite enumeration of `Application.loaded_applications()` is VACUOUS
  there — standalone `ezagent_core` loads no `ezagent_plugin_*` app, so its
  comprehension is empty and the assertion holds with zero subjects. This suite
  runs with the world plugin booted, so it actually checks `world-layouts`.
  """
  use ExUnit.Case, async: true

  # D7 exemption set — core's bare names (claimed at Registry.init/1) are NOT
  # plugin-contributed and keep their bare names by design.
  @core_bare_types ["cc-agents", "codex-agents", "uploads"]

  test "the world plugin's resource_types/0 are slug-prefixed with its slug" do
    slug = EzagentPluginWorld.Application.plugin_info().slug
    types = for {type, _spec} <- EzagentPluginWorld.Application.resource_types(), do: type

    # Must be non-empty here, else the lint is vacuous (the PR-1 core defect).
    assert types != [], "world plugin declares no resource_types/0 — lint would be vacuous"

    offenders =
      for type <- types,
          type not in @core_bare_types,
          not String.starts_with?(type, slug <> "-"),
          do: type

    assert offenders == [],
           "plugin-contributed resource <type>s must be slug-prefixed (D7): #{inspect(offenders)}"

    assert "world-layouts" in types
  end
end
