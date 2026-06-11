defmodule EzagentPluginContent.SkillIndexer do
  @moduledoc "Build a Skill Index markdown from a skills directory tree (v2 §3.2.3). Each SKILL.md may have YAML frontmatter."

  @spec build(skills_dir :: String.t(), tid :: String.t()) :: String.t()
  def build(skills_dir, tid) do
    paths = Path.wildcard(skills_dir <> "/**/SKILL.md")

    if paths == [] do
      "## Skill Index\n\n(none)\n"
    else
      lines =
        paths
        |> Enum.map(&parse_skill(&1, skills_dir, tid))
        |> Enum.sort_by(& &1.name)
        |> Enum.map(fn %{name: name, description: desc, rel: rel} ->
          "- #{name} — #{desc} (plugins/#{tid}/skills/#{rel})"
        end)

      "## Skill Index\n\n" <> Enum.join(lines, "\n") <> "\n"
    end
  end

  # ---- private ----

  defp parse_skill(abs_path, skills_dir, _tid) do
    rel = Path.relative_to(abs_path, skills_dir)
    dir_name = abs_path |> Path.dirname() |> Path.basename()

    {name, description} =
      abs_path
      |> File.read()
      |> case do
        {:ok, content} -> extract_frontmatter(content, dir_name)
        {:error, _} -> {dir_name, ""}
      end

    %{name: name, description: description, rel: rel}
  end

  defp extract_frontmatter(content, fallback_name) do
    case String.split(content, ~r/^---\s*$/m, parts: 3) do
      ["", yaml_block, _body] ->
        parse_yaml_frontmatter(yaml_block, fallback_name)

      _no_frontmatter ->
        {fallback_name, ""}
    end
  end

  defp parse_yaml_frontmatter(yaml_block, fallback_name) do
    try do
      parsed = YamlElixir.read_from_string!(yaml_block)

      name =
        case Map.get(parsed, "name") do
          nil -> fallback_name
          v -> to_string(v)
        end

      description =
        case Map.get(parsed, "description") do
          nil -> ""
          v -> v |> to_string() |> String.trim()
        end

      {name, description}
    rescue
      _ -> {fallback_name, ""}
    end
  end
end
