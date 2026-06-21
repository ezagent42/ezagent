defmodule EzagentCore.ArchitectureCase do
  @moduledoc false

  import ExUnit.Assertions

  @manifest_path Path.join(__DIR__, "arch_baseline_manifest.exs")
  @manifest @manifest_path |> Code.eval_file() |> elem(0)

  def manifest, do: @manifest
  def manifest_path, do: @manifest_path

  def cap(name) when is_atom(name), do: Map.fetch!(@manifest, name)

  def assert_at_or_below(name) when is_atom(name) do
    count = Mix.Tasks.Ezagent.Arch.Scan.count(name)
    cap = cap(name)

    assert count <= cap,
           """
           Architecture fitness regression for #{name}: measured #{count}, cap #{cap}.
           Fix the new debt or, for an intentional cap increase, add:
               # arch-cap-bump: <reason>
           on the manifest line.
           """
  end

  @doc """
  Ratchet assertion for the documentation-coverage gate (2026-06-13). Same
  semantics as `assert_at_or_below/1` but counts come from
  `Mix.Tasks.Ezagent.Doc.Scan` (doc-coverage) rather than the architecture
  scanner. Shares the manifest cap + `# arch-cap-bump:` convention.
  """
  def assert_doc_at_or_below(name) when is_atom(name) do
    count = Mix.Tasks.Ezagent.Doc.Scan.count(name)
    cap = cap(name)

    assert count <= cap,
           """
           Documentation-coverage regression for #{name}: measured #{count}, cap #{cap}.
           Add a @moduledoc / @doc (or an explicit @moduledoc false / @doc false)
           to the new offender(s) — run `mix ezagent.doc.scan` to list them.
           For an intentional cap increase, add:
               # arch-cap-bump: <reason>
           on the manifest line.
           """
  end

  def assert_zero(name) when is_atom(name) do
    count = Mix.Tasks.Ezagent.Arch.Scan.count(name)

    assert count == 0,
           """
           Architecture invariant regression for #{name}: measured #{count}, expected 0.
           This PR-0 fitness function is target-zero and must never grow.
           """
  end

  def assert_manifest_cap_raise_is_annotated(name) do
    current = cap(name)

    with {:ok, previous_manifest} <- previous_manifest(),
         {:ok, previous} <- Map.fetch(previous_manifest, name),
         true <- current > previous do
      assert manifest_line_has_cap_bump?(name),
             "#{name} cap was raised from #{previous} to #{current} without # arch-cap-bump:"
    else
      _ -> :ok
    end
  end

  defp previous_manifest do
    rel = Path.relative_to(@manifest_path, repo_root())

    case System.cmd("git", ["show", "origin/main:" <> rel], stderr_to_stdout: true) do
      {contents, 0} ->
        {manifest, _binding} = Code.eval_string(contents)
        {:ok, manifest}

      _ ->
        :error
    end
  end

  defp manifest_line_has_cap_bump?(name) do
    name = Atom.to_string(name)

    @manifest_path
    |> File.read!()
    |> String.split("\n")
    |> lines_have_cap_bump?(name, [])
  end

  defp lines_have_cap_bump?([], _name, _comment_block), do: false

  defp lines_have_cap_bump?([line | rest], name, comment_block) do
    if String.contains?(line, name <> ":") do
      String.contains?(line, "# arch-cap-bump:") or block_has_cap_bump?(comment_block)
    else
      lines_have_cap_bump?(rest, name, next_comment_block(line, comment_block))
    end
  end

  defp next_comment_block(line, comment_block) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" -> comment_block
      String.starts_with?(String.trim_leading(line), "#") -> [line | comment_block]
      true -> []
    end
  end

  defp block_has_cap_bump?(comment_block),
    do: Enum.any?(comment_block, &String.contains?(&1, "# arch-cap-bump:"))

  defp repo_root do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: false) do
      {top, 0} -> String.trim(top)
      _ -> Path.expand("../../../..", __DIR__)
    end
  end
end
