defmodule EzagentPluginContent.Platform.PlatformSoulStore do
  @moduledoc """
  Read/write platform soul templates from priv/platform/.
  CRUD over soul.md files at various levels (platform, framework, templates).
  """

  @base_dir Path.join(:code.priv_dir(:ezagent_plugin_content), "platform")

  @doc """
  Read a platform soul template.
  Level can be: `:platform`, `:framework`, or `:template`.
  """
  @spec read_soul(atom(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_soul(level, role)

  def read_soul(:platform, role) do
    path = Path.join([@base_dir, "platform", "#{role}.md"])
    read_file(path)
  end

  def read_soul(:framework, role) do
    path = Path.join([@base_dir, "framework", role, "soul.md"])
    read_file(path)
  end

  def read_soul(:template, role) do
    path = Path.join([@base_dir, "templates", role, "soul.md"])
    read_file(path)
  end

  @doc """
  Write a platform soul template (overwrite).
  Returns `:ok` or `{:error, reason}`.
  """
  @spec write_soul(atom(), String.t(), binary()) :: :ok | {:error, term()}
  def write_soul(level, role, content)

  def write_soul(:platform, role, content) do
    path = Path.join([@base_dir, "platform", "#{role}.md"])
    write_file(path, content)
  end

  def write_soul(:framework, role, content) do
    path = Path.join([@base_dir, "framework", role, "soul.md"])
    write_file(path, content)
  end

  def write_soul(:template, role, content) do
    path = Path.join([@base_dir, "templates", role, "soul.md"])
    write_file(path, content)
  end

  @doc """
  Delete a platform soul template.
  """
  @spec delete_soul(atom(), String.t()) :: :ok | {:error, term()}
  def delete_soul(level, role)

  def delete_soul(:platform, role) do
    path = Path.join([@base_dir, "platform", "#{role}.md"])
    delete_file(path)
  end

  def delete_soul(:framework, role) do
    path = Path.join([@base_dir, "framework", role, "soul.md"])
    delete_file(path)
  end

  def delete_soul(:template, role) do
    path = Path.join([@base_dir, "templates", role, "soul.md"])
    delete_file(path)
  end

  # Private helpers

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp write_file(path, content) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, content)
    :ok
  end

  defp delete_file(path) do
    if File.exists?(path) do
      File.rm!(path)
    end

    :ok
  end
end
