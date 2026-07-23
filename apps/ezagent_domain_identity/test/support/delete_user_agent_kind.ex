defmodule Ezagent.Identity.Test.DeleteUserAgentKind do
  @moduledoc false

  @behaviour Ezagent.Kind

  @impl true
  def type_name, do: :agent

  @impl true
  def behaviors, do: [Ezagent.ActionSet.Identity]

  @impl true
  def persistence, do: {:snapshot, :on_change}
end
