defmodule EzagentCore.F5RegistryAuthorityUseClassificationTest do
  use ExUnit.Case, async: true

  test "CapabilityRegistry bare matches are explicitly limited to grant-side delegation" do
    source =
      File.read!(Path.expand("../../lib/ezagent/capability_registry.ex", __DIR__))

    markers = Regex.scan(~r/F-5 REVIEWED EXEMPTION: GRANT-side/, source)

    assert length(markers) == 2,
           "each Capability.matches?/2 site in CapabilityRegistry must be classified as grant-side"

    assert source =~ "def authorize_grant("
    refute source =~ "def authorize_access("
  end
end
