defmodule Ezagent.Invariants.CapProvenanceChokepointTest do
  @moduledoc """
  I11: grant and revoke share one provenance-preparation primitive.

  The artifact metadata mutation belongs only to `Ezagent.Cap`; the legacy
  dispatch adapter must route grant through `Cap.issue/3` and revoke through
  the same lower-level provenance primitive without invoking grant authz.
  """
  use ExUnit.Case, async: true

  @cap_path "apps/ezagent_core/lib/ezagent/cap.ex"
  @grant_path "apps/ezagent_domain_identity/lib/ezagent/identity/grant.ex"

  test "Ezagent.Cap is the sole home that stamps granted_by provenance" do
    hits = grep("%\\{cap \\| granted_by:")

    assert Enum.all?(hits, &String.starts_with?(&1, @cap_path <> ":")),
           "granted_by provenance mutation escaped Ezagent.Cap:\n#{Enum.join(hits, "\n")}"

    assert length(hits) == 1,
           "expected exactly one shared provenance mutation, got:\n#{Enum.join(hits, "\n")}"
  end

  test "grant issues while revoke uses the same provenance primitive" do
    source = File.read!(Path.join(repo_root(), @grant_path))

    assert source =~ "Cap.issue(authorization, target, cap)"
    assert source =~ "Cap.prepare_provenance(authorization, cap)"
  end

  defp grep(pattern) do
    {output, status} =
      System.cmd("grep", ["-rEn", pattern, Path.join(repo_root(), "apps"), "--include=*.ex"],
        stderr_to_stdout: false
      )

    if status > 1, do: raise("grep failed with exit #{status}")

    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.replace_prefix(&1, repo_root() <> "/", ""))
    |> Enum.reject(&String.contains?(&1, "/test/"))
  end

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
