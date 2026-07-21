defmodule EzagentCore.Test.CapAuthorityLoaderStub do
  @behaviour Ezagent.Cap.AuthorityLoader

  @impl true
  def read_held_caps(actor) do
    case Application.get_env(:ezagent_core, __MODULE__, MapSet.new()) do
      %{} = by_holder when not is_struct(by_holder, MapSet) ->
        Map.get(by_holder, Ezagent.URI.stable_key(actor), MapSet.new())

      caps ->
        caps
    end
  end

  @impl true
  def principal_fenced?(_actor), do: false
end
