defmodule EzagentPluginContent.Skill.SkillStore do
  @moduledoc "Skill file CRUD. Only writes to tenant sandbox."

  alias EzagentPluginContent.Skill.SkillLoader

  @spec read(binary(), String.t(), String.t(), String.t()) :: {:ok, binary()} | :not_found
  def read(base_dir, tid, role, name) do
    layers = [:tenant, :industry, :platform, :framework]

    Enum.find_value(layers, :not_found, fn layer ->
      entries = SkillLoader.list(base_dir, tid, role, layer)

      case Enum.find(entries, &(&1.name == name)) do
        # keep searching
        nil -> nil
        entry -> {:ok, File.read!(entry.path)}
      end
    end)
  end

  @spec write(binary(), String.t(), String.t(), String.t(), binary()) :: :ok
  def write(base_dir, tid, role, name, content) do
    dir = Path.join([base_dir, "tenants", tid, "sandbox", "skills", role, name])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SKILL.md"), content)
    :ok
  end

  @spec delete(binary(), String.t(), String.t(), String.t()) :: :ok | {:error, :not_found}
  def delete(base_dir, tid, role, name) do
    path = Path.join([base_dir, "tenants", tid, "sandbox", "skills", role, name])
    if File.exists?(path), do: File.rm_rf!(path) |> then(fn _ -> :ok end), else: {:error, :not_found}
  end
end
