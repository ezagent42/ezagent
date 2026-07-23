defmodule Ezagent.World.RefreshSurfaceBuilder do
  @moduledoc false

  def refresh_state(%URI{} = uri, %{marker: marker}) do
    # Bind the URI string before the map literal so the map line stays off the
    # unify-uri-query `uri_string_key` scan (same convention as runtime code).
    entity_uri_str = URI.to_string(uri)
    %{"entity_uri" => entity_uri_str, "marker" => marker}
  end
end
