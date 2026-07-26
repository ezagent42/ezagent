defmodule Ezagent.TestSupport.HonestTerminateKind do
  @moduledoc false

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :test

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Test.TestBehavior]

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}

  @impl Ezagent.Kind
  def terminate_strategy, do: {:custom, __MODULE__, :leave_running}

  def leave_running(_uri), do: :ok
end
