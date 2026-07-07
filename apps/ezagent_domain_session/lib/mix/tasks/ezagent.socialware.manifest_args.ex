defmodule Mix.Tasks.Ezagent.Socialware.ManifestArgs do
  @moduledoc false

  @doc false
  @spec workspace_uri(keyword()) :: URI.t()
  def workspace_uri(opts) do
    case Keyword.get(opts, :workspace) do
      nil -> Ezagent.URI.workspace(:system)
      ws when is_binary(ws) -> Ezagent.URI.new!(ws)
    end
  end
end
