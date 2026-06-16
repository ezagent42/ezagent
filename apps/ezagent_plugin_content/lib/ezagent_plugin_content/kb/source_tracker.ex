defmodule EzagentPluginContent.Kb.SourceTracker do
  @moduledoc "Tracks KB sources by type/source grouping for the admin Sources tab."

  alias EzagentPluginContent.Kb.KbStore

  @doc """
  Lists all KB sources grouped by source_type and source_id.

  Returns a list of maps with keys: :source_type, :source_id, :title, :chunk_count.
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
        %{
          source_type: type,
          source_id: source_id,
          title: (List.first(chunks) || %{})["title"] || source_id,
          chunk_count: length(chunks)
        }
      end)
    end)
  end
end
