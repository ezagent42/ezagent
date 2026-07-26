defmodule Ezagent.Identity.Test.BusyDeleteUserAgentKind do
  @moduledoc false

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :agent

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.ActionSet.Identity]

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}

  @impl Ezagent.Kind
  def terminate_strategy, do: {:custom, __MODULE__, :leave_running}

  def leave_running(_uri), do: :ok
end
