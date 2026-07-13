defmodule Ezagent.Session.Config.ManifestImport do
  @moduledoc false

  @spec read(String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  @doc false
  def read(path, root) when is_binary(path) and is_binary(root) do
    root = Path.expand(root)
    candidate = Path.expand(path, root)

    with :ok <- ensure_within_root(candidate, root),
         :ok <- reject_symlink_components(candidate, root),
         {:ok, body} <- File.read(candidate) do
      {:ok, body}
    else
      {:error, reason} -> {:error, {:participant_manifest_read_failed, reason}}
    end
  end

  def read(_path, _root),
    do: {:error, {:participant_manifest_read_failed, :invalid_path_or_root}}

  defp ensure_within_root(candidate, root) do
    relative = Path.relative_to(candidate, root)

    cond do
      relative == "." -> {:error, :manifest_path_is_root}
      relative == ".." -> {:error, :manifest_path_outside_root}
      String.starts_with?(relative, "../") -> {:error, :manifest_path_outside_root}
      Path.type(relative) == :absolute -> {:error, :manifest_path_outside_root}
      true -> :ok
    end
  end

  defp reject_symlink_components(candidate, root) do
    candidate
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce_while(root, fn segment, current ->
      next = Path.join(current, segment)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :manifest_symlink_forbidden}}
        {:ok, _stat} -> {:cont, next}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _path -> :ok
    end
  end
end
