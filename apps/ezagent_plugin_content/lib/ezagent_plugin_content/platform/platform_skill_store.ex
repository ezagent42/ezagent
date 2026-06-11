defmodule EzagentPluginContent.Platform.PlatformSkillStore do
  @moduledoc """
  Read/write platform skill templates from priv/platform/skills/.
  Each skill is a directory containing a SKILL.md file.
  """

  @skills_base Path.join(:code.priv_dir(:ezagent_plugin_content), "platform/skills")

  @doc """
  List all skills for a given role.
  Returns list of skill names (directory names).
  """
  @spec list_skills(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_skills(role) do
    dir = Path.join(@skills_base, role)
    if File.dir?(dir) do
      {:ok, File.ls!(dir) |> Enum.filter(fn name ->
        File.dir?(Path.join(dir, name))
      end)}
    else
      {:ok, []}
    end
  end

  @doc """
  Read a platform skill's SKILL.md content.
  """
  @spec read_skill(String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_skill(role, skill_name) do
    path = Path.join([@skills_base, role, skill_name, "SKILL.md"])
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Write (create or update) a platform skill's SKILL.md content.
  """
  @spec write_skill(String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def write_skill(role, skill_name, content) do
    dir = Path.join([@skills_base, role, skill_name])
    File.mkdir_p!(dir)
    path = Path.join(dir, "SKILL.md")
    File.write!(path, content)
    :ok
  end

  @doc """
  Delete a platform skill (removes the entire skill directory).
  """
  @spec delete_skill(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_skill(role, skill_name) do
    dir = Path.join([@skills_base, role, skill_name])
    if File.dir?(dir), do: File.rm_rf!(dir)
    :ok
  end
end
