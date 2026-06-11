defmodule EzagentPluginContent.Skill.SkillIndexer do
  @moduledoc "Generate Skill Index markdown from 4-layer skill scanning."

  alias EzagentPluginContent.Skill.SkillLoader

  @spec build(binary(), String.t(), String.t()) :: binary()
  def build(base_dir, tid, role) do
    layers = [:tenant, :industry, :platform, :framework]
    entries = Enum.flat_map(layers, &SkillLoader.list(base_dir, tid, role, &1))
    # Same-name override: first occurrence wins (tenant first in layers order)
    unique = Enum.uniq_by(entries, & &1.name)
    if unique == [], do: "", else: build_markdown(unique)
  end

  defp build_markdown(entries) do
    lines =
      Enum.map(entries, fn e ->
        meta = read_frontmatter(e.path)
        name = Map.get(meta, "name", e.name)
        desc = Map.get(meta, "description", "")
        desc_suffix = if desc != "", do: ": #{desc}", else: ""
        "  - **#{name}** — `skills/customer/#{e.name}/SKILL.md`#{desc_suffix}"
      end)

    ["\n## Skill Index\n\n需要时 Read 对应文件:\n" | lines] |> Enum.join("\n")
  end

  defp read_frontmatter(path) do
    case File.read(path) do
      {:ok, content} ->
        case Regex.run(~r/^---\s*\n(.*?)\n---/s, content) do
          [_, yaml_str] ->
            case YamlElixir.read_from_string(yaml_str) do
              {:ok, map} -> map
              _ -> %{}
            end

          _ ->
            %{}
        end

      _ ->
        %{}
    end
  end
end
