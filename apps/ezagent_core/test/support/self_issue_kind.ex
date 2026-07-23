defmodule Ezagent.Test.SelfIssueKind do
  @moduledoc false
  @behaviour Ezagent.Kind

  @impl true
  def type_name, do: :agent

  @impl true
  def behaviors, do: [Ezagent.ActionSet.Identity, Ezagent.Test.SelfIssueBehavior]

  @impl true
  def persistence, do: {:snapshot, :on_change}
end
