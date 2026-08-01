defmodule Ezagent.Invariants.CleanSlateGrantProtocolTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @self "apps/ezagent_core/test/invariants/clean_slate_grant_protocol_test.exs"

  @forbidden [
    "signing_version",
    "RevocationEpoch",
    "CapRevocationEpoch",
    "cap_revocation_epoch",
    "CapRevocationCutover",
    "cap_revocation_cutover",
    "Identity.Cutover",
    "identity_cutover_active_override",
    "IdentityCaps.UserStore"
  ]

  @historical_exceptions [
    "apps/ezagent_core/priv/repo/migrations/20260520000000_phase4_users.exs",
    "apps/ezagent_core/priv/repo/migrations/20260601000000_phase9_pr6_workspace_uri_columns.exs",
    "apps/ezagent_core/priv/repo_pg/migrations/20260728120000_create_identity_caps.exs",
    "apps/ezagent_core/priv/repo_pg/migrations/20260729130000_create_identity_cutover.exs",
    "apps/ezagent_core/priv/repo_pg/migrations/20260801000300_remove_identity_cap_compatibility.exs"
  ]

  test "runtime source contains no protocol-version or cutover compatibility plane" do
    violations =
      source_files()
      |> Enum.reject(&exception?/1)
      |> Enum.flat_map(&violations/1)

    assert violations == [],
           "clean-slate grant protocol violations:\n" <>
             Enum.map_join(violations, "\n", fn {file, identifier} ->
               "  #{file}: #{identifier}"
             end)
  end

  defp source_files do
    [
      Path.join(@root, "apps/**/*.{ex,exs}"),
      Path.join(@root, "config/*.{ex,exs}"),
      Path.join(@root, "mix.exs")
    ]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
  end

  defp exception?(absolute_path) do
    relative = Path.relative_to(absolute_path, @root)
    relative == @self or relative in @historical_exceptions
  end

  defp violations(absolute_path) do
    source = File.read!(absolute_path)
    relative = Path.relative_to(absolute_path, @root)

    for identifier <- @forbidden,
        String.contains?(source, identifier),
        do: {relative, identifier}
  end
end
