defmodule EzagentPluginContent.Skill.SkillLoader do
  @moduledoc "4-layer skill scanning with same-name override (tenant > industry > platform > framework)."

  defmodule Entry do
    defstruct [:name, :path, :layer]
  end

  @type layer :: :framework | :platform | :industry | :tenant

  @spec list(binary(), String.t(), String.t(), layer()) :: [%Entry{}]
  def list(base_dir, tid, role, layer)

  def list(base_dir, tid, role, :tenant) do
    dir = Path.join([base_dir, "tenants", tid, "sandbox", "skills", role])
    scan_dir(dir, :tenant)
  end

  def list(base_dir, _tid, _role, :industry) do
    dir = Path.join([base_dir, "platform", "industry", "cloud-comms", "skills"])
    scan_dir(dir, :industry)
  end

  def list(base_dir, _tid, _role, :platform) do
    dir = Path.join([base_dir, "platform", "skills"])
    scan_dir(dir, :platform)
  end

  def list(base_dir, _tid, _role, :framework) do
    dir = Path.join([base_dir, "platform", "skills"])
    scan_dir(dir, :framework)
  end

  defp scan_dir(dir, layer) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          skill_file = Path.join([dir, name, "SKILL.md"])
          if File.exists?(skill_file), do: [%Entry{name: name, path: skill_file, layer: layer}], else: []
        end)

      _ ->
        []
    end
  end
end
