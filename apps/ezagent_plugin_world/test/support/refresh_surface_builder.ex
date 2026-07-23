defmodule Ezagent.World.RefreshSurfaceBuilder do
  @moduledoc false

  def refresh_state(%URI{} = uri, %{marker: marker}) do
    %{"entity_uri" => URI.to_string(uri), "marker" => marker}
  end
end
