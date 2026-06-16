defmodule EzagentPluginContent.Kb.SourceTracker do
  @moduledoc "Tracks KB sources by type/source grouping for the admin Sources tab."

  alias EzagentPluginContent.Kb.KbStore

  @doc """
  Lists all KB sources grouped by source_type and source_id.

  Returns a list of maps with keys: :source_type, :source_id, :title,
  :chunk_count, :source_url, :latest_chunk_time, :enabled.
  """
  @spec list_sources(binary()) :: [map()]
  def list_sources(kb_dir) do
    entries = KbStore.search(kb_dir, "")

    entries
    |> Enum.group_by(&Map.get(&1, "source_type", "manual"))
    |> Enum.flat_map(fn {type, group} ->
      group
      |> Enum.group_by(&Map.get(&1, "source_id", Map.get(&1, "id")))
      |> Enum.map(fn {source_id, chunks} ->
        first_entry = List.first(chunks) || %{}
        title = first_entry["title"] || source_id

        %{
          source_type: type,
          source_id: source_id,
          title: title,
          chunk_count: length(chunks),
          source_url: derive_source_url(type, source_id, title, kb_dir),
          latest_chunk_time: derive_latest_chunk_time(type, source_id, kb_dir, chunks),
          enabled: true
        }
      end)
    end)
  end

  defp derive_source_url("url", _source_id, title, _kb_dir) do
    # Title format is "URL: <host>", extract host as display URL
    case String.replace_prefix(title, "URL: ", "") do
      ^title -> title
      host -> "https://#{host}"
    end
  end

  defp derive_source_url("file", _source_id, title, _kb_dir) do
    # Title format is "File: <name> (<ext>)"
    case String.replace_prefix(title, "File: ", "") do
      ^title -> title
      name -> name
    end
  end

  defp derive_source_url(_type, _source_id, _title, _kb_dir), do: nil

  defp derive_latest_chunk_time("url", source_id, kb_dir, _chunks) do
    raw_path = Path.join([kb_dir, "_sources", "url", "#{source_id}.html"])
    file_mtime(raw_path)
  end

  defp derive_latest_chunk_time("file", source_id, kb_dir, _chunks) do
    sources_dir = Path.join(kb_dir, "_sources")
    files_dir = Path.join(sources_dir, "files")

    case File.ls(files_dir) do
      {:ok, files} ->
        files
        |> Enum.map(&Path.join(files_dir, &1))
        |> Enum.filter(&(Path.basename(&1) |> String.starts_with?(source_id) or
                          (:crypto.hash(:sha256, File.read!(&1))
                           |> Base.encode16(case: :lower)
                           |> String.slice(0, 12)) == source_id))
        |> Enum.map(&file_mtime/1)
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> nil
          times -> Enum.max(times, DateTime)
        end

      _ -> nil
    end
  end

  defp derive_latest_chunk_time("manual", _source_id, _kb_dir, chunks) do
    # Look for created_at field in chunk entries
    chunks
    |> Enum.map(&Map.get(&1, "created_at"))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      times -> Enum.max(times)
    end
  end

  defp derive_latest_chunk_time(_type, _source_id, _kb_dir, _chunks), do: nil

  defp file_mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} ->
        mtime |> DateTime.from_unix!() |> DateTime.to_iso8601()

      _ ->
        nil
    end
  end
end
