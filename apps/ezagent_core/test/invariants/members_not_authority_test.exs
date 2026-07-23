defmodule EzagentCore.Invariants.MembersNotAuthorityTest do
  @moduledoc "M-9: session roster reads are projection mechanics, never authorization."

  use ExUnit.Case, async: true

  alias EzagentCore.Invariants.MembersNotAuthorityProbes, as: Probes

  test "no unreviewed members projection read can become an authority decision" do
    offenders = scan_tree()

    assert offenders == [],
           """
           members_not_authority — unreviewed session/workspace roster reads remain.
           Every hit must either be removed from authorization or entered in the
           narrow probe allowlist with a reviewed projection/delivery reason:

           #{Enum.join(offenders, "\n")}
           """
  end

  test "detector flags a synthetic roster authorization predicate" do
    source = "def authorized?(members, caller), do: Map.has_key?(members, caller)"

    assert Enum.any?(Probes.probes(), &Regex.match?(&1.pattern, source))
  end

  defp scan_tree do
    root = Path.expand("../../../..", __DIR__)

    for probe <- Probes.probes(),
        path <- paths_for(probe, root),
        not allowed_path?(path, probe.allowlist),
        Regex.match?(probe.pattern, File.read!(path)),
        do: "[#{probe.id}] #{relative(path, root)} — #{probe.desc}"
  end

  defp paths_for(%{paths: paths}, root), do: Enum.map(paths, &Path.join(root, &1))
  defp paths_for(_probe, root), do: Path.wildcard(Path.join(root, "apps/*/lib/**/*.ex"))

  defp allowed_path?(path, allowlist) do
    Enum.any?(allowlist, &String.contains?(path, &1))
  end

  defp relative(path, root), do: Path.relative_to(path, root)
end
