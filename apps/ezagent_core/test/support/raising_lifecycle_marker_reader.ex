defmodule Ezagent.TestSupport.RaisingLifecycleMarkerReader do
  @moduledoc false

  def ever_created?(_uri), do: raise("marker store unavailable")
end
