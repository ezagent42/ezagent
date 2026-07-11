defmodule EzagentCore.Test.CapAuthorityLoaderStub do
  @behaviour Ezagent.Cap.AuthorityLoader

  @impl true
  def read_held_caps(_actor) do
    Application.get_env(:ezagent_core, __MODULE__, MapSet.new())
  end
end
