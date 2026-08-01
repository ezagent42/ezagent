defmodule Ezagent.Invariants.IdentityCapsAccessGateTest do
  @moduledoc """
  Structural boundary for the sole identity-capability authority.

  Raw `caps_json` storage belongs only to `IdentityCaps.Store`; applications use
  the `IdentityCaps` facade, and the small persisted-only read allowlist stays
  explicit for non-blocking lifecycle paths.
  """
  use ExUnit.Case, async: true

  @store "apps/ezagent_domain_identity/lib/ezagent/identity_caps/store.ex"

  @persisted_only_allowlist MapSet.new([
                              "apps/ezagent_domain_identity/lib/ezagent/entity.ex",
                              "apps/ezagent_domain_session/lib/ezagent/behavior/session/self_add.ex"
                            ])

  test "raw caps_json storage exists only inside IdentityCaps.Store" do
    assert files_with_atom(:caps_json) == MapSet.new([@store])
  end

  test "the retired Identity compatibility read has no runtime consumer" do
    assert files_containing("Identity.read_identity_caps") == MapSet.new()
  end

  test "persisted-only facade consumers remain explicitly bounded" do
    assert files_containing("IdentityCaps.load_persisted(") == @persisted_only_allowlist
  end

  test "snapshot raw reads cannot serve identity capability authority" do
    offenders =
      source_files()
      |> Enum.filter(fn {_relative, absolute} ->
        source = File.read!(absolute)

        (String.contains?(source, "SnapshotStore.latest") or
           String.contains?(source, "KindSnapshot.decode_state")) and
          String.contains?(source, ":identity") and
          String.contains?(source, ":caps")
      end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    assert offenders == MapSet.new()
  end

  defp files_with_atom(atom) do
    source_files()
    |> Enum.filter(fn {_relative, absolute} -> ast_contains_atom?(quoted!(absolute), atom) end)
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp files_containing(needle) do
    source_files()
    |> Enum.filter(fn {_relative, absolute} -> File.read!(absolute) =~ needle end)
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp ast_contains_atom?(ast, atom) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, found? ->
        {node, found? or node == atom}
      end)

    found?
  end

  defp source_files do
    root = repo_root()

    root
    |> Path.join("apps/**/lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&EzagentCore.AstScan.tmp_fixture?/1)
    |> Enum.map(&{Path.relative_to(&1, root), &1})
  end

  defp quoted!(file) do
    case Code.string_to_quoted(File.read!(file)) do
      {:ok, ast} -> ast
      {:error, reason} -> raise "cannot scan #{file}: #{inspect(reason)}"
    end
  end

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
