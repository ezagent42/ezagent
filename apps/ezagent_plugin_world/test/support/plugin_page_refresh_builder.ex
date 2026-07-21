defmodule Ezagent.World.PluginPageRefreshBuilder do
  def refresh_state(entity_uri, %{marker: marker}) do
    %{"entity_uri" => URI.to_string(entity_uri), "marker" => marker}
  end
end
